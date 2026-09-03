import Foundation
import Network

struct IndexedTransaction: Decodable, Sendable {
    let transactionID: String?
    let blockTime: Int64?
    let isAccepted: Bool?
    let acceptingBlockTime: Int64?
    let acceptingBlockBlueScore: UInt64?
    let inputs: [IndexedTransactionInput]?
    let outputs: [IndexedTransactionOutput]?

    enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case blockTime = "block_time"
        case isAccepted = "is_accepted"
        case acceptingBlockTime = "accepting_block_time"
        case acceptingBlockBlueScore = "accepting_block_blue_score"
        case inputs
        case outputs
    }
}

private struct VirtualBlueScoreResponse: Decodable {
    let blueScore: UInt64
}

struct IndexedTransactionInput: Decodable, Sendable {
    let previousOutpointHash: String?
    let previousOutpointIndex: UInt32?
    let previousOutpointAddress: String?
    let previousOutpointAmount: UInt64?

    enum CodingKeys: String, CodingKey {
        case previousOutpointHash = "previous_outpoint_hash"
        case previousOutpointIndex = "previous_outpoint_index"
        case previousOutpointAddress = "previous_outpoint_address"
        case previousOutpointAmount = "previous_outpoint_amount"
    }

    init(
        previousOutpointHash: String? = nil,
        previousOutpointIndex: UInt32? = nil,
        previousOutpointAddress: String?,
        previousOutpointAmount: UInt64?
    ) {
        self.previousOutpointHash = previousOutpointHash
        self.previousOutpointIndex = previousOutpointIndex
        self.previousOutpointAddress = previousOutpointAddress
        self.previousOutpointAmount = previousOutpointAmount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        previousOutpointHash = try container.decodeIfPresent(
            String.self,
            forKey: .previousOutpointHash
        )
        if let numericIndex = try? container.decodeIfPresent(
            UInt32.self,
            forKey: .previousOutpointIndex
        ) {
            previousOutpointIndex = numericIndex
        } else if let stringIndex = try? container.decodeIfPresent(
            String.self,
            forKey: .previousOutpointIndex
        ) {
            previousOutpointIndex = UInt32(stringIndex)
        } else {
            previousOutpointIndex = nil
        }
        previousOutpointAddress = try container.decodeIfPresent(
            String.self,
            forKey: .previousOutpointAddress
        )
        previousOutpointAmount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .previousOutpointAmount
        )
    }
}

struct IndexedTransactionOutput: Decodable, Sendable {
    let amount: UInt64
    let scriptPublicKeyAddress: String?

    enum CodingKeys: String, CodingKey {
        case amount
        case scriptPublicKeyAddress = "script_public_key_address"
    }
}

private struct ActiveAddressRequest: Encodable {
    let addresses: [String]
}

private struct ActiveAddressResponse: Decodable {
    let address: String
    let active: Bool
}

private struct TransactionSearchRequest: Encodable {
    let transactionIds: [String]
}

private enum TransactionHistoryError: LocalizedError {
    case unsupportedNetwork
    case invalidResponse
    case server(Int)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .unsupportedNetwork:
            "Complete transaction history is currently available for mainnet accounts only."
        case .invalidResponse:
            "The transaction history service returned an invalid response."
        case .server(let status):
            "The transaction history service returned HTTP \(status)."
        case .rateLimited:
            "Transaction history synchronization will retry shortly."
        }
    }
}

struct TransactionHistoryClient: Sendable {
    private let baseURL = URL(string: "https://api.kaspa.org")!

    func virtualBlueScore() async throws -> UInt64 {
        let request = URLRequest(
            url: baseURL.appending(path: "info/virtual-chain-blue-score")
        )
        let (data, _) = try await data(for: request)
        return try JSONDecoder().decode(
            VirtualBlueScoreResponse.self,
            from: data
        ).blueScore
    }

    func transactions(
        for profile: WalletProfile,
        progress: (@MainActor @Sendable (
            _ completed: Int,
            _ total: Int,
            _ isRetryingThrottledAddresses: Bool
        ) -> Void)? = nil
    ) async throws -> [WalletTransaction] {
        guard profile.network.lowercased() == "mainnet" else {
            throw TransactionHistoryError.unsupportedNetwork
        }

        let addresses = Array(Set(profile.receiveAddresses + profile.changeAddresses)).sorted()
        guard !addresses.isEmpty else { return [] }
        let activeAddresses = try await activeAddresses(in: addresses).sorted()
        guard !activeAddresses.isEmpty else { return [] }

        var indexedTransactions: [IndexedTransaction] = []
        let maximumConcurrentRequests = 3
        var nextAddressIndex = 0
        var completedAddressCount = 0
        await progress?(0, activeAddresses.count, false)
        var throttledAddresses: [String] = []

        try await withThrowingTaskGroup(
            of: (transactions: [IndexedTransaction], throttledAddress: String?).self
        ) { group in
            func enqueueNextAddress() {
                guard nextAddressIndex < activeAddresses.count else { return }
                let address = activeAddresses[nextAddressIndex]
                nextAddressIndex += 1
                group.addTask {
                    do {
                        return (try await fetchTransactions(for: address), nil)
                    } catch TransactionHistoryError.rateLimited {
                        return ([], address)
                    }
                }
            }

            for _ in 0..<min(maximumConcurrentRequests, activeAddresses.count) {
                enqueueNextAddress()
            }

            while let result = try await group.next() {
                try Task.checkCancellation()
                if let throttledAddress = result.throttledAddress {
                    throttledAddresses.append(throttledAddress)
                } else {
                    indexedTransactions.append(contentsOf: result.transactions)
                    completedAddressCount += 1
                    await progress?(completedAddressCount, activeAddresses.count, false)
                }
                enqueueNextAddress()
            }
        }

        // Preserve completed requests and retry only throttled addresses after
        // a cooldown. Healthy imports never enter this slower path.
        for retryRound in 0..<2 where !throttledAddresses.isEmpty {
            await progress?(completedAddressCount, activeAddresses.count, true)
            try await Task.sleep(for: .seconds(retryRound == 0 ? 15 : 30))

            var stillThrottled: [String] = []
            for address in throttledAddresses {
                try Task.checkCancellation()
                do {
                    indexedTransactions.append(
                        contentsOf: try await fetchTransactions(for: address)
                    )
                    completedAddressCount += 1
                    await progress?(completedAddressCount, activeAddresses.count, true)
                } catch TransactionHistoryError.rateLimited {
                    stillThrottled.append(address)
                }
            }
            throttledAddresses = stillThrottled
        }

        guard throttledAddresses.isEmpty else {
            throw TransactionHistoryError.rateLimited
        }

        return mapTransactions(
            indexedTransactions,
            profileID: profile.id,
            receiveAddresses: Set(profile.receiveAddresses),
            changeAddresses: Set(profile.changeAddresses)
        )
    }

    func transaction(
        id: String,
        for profile: WalletProfile
    ) async throws -> WalletTransaction? {
        guard profile.network.lowercased() == "mainnet" else { return nil }
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedID.isEmpty else { return nil }

        var components = URLComponents(
            url: baseURL.appending(path: "transactions").appending(path: normalizedID),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "resolve_previous_outpoints", value: "light")
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, _) = try await data(for: request)
        let indexed = try JSONDecoder().decode(IndexedTransaction.self, from: data)
        return mapTransactions(
            [indexed],
            profileID: profile.id,
            receiveAddresses: Set(profile.receiveAddresses),
            changeAddresses: Set(profile.changeAddresses)
        ).first
    }

    func transactions(
        ids: [String],
        for profile: WalletProfile
    ) async throws -> [WalletTransaction] {
        guard profile.network.lowercased() == "mainnet" else { return [] }
        let uniqueIDs = Array(Set(ids.map { $0.lowercased() })).prefix(32)
        guard !uniqueIDs.isEmpty else { return [] }

        var components = URLComponents(
            url: baseURL.appending(path: "transactions/search"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "resolve_previous_outpoints", value: "light")
        ]
        guard let url = components.url else {
            throw TransactionHistoryError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            TransactionSearchRequest(transactionIds: Array(uniqueIDs))
        )
        let (data, _) = try await data(for: request)
        let indexed = try JSONDecoder().decode([IndexedTransaction].self, from: data)
        return mapTransactions(
            indexed,
            profileID: profile.id,
            receiveAddresses: Set(profile.receiveAddresses),
            changeAddresses: Set(profile.changeAddresses)
        )
    }

    func recentTransactions(
        for addresses: [String],
        spending outpointIDs: Set<String>,
        profile: WalletProfile
    ) async throws -> [WalletTransaction] {
        guard profile.network.lowercased() == "mainnet" else { return [] }
        let uniqueAddresses = Array(Set(addresses)).sorted()
        guard !uniqueAddresses.isEmpty else { return [] }

        var indexed: [IndexedTransaction] = []
        for address in uniqueAddresses {
            indexed.append(contentsOf: try await fetchRecentTransactions(for: address))
        }
        let matching = indexed.filter { transaction in
            (transaction.inputs ?? []).contains { input in
                guard let hash = input.previousOutpointHash?.lowercased(),
                      let index = input.previousOutpointIndex else { return false }
                return outpointIDs.contains("\(hash):\(index)")
            }
        }
        return mapTransactions(
            matching,
            profileID: profile.id,
            receiveAddresses: Set(profile.receiveAddresses),
            changeAddresses: Set(profile.changeAddresses)
        )
    }

    func activeAddresses(in addresses: [String]) async throws -> Set<String> {
        var active: [String] = []
        for start in stride(from: 0, to: addresses.count, by: 250) {
            let end = min(start + 250, addresses.count)
            var request = URLRequest(url: baseURL.appending(path: "addresses/active"))
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                ActiveAddressRequest(addresses: Array(addresses[start..<end]))
            )

            let (data, _) = try await data(for: request)
            let entries = try JSONDecoder().decode([ActiveAddressResponse].self, from: data)
            active.append(contentsOf: entries.filter(\.active).map(\.address))
        }
        return Set(active.map { $0.lowercased() })
    }

    private func fetchTransactions(for address: String) async throws -> [IndexedTransaction] {
        var before: String?
        var seenCursors = Set<String>()
        var transactions: [IndexedTransaction] = []

        for _ in 0..<100 {
            var components = URLComponents(
                url: baseURL
                    .appending(path: "addresses")
                    .appending(path: address)
                    .appending(path: "full-transactions-page"),
                resolvingAgainstBaseURL: false
            )!
            var queryItems = [
                URLQueryItem(name: "limit", value: "500"),
                URLQueryItem(name: "resolve_previous_outpoints", value: "light")
            ]
            if let before {
                queryItems.append(URLQueryItem(name: "before", value: before))
            }
            components.queryItems = queryItems
            guard let url = components.url else {
                throw TransactionHistoryError.invalidResponse
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, response) = try await data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TransactionHistoryError.invalidResponse
            }
            transactions.append(
                contentsOf: try JSONDecoder().decode([IndexedTransaction].self, from: data)
            )

            guard let next = httpResponse.value(forHTTPHeaderField: "X-Next-Page-Before"),
                  !next.isEmpty,
                  seenCursors.insert(next).inserted else {
                break
            }
            before = next
            try await Task.sleep(for: .milliseconds(100))
        }
        return transactions
    }

    private func fetchRecentTransactions(for address: String) async throws -> [IndexedTransaction] {
        var components = URLComponents(
            url: baseURL
                .appending(path: "addresses")
                .appending(path: address)
                .appending(path: "full-transactions-page"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "resolve_previous_outpoints", value: "light")
        ]
        guard let url = components.url else {
            throw TransactionHistoryError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, _) = try await data(for: request)
        return try JSONDecoder().decode([IndexedTransaction].self, from: data)
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error = TransactionHistoryError.invalidResponse
        for attempt in 0..<6 {
            let result: (Data, URLResponse)
            do {
                result = try await URLSession.shared.data(for: request)
            } catch {
                lastError = error
                guard attempt < 5, isTransientTransportError(error) else {
                    throw error
                }
                try await Task.sleep(for: .seconds(min(1 << attempt, 15)))
                continue
            }

            guard let response = result.1 as? HTTPURLResponse else {
                throw TransactionHistoryError.invalidResponse
            }

            if response.statusCode == 429 || (500..<600).contains(response.statusCode) {
                lastError = response.statusCode == 429
                    ? TransactionHistoryError.rateLimited
                    : TransactionHistoryError.server(response.statusCode)
                guard attempt < 5 else { throw lastError }

                let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init)
                let fallbackDelay = TimeInterval(1 << attempt)
                let delay = min(max(retryAfter ?? fallbackDelay, 1), 15)
                try await Task.sleep(for: .seconds(delay))
                continue
            }

            try validate(response)
            return result
        }

        throw lastError
    }

    private func isTransientTransportError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .resourceUnavailable
        ].contains(urlError.code)
    }

    private func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TransactionHistoryError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TransactionHistoryError.server(httpResponse.statusCode)
        }
    }

    func mapTransactions(
        _ indexedTransactions: [IndexedTransaction],
        profileID: UUID,
        receiveAddresses: Set<String>,
        changeAddresses: Set<String>
    ) -> [WalletTransaction] {
        let normalizedReceiveAddresses = Set(receiveAddresses.map { $0.lowercased() })
        let normalizedChangeAddresses = Set(changeAddresses.map { $0.lowercased() })
        let walletAddresses = normalizedReceiveAddresses.union(normalizedChangeAddresses)
        var mappedByID: [String: WalletTransaction] = [:]

        for transaction in indexedTransactions {
            guard let rawID = transaction.transactionID else { continue }
            let transactionID = rawID.lowercased()
            guard mappedByID[transactionID] == nil else { continue }

            let inputs = transaction.inputs ?? []
            let outputs = transaction.outputs ?? []
            let walletInputTotal = inputs.reduce(UInt64(0)) { result, input in
                guard let address = input.previousOutpointAddress,
                      walletAddresses.contains(address.lowercased()) else { return result }
                return result &+ (input.previousOutpointAmount ?? 0)
            }
            let walletOutputTotal = outputs.reduce(UInt64(0)) { result, output in
                guard let address = output.scriptPublicKeyAddress,
                      walletAddresses.contains(address.lowercased()) else { return result }
                return result &+ output.amount
            }
            guard walletInputTotal > 0 || walletOutputTotal > 0 else { continue }

            let totalInput = inputs.reduce(UInt64(0)) {
                $0 &+ ($1.previousOutpointAmount ?? 0)
            }
            let totalOutput = outputs.reduce(UInt64(0)) { $0 &+ $1.amount }
            let fee = totalInput >= totalOutput ? totalInput - totalOutput : 0
            let direction: WalletTransactionDirection = walletInputTotal > 0 ? .sent : .received
            let amount: UInt64
            let counterparty: String
            let kind: WalletTransactionKind

            if direction == .sent {
                let externalOutputs = outputs.filter {
                    guard let address = $0.scriptPublicKeyAddress else { return false }
                    return !walletAddresses.contains(address.lowercased())
                }
                if externalOutputs.isEmpty {
                    let internalDestinationOutputs = outputs.filter {
                        guard let address = $0.scriptPublicKeyAddress?.lowercased() else {
                            return false
                        }
                        return normalizedReceiveAddresses.contains(address)
                            && !normalizedChangeAddresses.contains(address)
                    }
                    amount = internalDestinationOutputs.reduce(UInt64(0)) { $0 &+ $1.amount }
                    counterparty = "Internal Transfer"
                    kind = .internalTransfer
                } else {
                    amount = externalOutputs.reduce(UInt64(0)) { $0 &+ $1.amount }
                    let addresses = Array(Set(externalOutputs.compactMap(\.scriptPublicKeyAddress)))
                    counterparty = addresses.count == 1
                        ? addresses[0]
                        : "\(addresses.count) recipients"
                    kind = .sent
                }
            } else {
                amount = walletOutputTotal
                let sourceAddresses = Array(Set(inputs.compactMap(\.previousOutpointAddress).filter {
                    !walletAddresses.contains($0.lowercased())
                }))
                counterparty = sourceAddresses.count == 1
                    ? sourceAddresses[0]
                    : sourceAddresses.isEmpty ? "Coinbase or unknown source" : "Multiple senders"
                kind = .received
            }

            let milliseconds = transaction.acceptingBlockTime ?? transaction.blockTime ?? 0
            mappedByID[transactionID] = WalletTransaction(
                profileID: profileID,
                transactionID: transactionID,
                destination: counterparty,
                amountSompi: amount,
                feeSompi: direction == .sent ? fee : 0,
                broadcastAt: milliseconds > 0
                    ? Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
                    : Date(),
                direction: direction,
                kind: kind,
                status: transaction.isAccepted == true
                    && transaction.acceptingBlockBlueScore != nil
                    ? .confirmed
                    : .pending,
                acceptingBlockBlueScore: transaction.acceptingBlockBlueScore
            )
        }

        return mappedByID.values.sorted { $0.broadcastAt > $1.broadcastAt }
    }
}

@MainActor
final class WalletSnapshotCache {

    static let shared = WalletSnapshotCache()

    private let legacyPrefix = "kassigner.walletSnapshot.v1."
    private let protectedStorage: ProtectedWalletStorage
    private let defaults: UserDefaults

    init(
        protectedStorage: ProtectedWalletStorage = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.protectedStorage = protectedStorage
        self.defaults = defaults
    }

    func load(profileID: UUID) -> WalletSyncPayload? {
        let fileName = snapshotFileName(profileID: profileID)
        if let snapshot = protectedStorage.load(
            WalletSyncPayload.self,
            fileName: fileName
        ) {
            return snapshot
        }
        let legacyKey = legacyPrefix + profileID.uuidString
        guard let data = defaults.data(forKey: legacyKey),
              let snapshot = try? JSONDecoder().decode(
                  WalletSyncPayload.self,
                  from: data
              ) else { return nil }
        if protectedStorage.save(snapshot, fileName: fileName) {
            defaults.removeObject(forKey: legacyKey)
        }
        return snapshot
    }

    func save(_ snapshot: WalletSyncPayload, profileID: UUID) {
        _ = protectedStorage.save(
            snapshot,
            fileName: snapshotFileName(profileID: profileID)
        )
    }

    func remove(profileID: UUID) {
        protectedStorage.remove(fileName: snapshotFileName(profileID: profileID))
        defaults.removeObject(forKey: legacyPrefix + profileID.uuidString)
    }

    private func snapshotFileName(profileID: UUID) -> String {
        "wallet-snapshot-\(profileID.uuidString.lowercased()).json"
    }
}

@MainActor
final class WalletSyncService: ObservableObject {
    struct DiscoveryPlan: Equatable {
        let receiveCount: Int
        let changeCount: Int
        let nextReceiveIndex: Int
        let nextChangeIndex: Int
        let reachedSafetyLimit: Bool
    }

    struct DiscoveryProgress: Equatable {
        let title: String
        let detail: String
        let fraction: Double
    }

    struct TransactionHistoryProgress: Equatable {
        enum Phase: Equatable {
            case locatingAddresses
            case loadingAddresses
            case retryingThrottledAddresses
            case finalizing
        }

        let profileID: UUID
        let completedAddresses: Int
        let totalAddresses: Int
        let phase: Phase

        var fraction: Double? {
            if phase == .finalizing { return 1 }
            guard totalAddresses > 0 else { return nil }
            return min(1, max(0, Double(completedAddresses) / Double(totalAddresses)))
        }

        var detail: String {
            switch phase {
            case .locatingAddresses:
                return "Finding active wallet addresses…"
            case .loadingAddresses:
                guard totalAddresses > 0 else {
                    return "Finding active wallet addresses…"
                }
                return "Loading address \(completedAddresses) of \(totalAddresses)…"
            case .retryingThrottledAddresses:
                return "Kaspa is busy. Retrying remaining addresses…"
            case .finalizing:
                return "Finalizing transaction history…"
            }
        }
    }

    private struct InitialDiscoveryCheckpoint {
        let profile: WalletProfile
        let snapshot: WalletSyncPayload
    }

    enum State: Equatable {
        case idle
        case syncing
        case connected
        case failed(String)

        var title: String {
            switch self {
            case .idle: "Ready"
            case .syncing: "Connecting..."
            case .connected: "Connected"
            case .failed: "No connection"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var snapshot: WalletSyncPayload?
    @Published private(set) var feeEstimate: FeeEstimate?
    @Published private(set) var isNetworkAvailable = true
    @Published private(set) var isRefreshingTransactionHistory = false
    @Published private(set) var transactionHistoryProgress: TransactionHistoryProgress?
    @Published private(set) var transactionHistoryError: String?
    @Published private(set) var transactionHistoryUpdatedAt: Date?
    @Published private(set) var virtualBlueScore: UInt64?
    @Published private(set) var initialDiscoveryProgress: DiscoveryProgress?
    @Published private(set) var initialDiscoveryError: String?
    @Published private(set) var discoveryNotice: String?
    private var initialDiscoveryStage = "Preparing wallet discovery"
    private var initialDiscoveryCheckpoint: InitialDiscoveryCheckpoint?

    private var activeProfileID: UUID?
    private var activeProfileGeneration: UInt64 = 0
    private var lastRefreshAttempt: Date?
    private var lastTransactionHistoryAttempt: [UUID: Date] = [:]
    private var transactionHistoryProfilesInFlight: [UUID: UInt64] = [:]
    private var virtualBlueScoreRefreshInFlight = false
    private var lastVirtualBlueScoreAttempt: Date?
    private let transactionHistoryClient = TransactionHistoryClient()
    private let outgoingReconciliationKeyPrefix =
        "kassigner.outgoingReconciliation.v1."
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "org.kassigner.KasSigner.network-monitor")

    func preload(profile: WalletProfile) {
        guard activeProfileID != profile.id else { return }

        if initialDiscoveryCheckpoint?.profile.id != profile.id {
            initialDiscoveryCheckpoint = nil
        }
        activeProfileGeneration &+= 1
        activeProfileID = profile.id
        lastRefreshAttempt = nil
        transactionHistoryError = nil
        transactionHistoryUpdatedAt = nil
        initialDiscoveryProgress = nil
        initialDiscoveryError = nil
        discoveryNotice = nil
        virtualBlueScore = nil
        lastVirtualBlueScoreAttempt = nil
        state = isNetworkAvailable ? .idle : .failed("No internet connection.")

        snapshot = WalletSnapshotCache.shared.load(profileID: profile.id)
    }

    func clearDiscoveryNotice() {
        discoveryNotice = nil
    }

    func refreshVirtualBlueScore(force: Bool = false) async {
        guard isNetworkAvailable else { return }
        if virtualBlueScoreRefreshInFlight { return }
        if !force,
           let lastVirtualBlueScoreAttempt,
           Date().timeIntervalSince(lastVirtualBlueScoreAttempt) < 0.20 {
            return
        }

        lastVirtualBlueScoreAttempt = Date()
        virtualBlueScoreRefreshInFlight = true

        do {
            virtualBlueScore = try await transactionHistoryClient.virtualBlueScore()
        } catch {
            // Keep the last node-driven score when a transient request fails.
        }

        virtualBlueScoreRefreshInFlight = false
    }

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasAvailable = self.isNetworkAvailable
                self.isNetworkAvailable = path.status == .satisfied
                if path.status != .satisfied {
                    self.state = .failed("No internet connection.")
                } else if !wasAvailable {
                    self.state = .idle
                }
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    func refresh(
        profile: WalletProfile,
        walletStore: WalletStore,
        engine: KasSignerEngine,
        preferences: AppPreferences,
        force: Bool = true,
        minimumInterval: TimeInterval = 9,
        includeTransactionHistory: Bool = true,
        keepTransactionProgressThroughReconciliation: Bool = false
    ) async {
        guard isNetworkAvailable else {
            state = .failed("No internet connection.")
            return
        }

        if activeProfileID != profile.id {
            preload(profile: profile)
        }
        let profileGeneration = activeProfileGeneration

        if case .syncing = state { return }

        if !force,
           activeProfileID == profile.id,
           let lastRefreshAttempt,
           Date().timeIntervalSince(lastRefreshAttempt) < minimumInterval {
            return
        }

        if snapshot == nil,
           let cached = WalletSnapshotCache.shared.load(profileID: profile.id) {
            snapshot = cached
        }

        lastRefreshAttempt = Date()
        state = .syncing

        do {
            let beganWithInitialDiscovery = (
                walletStore.profiles.first(where: { $0.id == profile.id }) ?? profile
            ).requiresInitialDiscovery
            var profileToSync = walletStore.profiles.first(where: { $0.id == profile.id })
                ?? profile

            let resumableCheckpoint = initialDiscoveryCheckpoint.flatMap {
                $0.profile.id == profile.id ? $0 : nil
            }

            if beganWithInitialDiscovery,
               preferences.nodeMode == .automatic,
               resumableCheckpoint == nil {
                profileToSync = try await discoverImportedWallet(
                    profile: profileToSync,
                    engine: engine
                )
                guard activeProfileID == profile.id,
                      activeProfileGeneration == profileGeneration else { return }
            } else if beganWithInitialDiscovery {
                discoveryNotice = "Historical address discovery was skipped because Custom Node mode does not contact public indexers. Current UTXOs were still synchronized from your selected node."
                initialDiscoveryProgress = DiscoveryProgress(
                    title: "Synchronizing wallet",
                    detail: "Loading current UTXOs from your custom Kaspa node…",
                    fraction: 0.42
                )
            }

            let result: WalletSyncPayload
            let discoveredProfile: WalletProfile
            if let resumableCheckpoint {
                result = resumableCheckpoint.snapshot
                discoveredProfile = resumableCheckpoint.profile
            } else {
                let syncResult = try await syncWithAddressDiscovery(
                    profile: profileToSync,
                    walletStore: walletStore,
                    engine: engine,
                    preferences: preferences
                )
                result = syncResult.0
                discoveredProfile = syncResult.1
                if beganWithInitialDiscovery {
                    initialDiscoveryCheckpoint = InitialDiscoveryCheckpoint(
                        profile: discoveredProfile,
                        snapshot: result
                    )
                }
            }
            guard activeProfileID == profile.id,
                  activeProfileGeneration == profileGeneration else { return }
            if discoveredProfile != profile {
                if !beganWithInitialDiscovery {
                    walletStore.update(discoveredProfile)
                    walletStore.setLastViewedReceiveIndex(
                        discoveredProfile.nextReceiveIndex,
                        for: discoveredProfile.id,
                        addressCount: discoveredProfile.receiveAddresses.count
                    )
                }
            }
            var completedProfile = discoveredProfile
            if beganWithInitialDiscovery {
                completedProfile.requiresInitialDiscovery = false
                if walletStore.pendingImportedProfile?.id == completedProfile.id {
                    walletStore.commitPendingImport(completedProfile)
                } else {
                    walletStore.update(completedProfile)
                }
                initialDiscoveryProgress = DiscoveryProgress(
                    title: "Wallet ready",
                    detail: "Addresses and UTXOs are synchronized.",
                    fraction: 1
                )
            }

            let shouldRefreshTransactionHistory = includeTransactionHistory
                && (!beganWithInitialDiscovery || preferences.nodeMode == .automatic)
            if shouldRefreshTransactionHistory,
               keepTransactionProgressThroughReconciliation {
                prepareTransactionHistoryProgress(profileID: profile.id)
            }

            // Commit the authoritative address and UTXO result before loading
            // indexer history. This opens the wallet while the Transactions
            // tab reports its own background synchronization progress.
            snapshot = result
            WalletSnapshotCache.shared.save(result, profileID: profile.id)
            state = .connected
            initialDiscoveryProgress = nil
            initialDiscoveryError = nil
            initialDiscoveryCheckpoint = nil

            do {
                feeEstimate = try await engine.getFeeEstimate(
                    nodeConfiguration: preferences.nodeConfiguration
                )
            } catch {
                // Preserve the last valid estimate if a refresh temporarily fails.
            }

            guard activeProfileID == profile.id,
                  activeProfileGeneration == profileGeneration else { return }

            if shouldRefreshTransactionHistory {
                await refreshTransactionHistory(
                    profile: completedProfile,
                    walletStore: walletStore,
                    force: beganWithInitialDiscovery,
                    keepProgressVisible: keepTransactionProgressThroughReconciliation
                )
            }
        } catch {
            guard activeProfileID == profile.id,
                  activeProfileGeneration == profileGeneration else { return }
            state = .failed(friendlyMessage(for: error, preferences: preferences))
            if profile.requiresInitialDiscovery {
                initialDiscoveryProgress = nil
                initialDiscoveryError = discoveryMessage(
                    for: error,
                    stage: initialDiscoveryStage,
                    preferences: preferences
                )
            }
        }
    }

    func refreshTransactionHistory(
        profile: WalletProfile,
        walletStore: WalletStore,
        force: Bool = false,
        keepProgressVisible: Bool = false
    ) async {
        guard activeProfileID == profile.id else { return }
        let profileGeneration = activeProfileGeneration
        if transactionHistoryProfilesInFlight[profile.id] == profileGeneration { return }
        if !force,
           let lastAttempt = lastTransactionHistoryAttempt[profile.id],
           Date().timeIntervalSince(lastAttempt) < 30 {
            return
        }

        lastTransactionHistoryAttempt[profile.id] = Date()
        transactionHistoryProfilesInFlight[profile.id] = profileGeneration
        isRefreshingTransactionHistory = true
        transactionHistoryProgress = TransactionHistoryProgress(
            profileID: profile.id,
            completedAddresses: 0,
            totalAddresses: 0,
            phase: .locatingAddresses
        )
        transactionHistoryError = nil
        var committedCompleteHistory = false
        defer {
            if transactionHistoryProfilesInFlight[profile.id] == profileGeneration {
                transactionHistoryProfilesInFlight.removeValue(forKey: profile.id)
            }
            isRefreshingTransactionHistory = !transactionHistoryProfilesInFlight.isEmpty
            if keepProgressVisible,
               committedCompleteHistory,
               activeProfileID == profile.id,
               activeProfileGeneration == profileGeneration {
                transactionHistoryProgress = TransactionHistoryProgress(
                    profileID: profile.id,
                    completedAddresses: 1,
                    totalAddresses: 1,
                    phase: .finalizing
                )
                isRefreshingTransactionHistory = true
            } else if !isRefreshingTransactionHistory {
                transactionHistoryProgress = nil
            }
        }

        do {
            let transactions = try await transactionHistoryClient.transactions(
                for: profile
            ) { [weak self] completed, total, isRetrying in
                guard let self,
                      self.activeProfileID == profile.id,
                      self.activeProfileGeneration == profileGeneration else { return }
                self.transactionHistoryProgress = TransactionHistoryProgress(
                    profileID: profile.id,
                    completedAddresses: completed,
                    totalAddresses: total,
                    phase: isRetrying ? .retryingThrottledAddresses : .loadingAddresses
                )
            }
            guard activeProfileID == profile.id,
                  activeProfileGeneration == profileGeneration else { return }
            walletStore.mergeSyncedTransactions(transactions, profileID: profile.id)
            transactionHistoryUpdatedAt = Date()
            committedCompleteHistory = true
        } catch {
            guard activeProfileID == profile.id,
                  activeProfileGeneration == profileGeneration else { return }
            guard !Task.isCancelled,
                  !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            transactionHistoryError = error.localizedDescription
        }
    }

    func prepareTransactionHistoryProgress(profileID: UUID) {
        guard activeProfileID == profileID else { return }
        transactionHistoryProgress = TransactionHistoryProgress(
            profileID: profileID,
            completedAddresses: 0,
            totalAddresses: 0,
            phase: .locatingAddresses
        )
        isRefreshingTransactionHistory = true
    }

    func completeTransactionHistoryReconciliation(profileID: UUID) {
        guard transactionHistoryProgress?.profileID == profileID,
              transactionHistoryProfilesInFlight[profileID] == nil else { return }
        transactionHistoryProgress = nil
        isRefreshingTransactionHistory = !transactionHistoryProfilesInFlight.isEmpty
    }

    func reconcilePendingTransactions(
        profile: WalletProfile,
        walletStore: WalletStore
    ) async {
        let pending = walletStore.pendingTransactions.filter {
            $0.profileID == profile.id
        }
        guard !pending.isEmpty else { return }

        var resolved: [WalletTransaction] = []
        for transaction in pending.prefix(8) {
            do {
                if let indexed = try await transactionHistoryClient.transaction(
                    id: transaction.transactionID,
                    for: profile
                ) {
                    if indexed.acceptingBlockBlueScore != nil {
                        resolved.append(indexed)
                    }
                }
            } catch {
                // The node/indexer may not expose a just-broadcast transaction yet.
                // Keep the local pending card and retry on the next wallet event.
            }
        }
        guard !resolved.isEmpty else { return }
        walletStore.mergeResolvedTransactions(resolved, profileID: profile.id)
    }

    func reconcileTransactionIDs(
        _ transactionIDs: some Sequence<String>,
        profile: WalletProfile,
        walletStore: WalletStore
    ) async {
        let unresolved = Array(Set(transactionIDs.map { $0.lowercased() })).prefix(16)
        var unresolvedIDs = Array(unresolved)
        var resolved: [WalletTransaction] = []

        for attempt in 0..<3 where !unresolvedIDs.isEmpty {
            if attempt > 0 {
                let delay = attempt == 1 ? 2.0 : 5.0
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }

            var stillUnresolved: [String] = []
            for transactionID in unresolvedIDs {
                do {
                    if let indexed = try await transactionHistoryClient.transaction(
                        id: transactionID,
                        for: profile
                    ) {
                        if indexed.acceptingBlockBlueScore != nil {
                            resolved.append(indexed)
                        } else {
                            stillUnresolved.append(transactionID)
                        }
                    } else {
                        stillUnresolved.append(transactionID)
                    }
                } catch {
                    stillUnresolved.append(transactionID)
                }
            }
            unresolvedIDs = stillUnresolved
        }

        guard !resolved.isEmpty else { return }
        walletStore.mergeResolvedTransactions(resolved, profileID: profile.id)
    }

    func reconcileRecentOutgoingTransactions(
        removedOutpointIDs: Set<String> = [],
        addresses: [String],
        profile: WalletProfile,
        walletStore: WalletStore
    ) async {
        var request = outgoingReconciliationRequest(for: profile.id)
        request.outpointIDs.formUnion(removedOutpointIDs)
        request.addresses.formUnion(addresses)
        saveOutgoingReconciliationRequest(request, profileID: profile.id)

        guard !request.outpointIDs.isEmpty,
              !request.addresses.isEmpty else { return }

        for attempt in 0..<3 {
            if attempt > 0 {
                let delay = attempt == 1 ? 2.0 : 5.0
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }

            do {
                let transactions = try await transactionHistoryClient.recentTransactions(
                    for: Array(request.addresses),
                    spending: request.outpointIDs,
                    profile: profile
                )
                guard !transactions.isEmpty else { continue }
                walletStore.mergeResolvedTransactions(
                    transactions,
                    profileID: profile.id
                )
                clearOutgoingReconciliationRequest(profileID: profile.id)
                return
            } catch {
                // The indexer may trail the node briefly. Retry this small,
                // address-scoped lookup without starting a full history scan.
            }
        }
    }

    func reconcileTransactionsObservedByOtherWallets(
        profile: WalletProfile,
        walletStore: WalletStore
    ) async {
        let existingIDs = Set(walletStore.transactions.lazy
            .filter { $0.profileID == profile.id }
            .map { $0.transactionID.lowercased() })
        let candidateIDs = walletStore.transactions
            .filter {
                $0.profileID != profile.id
                    && !existingIDs.contains($0.transactionID.lowercased())
            }
            .sorted { $0.broadcastAt > $1.broadcastAt }
            .prefix(16)
            .map(\.transactionID)
        guard !candidateIDs.isEmpty else { return }

        do {
            let related = try await transactionHistoryClient.transactions(
                ids: candidateIDs,
                for: profile
            )
            walletStore.mergeResolvedTransactions(related, profileID: profile.id)
        } catch {
            // This is a repair path. Normal node-driven refresh remains active
            // and the next wallet selection or pull-to-refresh will retry.
        }
    }

    private struct OutgoingReconciliationRequest: Codable {
        var outpointIDs = Set<String>()
        var addresses = Set<String>()
    }

    private func outgoingReconciliationRequest(
        for profileID: UUID
    ) -> OutgoingReconciliationRequest {
        let fileName = outgoingReconciliationFileName(profileID: profileID)
        if let request = ProtectedWalletStorage.shared.load(
            OutgoingReconciliationRequest.self,
            fileName: fileName
        ) {
            return request
        }
        let legacyKey = outgoingReconciliationKeyPrefix + profileID.uuidString
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let request = try? JSONDecoder().decode(
                  OutgoingReconciliationRequest.self,
                  from: data
              ) else { return OutgoingReconciliationRequest() }
        if ProtectedWalletStorage.shared.save(request, fileName: fileName) {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        return request
    }

    private func saveOutgoingReconciliationRequest(
        _ request: OutgoingReconciliationRequest,
        profileID: UUID
    ) {
        _ = ProtectedWalletStorage.shared.save(
            request,
            fileName: outgoingReconciliationFileName(profileID: profileID)
        )
    }

    private func clearOutgoingReconciliationRequest(profileID: UUID) {
        ProtectedWalletStorage.shared.remove(
            fileName: outgoingReconciliationFileName(profileID: profileID)
        )
        UserDefaults.standard.removeObject(
            forKey: outgoingReconciliationKeyPrefix + profileID.uuidString
        )
    }

    private func outgoingReconciliationFileName(profileID: UUID) -> String {
        "outgoing-reconciliation-\(profileID.uuidString.lowercased()).json"
    }

    private func discoverImportedWallet(
        profile: WalletProfile,
        engine: KasSignerEngine
    ) async throws -> WalletProfile {
        let maximumAddressesPerChain = 512
        let trailingGap = 20

        initialDiscoveryError = nil
        discoveryNotice = nil
        initialDiscoveryCheckpoint = nil
        initialDiscoveryStage = "Deriving wallet addresses"
        initialDiscoveryProgress = DiscoveryProgress(
            title: "Discovering wallet",
            detail: "Deriving receive and change addresses…",
            fraction: 0.12
        )

        let receiveNeeded = max(
            0,
            maximumAddressesPerChain - profile.receiveAddresses.count
        )
        let changeNeeded = max(
            0,
            maximumAddressesPerChain - profile.changeAddresses.count
        )
        let candidates = try await engine.extendAddresses(
            for: profile,
            receiveCount: receiveNeeded,
            changeCount: changeNeeded
        )
        try Task.checkCancellation()

        initialDiscoveryProgress = DiscoveryProgress(
            title: "Scanning address history",
            detail: "Checking historical activity across both address chains…",
            fraction: 0.42
        )
        initialDiscoveryStage = "Scanning address history"
        let allCandidates = candidates.receiveAddresses + candidates.changeAddresses
        let active = try await transactionHistoryClient.activeAddresses(
            in: allCandidates
        )
        try Task.checkCancellation()

        let plan = Self.discoveryPlan(
            receiveAddresses: candidates.receiveAddresses,
            changeAddresses: candidates.changeAddresses,
            activeAddresses: active,
            currentNextReceiveIndex: profile.nextReceiveIndex,
            currentNextChangeIndex: profile.nextChangeIndex,
            trailingGap: trailingGap,
            maximumAddressesPerChain: maximumAddressesPerChain
        )

        var discovered = profile
        discovered.receiveAddresses = Array(
            candidates.receiveAddresses.prefix(plan.receiveCount)
        )
        discovered.changeAddresses = Array(
            candidates.changeAddresses.prefix(plan.changeCount)
        )
        discovered.nextReceiveIndex = plan.nextReceiveIndex
        discovered.nextChangeIndex = plan.nextChangeIndex
        let normalizedActive = Set(active.map { $0.lowercased() })
        discovered.earliestFreshReceiveIndex = discovered.receiveAddresses.firstIndex {
            !normalizedActive.contains($0.lowercased())
        }

        if plan.reachedSafetyLimit {
            discoveryNotice = "Wallet activity reaches the 512-address discovery limit. The discovered range is usable, but a deeper scan is recommended."
        }

        initialDiscoveryProgress = DiscoveryProgress(
            title: "Synchronizing wallet",
            detail: "Loading current UTXOs from the selected Kaspa node…",
            fraction: 0.68
        )
        initialDiscoveryStage = "Synchronizing UTXOs"
        return discovered
    }

    nonisolated static func discoveryPlan(
        receiveAddresses: [String],
        changeAddresses: [String],
        activeAddresses: Set<String>,
        currentNextReceiveIndex: Int,
        currentNextChangeIndex: Int,
        trailingGap: Int = 20,
        maximumAddressesPerChain: Int = 512
    ) -> DiscoveryPlan {
        let normalizedActive = Set(activeAddresses.map { $0.lowercased() })
        func highestActiveIndex(in addresses: [String]) -> Int? {
            addresses.indices.last {
                normalizedActive.contains(addresses[$0].lowercased())
            }
        }
        func retainedCount(highestIndex: Int?, available: Int) -> Int {
            min(
                min(maximumAddressesPerChain, available),
                max(min(20, available), (highestIndex ?? -1) + 1 + trailingGap)
            )
        }

        let highestReceive = highestActiveIndex(in: receiveAddresses)
        let highestChange = highestActiveIndex(in: changeAddresses)
        let warningBoundary = maximumAddressesPerChain - trailingGap
        return DiscoveryPlan(
            receiveCount: retainedCount(
                highestIndex: highestReceive,
                available: receiveAddresses.count
            ),
            changeCount: retainedCount(
                highestIndex: highestChange,
                available: changeAddresses.count
            ),
            nextReceiveIndex: max(
                currentNextReceiveIndex,
                (highestReceive ?? -1) + 1
            ),
            nextChangeIndex: max(
                currentNextChangeIndex,
                (highestChange ?? -1) + 1
            ),
            reachedSafetyLimit: (highestReceive ?? -1) >= warningBoundary
                || (highestChange ?? -1) >= warningBoundary
        )
    }

    private func syncWithAddressDiscovery(
        profile: WalletProfile,
        walletStore: WalletStore,
        engine: KasSignerEngine,
        preferences: AppPreferences
    ) async throws -> (WalletSyncPayload, WalletProfile) {
        let gapLimit = 8
        let derivationBatch = 8
        let maximumAddressesPerChain = 512
        var current = profile

        for _ in 0..<64 {
            try Task.checkCancellation()

            let result = try await engine.syncWallet(
                current,
                nodeConfiguration: preferences.nodeConfiguration
            )

            if let lastFundedReceive = result.balance.fundedReceiveIndices.max() {
                current.nextReceiveIndex = max(
                    current.nextReceiveIndex,
                    lastFundedReceive + 1
                )
            }
            if let lastFundedChange = result.balance.fundedChangeIndices.max() {
                current.nextChangeIndex = max(
                    current.nextChangeIndex,
                    lastFundedChange + 1
                )
            }

            let receiveBoundary = max(
                0,
                current.receiveAddresses.count - gapLimit
            )
            let changeBoundary = max(
                0,
                current.changeAddresses.count - gapLimit
            )
            let receiveNeedsExtension =
                current.receiveAddresses.count < maximumAddressesPerChain
                && (
                    current.nextReceiveIndex >= receiveBoundary
                    || result.balance.fundedReceiveIndices.contains {
                        $0 >= receiveBoundary
                    }
                )
            let changeNeedsExtension =
                current.changeAddresses.count < maximumAddressesPerChain
                && (
                    current.nextChangeIndex >= changeBoundary
                    || result.balance.fundedChangeIndices.contains {
                        $0 >= changeBoundary
                    }
                )

            if !receiveNeedsExtension && !changeNeedsExtension {
                return (result, current)
            }

            let receiveCount = receiveNeedsExtension
                ? min(
                    derivationBatch,
                    maximumAddressesPerChain - current.receiveAddresses.count
                )
                : 0
            let changeCount = changeNeedsExtension
                ? min(
                    derivationBatch,
                    maximumAddressesPerChain - current.changeAddresses.count
                )
                : 0

            guard receiveCount > 0 || changeCount > 0 else {
                return (result, current)
            }

            let derived = try await engine.extendAddresses(
                for: current,
                receiveCount: receiveCount,
                changeCount: changeCount
            )
            current.receiveAddresses = derived.receiveAddresses
            current.changeAddresses = derived.changeAddresses
            if !profile.requiresInitialDiscovery {
                walletStore.update(current)
                walletStore.setLastViewedReceiveIndex(
                    current.nextReceiveIndex,
                    for: current.id,
                    addressCount: current.receiveAddresses.count
                )
            }

            await Task.yield()
        }

        throw KasSignerEngine.EngineError.javascript(
            "Address discovery exceeded its safety limit."
        )
    }

    func reset() {
        activeProfileGeneration &+= 1
        activeProfileID = nil
        lastRefreshAttempt = nil
        snapshot = nil
        feeEstimate = nil
        transactionHistoryError = nil
        transactionHistoryUpdatedAt = nil
        initialDiscoveryProgress = nil
        initialDiscoveryError = nil
        discoveryNotice = nil
        transactionHistoryProfilesInFlight.removeAll()
        isRefreshingTransactionHistory = false
        transactionHistoryProgress = nil
        state = isNetworkAvailable ? .idle : .failed("No internet connection.")
    }

    private func friendlyMessage(for error: Error, preferences: AppPreferences) -> String {
        let message = error.localizedDescription.lowercased()

        if !isNetworkAvailable {
            return "No internet connection."
        }

        if preferences.nodeMode == .custom {
            if preferences.customNodeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter a custom Kaspa node URL in Settings."
            }
            if message.contains("wss://") || message.contains("ws://") {
                return "The custom node URL is invalid. Use a ws:// or wss:// address."
            }
            return "Unable to connect to your custom Kaspa node. Check its address and availability."
        }

        return "Unable to reach the Kaspa network. Check your internet connection and try again."
    }

    private func discoveryMessage(
        for error: Error,
        stage: String,
        preferences: AppPreferences
    ) -> String {
        let detail: String
        if let historyError = error as? TransactionHistoryError {
            detail = historyError.localizedDescription
        } else {
            detail = friendlyMessage(for: error, preferences: preferences)
        }
#if DEBUG
        print("Wallet discovery failed during \(stage): \(error.localizedDescription)")
#endif
        return "\(stage) failed. \(detail)"
    }
}
