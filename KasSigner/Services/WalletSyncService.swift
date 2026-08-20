import Foundation
import Network

struct IndexedTransaction: Decodable, Sendable {
    let transactionID: String?
    let blockTime: Int64?
    let isAccepted: Bool?
    let acceptingBlockTime: Int64?
    let inputs: [IndexedTransactionInput]?
    let outputs: [IndexedTransactionOutput]?

    enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case blockTime = "block_time"
        case isAccepted = "is_accepted"
        case acceptingBlockTime = "accepting_block_time"
        case inputs
        case outputs
    }
}

struct IndexedTransactionInput: Decodable, Sendable {
    let previousOutpointAddress: String?
    let previousOutpointAmount: UInt64?

    enum CodingKeys: String, CodingKey {
        case previousOutpointAddress = "previous_outpoint_address"
        case previousOutpointAmount = "previous_outpoint_amount"
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

private enum TransactionHistoryError: LocalizedError {
    case unsupportedNetwork
    case invalidResponse
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedNetwork:
            "Complete transaction history is currently available for mainnet accounts only."
        case .invalidResponse:
            "The transaction history service returned an invalid response."
        case .server(let status):
            "The transaction history service returned HTTP \(status)."
        }
    }
}

struct TransactionHistoryClient: Sendable {
    private let baseURL = URL(string: "https://api.kaspa.org")!

    func transactions(for profile: WalletProfile) async throws -> [WalletTransaction] {
        guard profile.network.lowercased() == "mainnet" else {
            throw TransactionHistoryError.unsupportedNetwork
        }

        let addresses = Array(Set(profile.receiveAddresses + profile.changeAddresses)).sorted()
        guard !addresses.isEmpty else { return [] }
        let activeAddresses = try await fetchActiveAddresses(addresses)
        guard !activeAddresses.isEmpty else { return [] }

        var indexedTransactions: [IndexedTransaction] = []
        for batchStart in stride(from: 0, to: activeAddresses.count, by: 6) {
            let batchEnd = min(batchStart + 6, activeAddresses.count)
            let batch = activeAddresses[batchStart..<batchEnd]
            let batchResults = try await withThrowingTaskGroup(
                of: [IndexedTransaction].self
            ) { group in
                for address in batch {
                    group.addTask {
                        try await fetchTransactions(for: address)
                    }
                }

                var results: [[IndexedTransaction]] = []
                for try await result in group {
                    results.append(result)
                }
                return results
            }
            indexedTransactions.append(contentsOf: batchResults.flatMap { $0 })
        }

        return mapTransactions(
            indexedTransactions,
            profileID: profile.id,
            walletAddresses: Set(addresses)
        )
    }

    private func fetchActiveAddresses(_ addresses: [String]) async throws -> [String] {
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

            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response)
            let entries = try JSONDecoder().decode([ActiveAddressResponse].self, from: data)
            active.append(contentsOf: entries.filter(\.active).map(\.address))
        }
        return Array(Set(active)).sorted()
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
                URLQueryItem(name: "resolve_previous_outpoints", value: "light"),
                URLQueryItem(name: "acceptance", value: "accepted")
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
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response)
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
        }
        return transactions
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
        walletAddresses: Set<String>
    ) -> [WalletTransaction] {
        var mappedByID: [String: WalletTransaction] = [:]

        for transaction in indexedTransactions where transaction.isAccepted != false {
            guard let rawID = transaction.transactionID else { continue }
            let transactionID = rawID.lowercased()
            guard mappedByID[transactionID] == nil else { continue }

            let inputs = transaction.inputs ?? []
            let outputs = transaction.outputs ?? []
            let walletInputTotal = inputs.reduce(UInt64(0)) { result, input in
                guard let address = input.previousOutpointAddress,
                      walletAddresses.contains(address) else { return result }
                return result &+ (input.previousOutpointAmount ?? 0)
            }
            let walletOutputTotal = outputs.reduce(UInt64(0)) { result, output in
                guard let address = output.scriptPublicKeyAddress,
                      walletAddresses.contains(address) else { return result }
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

            if direction == .sent {
                let externalOutputs = outputs.filter {
                    guard let address = $0.scriptPublicKeyAddress else { return false }
                    return !walletAddresses.contains(address)
                }
                amount = externalOutputs.reduce(UInt64(0)) { $0 &+ $1.amount }
                let addresses = Array(Set(externalOutputs.compactMap(\.scriptPublicKeyAddress)))
                counterparty = addresses.count == 1
                    ? addresses[0]
                    : addresses.isEmpty ? "Self transfer" : "\(addresses.count) recipients"
            } else {
                amount = walletOutputTotal
                let sourceAddresses = Array(Set(inputs.compactMap(\.previousOutpointAddress).filter {
                    !walletAddresses.contains($0)
                }))
                counterparty = sourceAddresses.count == 1
                    ? sourceAddresses[0]
                    : sourceAddresses.isEmpty ? "Coinbase or unknown source" : "Multiple senders"
            }

            let milliseconds = transaction.acceptingBlockTime ?? transaction.blockTime ?? 0
            mappedByID[transactionID] = WalletTransaction(
                profileID: profileID,
                transactionID: transactionID,
                destination: counterparty,
                amountSompi: amount,
                feeSompi: direction == .sent ? fee : 0,
                broadcastAt: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
                direction: direction,
                status: .confirmed
            )
        }

        return mappedByID.values.sorted { $0.broadcastAt > $1.broadcastAt }
    }
}

@MainActor
final class WalletSnapshotCache {

    static let shared = WalletSnapshotCache()

    private let prefix = "kassigner.walletSnapshot.v1."

    private init() {}

    func load(profileID: UUID) -> WalletSyncPayload? {
        let key = prefix + profileID.uuidString

        guard
            let data = UserDefaults.standard.data(forKey: key),
            let snapshot = try? JSONDecoder().decode(WalletSyncPayload.self, from: data)
        else {
            return nil
        }

        return snapshot
    }

    func save(_ snapshot: WalletSyncPayload, profileID: UUID) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }

        UserDefaults.standard.set(
            data,
            forKey: prefix + profileID.uuidString
        )
    }

    func remove(profileID: UUID) {
        UserDefaults.standard.removeObject(
            forKey: prefix + profileID.uuidString
        )
    }
}

@MainActor
final class WalletSyncService: ObservableObject {
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
    @Published private(set) var transactionHistoryError: String?
    @Published private(set) var transactionHistoryUpdatedAt: Date?

    private var activeProfileID: UUID?
    private var lastRefreshAttempt: Date?
    private var lastTransactionHistoryAttempt: [UUID: Date] = [:]
    private var transactionHistoryProfilesInFlight = Set<UUID>()
    private let transactionHistoryClient = TransactionHistoryClient()
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "org.kassigner.KasSigner.network-monitor")

    func preload(profile: WalletProfile) {
        guard activeProfileID != profile.id else { return }

        activeProfileID = profile.id
        lastRefreshAttempt = nil
        state = isNetworkAvailable ? .idle : .failed("No internet connection.")

        snapshot = WalletSnapshotCache.shared.load(profileID: profile.id)
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
        minimumInterval: TimeInterval = 9
    ) async {
        guard isNetworkAvailable else {
            state = .failed("No internet connection.")
            return
        }

        if case .syncing = state { return }

        if !force,
           activeProfileID == profile.id,
           let lastRefreshAttempt,
           Date().timeIntervalSince(lastRefreshAttempt) < minimumInterval {
            return
        }

        activeProfileID = profile.id

        if snapshot == nil,
           let cached = WalletSnapshotCache.shared.load(profileID: profile.id) {
            snapshot = cached
        }

        lastRefreshAttempt = Date()
        state = .syncing

        do {
            let (result, discoveredProfile) = try await syncWithAddressDiscovery(
                profile: walletStore.profiles.first(where: { $0.id == profile.id })
                    ?? profile,
                walletStore: walletStore,
                engine: engine,
                preferences: preferences
            )
            guard activeProfileID == profile.id else { return }
            if discoveredProfile != profile {
                walletStore.update(discoveredProfile)
                walletStore.setLastViewedReceiveIndex(
                    discoveredProfile.nextReceiveIndex,
                    for: discoveredProfile.id,
                    addressCount: discoveredProfile.receiveAddresses.count
                )
            }
            snapshot = result
            do {
                feeEstimate = try await engine.getFeeEstimate(
                    nodeConfiguration: preferences.nodeConfiguration
                )
            } catch {
                // Preserve the last valid estimate if a refresh temporarily fails.
            }

            WalletSnapshotCache.shared.save(
                result,
                profileID: profile.id
            )
            state = .connected
            await refreshTransactionHistory(
                profile: discoveredProfile,
                walletStore: walletStore
            )
        } catch {
            guard activeProfileID == profile.id else { return }
            state = .failed(friendlyMessage(for: error, preferences: preferences))
        }
    }

    func refreshTransactionHistory(
        profile: WalletProfile,
        walletStore: WalletStore,
        force: Bool = false
    ) async {
        if transactionHistoryProfilesInFlight.contains(profile.id) { return }
        if !force,
           let lastAttempt = lastTransactionHistoryAttempt[profile.id],
           Date().timeIntervalSince(lastAttempt) < 30 {
            return
        }

        lastTransactionHistoryAttempt[profile.id] = Date()
        transactionHistoryProfilesInFlight.insert(profile.id)
        isRefreshingTransactionHistory = true
        transactionHistoryError = nil
        defer {
            transactionHistoryProfilesInFlight.remove(profile.id)
            isRefreshingTransactionHistory = !transactionHistoryProfilesInFlight.isEmpty
        }

        do {
            let transactions = try await transactionHistoryClient.transactions(for: profile)
            guard activeProfileID == profile.id else { return }
            walletStore.mergeSyncedTransactions(transactions, profileID: profile.id)
            transactionHistoryUpdatedAt = Date()
        } catch {
            guard activeProfileID == profile.id else { return }
            transactionHistoryError = error.localizedDescription
        }
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
            walletStore.update(current)
            walletStore.setLastViewedReceiveIndex(
                current.nextReceiveIndex,
                for: current.id,
                addressCount: current.receiveAddresses.count
            )

            await Task.yield()
        }

        throw KasSignerEngine.EngineError.javascript(
            "Address discovery exceeded its safety limit."
        )
    }

    func reset() {
        activeProfileID = nil
        lastRefreshAttempt = nil
        snapshot = nil
        feeEstimate = nil
        transactionHistoryError = nil
        transactionHistoryUpdatedAt = nil
        transactionHistoryProfilesInFlight.removeAll()
        isRefreshingTransactionHistory = false
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
}
