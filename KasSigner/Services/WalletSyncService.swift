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

struct TransactionGraphInput: Identifiable, Codable, Equatable, Sendable {
    let outpoint: String
    let address: String?
    let amountSompi: UInt64?

    var id: String { outpoint }
}

struct TransactionGraphOutput: Identifiable, Codable, Equatable, Sendable {
    let index: Int
    let address: String?
    let amountSompi: UInt64

    var id: Int { index }
}

struct TransactionGraphDetails: Codable, Equatable, Sendable {
    let transactionID: String
    let inputs: [TransactionGraphInput]
    let outputs: [TransactionGraphOutput]
    let feeSompi: UInt64?

    var hasUnresolvedDetails: Bool {
        inputs.contains {
            !($0.address.map(TransactionGraphAddress.hasPlausibleFormat) ?? false)
                || $0.amountSompi == nil
        } || outputs.contains {
            !($0.address.map(TransactionGraphAddress.hasPlausibleFormat) ?? false)
        }
    }
}

enum TransactionGraphAddress {
    private static let alphabet = Set("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    static func hasPlausibleFormat(_ address: String) -> Bool {
        let normalized = address.lowercased()
        let prefix: String
        if normalized.hasPrefix("kaspa:") {
            prefix = "kaspa:"
        } else if normalized.hasPrefix("kaspatest:") {
            prefix = "kaspatest:"
        } else {
            return false
        }
        let payload = normalized.dropFirst(prefix.count)
        return payload.count > 8 && payload.allSatisfy { alphabet.contains($0) }
    }
}

struct TransactionHistorySyncResult {
    let transactions: [WalletTransaction]
    let graphs: [TransactionGraphDetails]
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

    func virtualBlueScore(network: KaspaNetwork = .mainnet) async throws -> UInt64 {
        let scoreBaseURL = network == .testnet10
            ? URL(string: "https://api-tn10.kaspa.org")! : baseURL
        let request = URLRequest(
            url: scoreBaseURL.appending(path: "info/virtual-chain-blue-score")
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
    ) async throws -> TransactionHistorySyncResult {
        guard profile.network.lowercased() == "mainnet" else {
            throw TransactionHistoryError.unsupportedNetwork
        }

        let addresses = Array(Set(profile.receiveAddresses + profile.changeAddresses)).sorted()
        guard !addresses.isEmpty else {
            return TransactionHistorySyncResult(transactions: [], graphs: [])
        }
        let activeAddresses = try await activeAddresses(in: addresses).sorted()
        guard !activeAddresses.isEmpty else {
            return TransactionHistorySyncResult(transactions: [], graphs: [])
        }

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

        let graphs = indexedTransactions.compactMap { indexed -> TransactionGraphDetails? in
            guard indexed.inputs != nil,
                  indexed.outputs != nil,
                  let transactionID = indexed.transactionID else { return nil }
            return try? makeTransactionGraph(indexed, fallbackID: transactionID)
        }
        let uniqueGraphs = Dictionary(
            graphs.map { ($0.transactionID, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.transactionID < $1.transactionID }

        return TransactionHistorySyncResult(
            transactions: mapTransactions(
                indexedTransactions,
                profileID: profile.id,
                receiveAddresses: Set(profile.receiveAddresses),
                changeAddresses: Set(profile.changeAddresses)
            ),
            graphs: uniqueGraphs
        )
    }

    func transaction(
        id: String,
        for profile: WalletProfile
    ) async throws -> WalletTransaction? {
        let transactionBaseURL: URL
        switch profile.network.lowercased() {
        case KaspaNetwork.mainnet.rawValue:
            transactionBaseURL = baseURL
        case KaspaNetwork.testnet10.rawValue:
            transactionBaseURL = URL(string: "https://api-tn10.kaspa.org")!
        default:
            return nil
        }
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedID.isEmpty else { return nil }

        var components = URLComponents(
            url: transactionBaseURL.appending(path: "transactions").appending(path: normalizedID),
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

    func transactionGraph(
        id: String,
        for profile: WalletProfile
    ) async throws -> TransactionGraphDetails? {
        guard profile.network.lowercased() == "mainnet" else {
            throw TransactionHistoryError.unsupportedNetwork
        }
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedID.isEmpty else { return nil }

        var components = URLComponents(
            url: baseURL.appending(path: "transactions").appending(path: normalizedID),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "resolve_previous_outpoints", value: "light")
        ]
        guard let url = components.url else {
            throw TransactionHistoryError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, _) = try await data(for: request)
        let indexed = try JSONDecoder().decode(IndexedTransaction.self, from: data)
        if let responseID = indexed.transactionID,
           responseID.lowercased() != normalizedID {
            throw TransactionHistoryError.invalidResponse
        }
        return try makeTransactionGraph(indexed, fallbackID: normalizedID)
    }

    func makeTransactionGraph(
        _ indexed: IndexedTransaction,
        fallbackID: String
    ) throws -> TransactionGraphDetails {
        guard let indexedInputs = indexed.inputs,
              let indexedOutputs = indexed.outputs else {
            throw TransactionHistoryError.invalidResponse
        }
        let inputs = indexedInputs.enumerated().map { offset, input in
            let hash = input.previousOutpointHash?.lowercased()
            let outpoint: String
            if let hash, let index = input.previousOutpointIndex {
                outpoint = "\(hash):\(index)"
            } else {
                outpoint = "input-\(offset)"
            }
            return TransactionGraphInput(
                outpoint: outpoint,
                address: input.previousOutpointAddress,
                amountSompi: input.previousOutpointAmount
            )
        }
        let outputs = indexedOutputs.enumerated().map { index, output in
            TransactionGraphOutput(
                index: index,
                address: output.scriptPublicKeyAddress,
                amountSompi: output.amount
            )
        }
        let totalInput = inputs.compactMap(\.amountSompi).reduce(UInt64(0), &+)
        let hasEveryInputAmount = inputs.allSatisfy { $0.amountSompi != nil }
        let totalOutput = outputs.reduce(UInt64(0)) { $0 &+ $1.amountSompi }
        let fee = hasEveryInputAmount && totalInput >= totalOutput
            ? totalInput - totalOutput
            : nil

        return TransactionGraphDetails(
            transactionID: indexed.transactionID?.lowercased() ?? fallbackID,
            inputs: inputs,
            outputs: outputs,
            feeSompi: fee
        )
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
final class TransactionGraphCache {
    private struct DiskCache: Codable, Sendable {
        let schemaVersion: Int
        let graphs: [String: TransactionGraphDetails]
        let lastRefreshedAt: [String: Date]?
    }

    static let shared = TransactionGraphCache()

    private let storage: ProtectedWalletStorage
    private let persistenceQueue = DispatchQueue(
        label: "org.kassigner.transactionGraphCache.persistence",
        qos: .utility
    )
    private var loadedProfiles = Set<UUID>()
    private var loadingProfiles: [UUID: Task<DiskCache?, Never>] = [:]
    private var profileGenerations: [UUID: UInt64] = [:]
    private var graphsByProfile: [UUID: [String: TransactionGraphDetails]] = [:]
    private var refreshDatesByProfile: [UUID: [String: Date]] = [:]
    private var dirtyProfiles = Set<UUID>()
    private var persistenceVersions: [UUID: UInt64] = [:]

    init(storage: ProtectedWalletStorage = .shared) {
        self.storage = storage
    }

    func graph(profileID: UUID, transactionID: String) async -> TransactionGraphDetails? {
        await loadIfNeeded(profileID: profileID)
        return graphsByProfile[profileID]?[normalizedID(transactionID)]
    }

    func shouldRefresh(_ graph: TransactionGraphDetails, profileID: UUID) -> Bool {
        guard graph.hasUnresolvedDetails else { return false }
        guard let lastRefresh = refreshDatesByProfile[profileID]?[normalizedID(graph.transactionID)] else {
            return true
        }
        let elapsed = Date().timeIntervalSince(lastRefresh)
        return elapsed < 0 || elapsed >= 15 * 60
    }

    func save(
        _ graphs: [TransactionGraphDetails],
        profileID: UUID,
        markRefreshed: Bool = false
    ) async {
        guard !graphs.isEmpty else { return }
        let generation = profileGenerations[profileID, default: 0]
        await loadIfNeeded(profileID: profileID)
        guard profileGenerations[profileID, default: 0] == generation else { return }

        var refreshDates = refreshDatesByProfile[profileID, default: [:]]
        var changed = false
        for graph in graphs {
            let id = normalizedID(graph.transactionID)
            if let existing = graphsByProfile[profileID]?[id],
               !existing.hasUnresolvedDetails,
               graph.hasUnresolvedDetails {
                continue
            }
            if graphsByProfile[profileID]?[id] != graph {
                graphsByProfile[profileID, default: [:]][id] = graph
                refreshDates.removeValue(forKey: id)
                changed = true
            }
            if graph.hasUnresolvedDetails, markRefreshed {
                refreshDates[id] = Date()
                changed = true
            } else if !graph.hasUnresolvedDetails,
                      refreshDates.removeValue(forKey: id) != nil {
                changed = true
            }
        }
        guard changed || dirtyProfiles.contains(profileID) else { return }
        refreshDatesByProfile[profileID] = refreshDates
        dirtyProfiles.insert(profileID)
        persistenceVersions[profileID, default: 0] &+= 1
        let version = persistenceVersions[profileID, default: 0]
        let saved = await persist(
            graphsByProfile[profileID, default: [:]],
            refreshDates: refreshDates,
            profileID: profileID
        )
        if saved,
           profileGenerations[profileID, default: 0] == generation,
           persistenceVersions[profileID] == version {
            dirtyProfiles.remove(profileID)
        }
    }

    func remove(profileID: UUID) {
        profileGenerations[profileID, default: 0] &+= 1
        loadedProfiles.remove(profileID)
        loadingProfiles.removeValue(forKey: profileID)
        graphsByProfile.removeValue(forKey: profileID)
        refreshDatesByProfile.removeValue(forKey: profileID)
        dirtyProfiles.remove(profileID)
        persistenceVersions.removeValue(forKey: profileID)
        let name = fileName(profileID: profileID)
        let directoryURL = storage.directoryURL
        persistenceQueue.sync {
            ProtectedWalletStorage(directoryURL: directoryURL).remove(fileName: name)
        }
    }

    private func loadIfNeeded(profileID: UUID) async {
        guard !loadedProfiles.contains(profileID) else { return }
        let generation = profileGenerations[profileID, default: 0]
        let task: Task<DiskCache?, Never>
        if let existing = loadingProfiles[profileID] {
            task = existing
        } else {
            let name = fileName(profileID: profileID)
            let directoryURL = storage.directoryURL
            let queue = persistenceQueue
            task = Task {
                await withCheckedContinuation { continuation in
                    queue.async {
                        let diskStorage = ProtectedWalletStorage(directoryURL: directoryURL)
                        continuation.resume(returning: diskStorage.load(DiskCache.self, fileName: name))
                    }
                }
            }
            loadingProfiles[profileID] = task
        }
        let cache = await task.value
        guard profileGenerations[profileID, default: 0] == generation,
              loadedProfiles.insert(profileID).inserted else { return }
        loadingProfiles.removeValue(forKey: profileID)
        guard cache?.schemaVersion == 1 else { return }
        graphsByProfile[profileID] = cache?.graphs ?? [:]
        refreshDatesByProfile[profileID] = cache?.lastRefreshedAt ?? [:]
    }

    private func persist(
        _ graphs: [String: TransactionGraphDetails],
        refreshDates: [String: Date],
        profileID: UUID
    ) async -> Bool {
        let cache = DiskCache(
            schemaVersion: 1,
            graphs: graphs,
            lastRefreshedAt: refreshDates
        )
        let name = fileName(profileID: profileID)
        let directoryURL = storage.directoryURL
        return await withCheckedContinuation { continuation in
            persistenceQueue.async {
                let diskStorage = ProtectedWalletStorage(directoryURL: directoryURL)
                continuation.resume(returning: diskStorage.save(cache, fileName: name))
            }
        }
    }

    private func normalizedID(_ transactionID: String) -> String {
        transactionID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func fileName(profileID: UUID) -> String {
        "transaction-graphs-\(profileID.uuidString.lowercased()).json"
    }
}

@MainActor
final class WalletSyncService: ObservableObject {
    static let cachedVirtualBlueScoreKey = "kassigner.mainnetVirtualBlueScore.v1"
    static let cachedTestnetVirtualBlueScoreKey = "kassigner.testnet10VirtualBlueScore.v1"

    enum AddressDiscoveryPolicy {
        case lightweight
        case comprehensive
    }

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
            case waitingForIndexer
            case retryingThrottledAddresses
            case finalizing
        }

        let profileID: UUID
        let completedAddresses: Int
        let totalAddresses: Int
        let phase: Phase

        var fraction: Double? {
            if phase == .finalizing { return 0.99 }
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
            case .waitingForIndexer:
                return "Kaspa's history indexer is slow. Waiting on remaining addresses…"
            case .retryingThrottledAddresses:
                return "Kaspa is busy. Retrying remaining addresses…"
            case .finalizing:
                return "Finalizing transaction history…"
            }
        }
    }

    private struct InitialDiscoveryCheckpoint {
        let profile: WalletProfile
    }

    private struct RefreshRequest {
        var profile: WalletProfile
        var walletStore: WalletStore
        var engine: KasSignerEngine
        var preferences: AppPreferences
        var force: Bool
        var minimumInterval: TimeInterval
        var includeTransactionHistory: Bool
        var forceTransactionHistory: Bool
        var keepTransactionProgressThroughReconciliation: Bool
        var addressDiscoveryPolicy: AddressDiscoveryPolicy
        var onWalletReady: [() -> Void]

        mutating func merge(_ other: RefreshRequest) {
            profile = other.profile
            preferences = other.preferences
            force = force || other.force
            minimumInterval = min(minimumInterval, other.minimumInterval)
            includeTransactionHistory = includeTransactionHistory || other.includeTransactionHistory
            forceTransactionHistory = forceTransactionHistory || other.forceTransactionHistory
            keepTransactionProgressThroughReconciliation =
                keepTransactionProgressThroughReconciliation
                || other.keepTransactionProgressThroughReconciliation
            if other.addressDiscoveryPolicy == .comprehensive {
                addressDiscoveryPolicy = .comprehensive
            }
            onWalletReady.append(contentsOf: other.onWalletReady)
        }
    }

    private struct HistoryRefreshRequest {
        var profile: WalletProfile
        var walletStore: WalletStore
        var force: Bool
        var keepProgressVisible: Bool

        mutating func merge(_ other: HistoryRefreshRequest) {
            profile = other.profile
            force = force || other.force
            keepProgressVisible = keepProgressVisible || other.keepProgressVisible
        }
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
    @Published private(set) var historicalDiscoveryError: String?
    @Published private(set) var isCheckingHistoricalAddresses = false
    private var initialDiscoveryStage = "Preparing wallet discovery"
    private var initialDiscoveryCheckpoint: InitialDiscoveryCheckpoint?

    private var activeProfileID: UUID?
    private var activeProfileGeneration: UInt64 = 0
    private var lastRefreshAttempt: Date?
    private var lastTransactionHistoryAttempt: [UUID: Date] = [:]
    private var transactionHistoryProfilesInFlight: [UUID: UInt64] = [:]
    private var initialHistoryReadyToRevealProfileID: UUID?
    private var pendingInitialHistoryPersistence: (
        profileID: UUID,
        generation: UInt64,
        history: TransactionHistorySyncResult
    )?
    private var transactionProgressStallTask: Task<Void, Never>?
    private var initialHistoryRun: (
        id: UUID,
        profileID: UUID,
        generation: UInt64,
        task: Task<Void, Never>
    )?
    private var refreshRun: (
        profileID: UUID,
        generation: UInt64,
        includesHistory: Bool,
        forcesHistory: Bool,
        keepsHistoryProgress: Bool,
        discoveryPolicy: AddressDiscoveryPolicy,
        task: Task<Void, Never>
    )?
    private var queuedRefresh: RefreshRequest?
    private var historyRefreshRun: (
        profileID: UUID,
        generation: UInt64,
        keepsProgress: Bool,
        task: Task<Void, Never>
    )?
    private var queuedHistoryRefresh: HistoryRefreshRequest?
    private var historicalDiscoveryRun: (
        profileID: UUID,
        generation: UInt64,
        task: Task<Void, Never>
    )?
    private var lastHistoricalDiscoveryAttempt: [UUID: Date] = [:]
    private var virtualBlueScoreRefreshInFlight = false
    private var lastVirtualBlueScoreAttempt: Date?
    private var latestObservedVirtualBlueScore: UInt64?
    private var activeNetwork: KaspaNetwork = .mainnet
    private var lastVirtualBlueScorePersistenceAt: Date?
    private let transactionHistoryClient = TransactionHistoryClient()
    private let defaults: UserDefaults
    private let outgoingReconciliationKeyPrefix =
        "kassigner.outgoingReconciliation.v1."
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "org.kassigner.KasSigner.network-monitor")

    func preload(profile: WalletProfile?) {
        guard activeProfileID != profile?.id || (profile == nil && snapshot != nil) else { return }

        if initialDiscoveryCheckpoint?.profile.id != profile?.id {
            initialDiscoveryCheckpoint = nil
        }
        activeProfileGeneration &+= 1
        refreshRun?.task.cancel()
        refreshRun = nil
        queuedRefresh = nil
        historyRefreshRun?.task.cancel()
        historyRefreshRun = nil
        queuedHistoryRefresh = nil
        historicalDiscoveryRun?.task.cancel()
        historicalDiscoveryRun = nil
        isCheckingHistoricalAddresses = false
        historicalDiscoveryError = nil
        initialHistoryRun?.task.cancel()
        initialHistoryRun = nil
        transactionProgressStallTask?.cancel()
        transactionProgressStallTask = nil
        transactionHistoryProfilesInFlight.removeAll()
        isRefreshingTransactionHistory = false
        transactionHistoryProgress = nil
        activeProfileID = profile?.id
        activeNetwork = profile?.network == KaspaNetwork.testnet10.rawValue ? .testnet10 : .mainnet
        let scoreCacheKey = activeNetwork == .testnet10
            ? Self.cachedTestnetVirtualBlueScoreKey : Self.cachedVirtualBlueScoreKey
        virtualBlueScore = defaults.string(forKey: scoreCacheKey).flatMap(UInt64.init)
        latestObservedVirtualBlueScore = nil
        lastRefreshAttempt = nil
        transactionHistoryError = nil
        transactionHistoryUpdatedAt = nil
        initialDiscoveryProgress = nil
        initialDiscoveryError = nil
        discoveryNotice = nil
        initialHistoryReadyToRevealProfileID = nil
        pendingInitialHistoryPersistence = nil
        lastVirtualBlueScoreAttempt = nil
        state = isNetworkAvailable ? .idle : .failed("No internet connection.")

        snapshot = profile.flatMap { WalletSnapshotCache.shared.load(profileID: $0.id) }
    }

    func clearDiscoveryNotice() {
        discoveryNotice = nil
    }

    func checkHistoricalAddressesIfNeeded(
        profile: WalletProfile,
        walletStore: WalletStore,
        engine: KasSignerEngine,
        preferences: AppPreferences,
        force: Bool = false
    ) async {
        guard activeProfileID == profile.id,
              !profile.requiresInitialDiscovery,
              !profile.requiresInitialHistorySync else { return }
        let generation = activeProfileGeneration
        if let run = historicalDiscoveryRun,
           run.profileID == profile.id,
           run.generation == generation {
            await run.task.value
            return
        }

        let latest = walletStore.profiles.first(where: { $0.id == profile.id }) ?? profile
        let now = Date()
        if !force,
           let lastCheck = latest.lastHistoricalDiscoveryAt,
           now.timeIntervalSince(lastCheck) < 5 * 60 {
            return
        }
        if !force,
           let lastAttempt = lastHistoricalDiscoveryAttempt[profile.id],
           now.timeIntervalSince(lastAttempt) < 60 {
            return
        }
        guard isNetworkAvailable else {
            return
        }
        guard profile.network.lowercased() == "mainnet" else {
            historicalDiscoveryError = "Historical address coverage is available for mainnet accounts only."
            return
        }
        guard preferences.activeNodeMode == .automatic else {
            historicalDiscoveryError = "Historical address coverage needs Automatic Nodes. Current UTXOs can still refresh."
            return
        }

        lastHistoricalDiscoveryAttempt[profile.id] = now
        historicalDiscoveryError = nil
        isCheckingHistoricalAddresses = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeProfileID == profile.id,
                   self.activeProfileGeneration == generation {
                    self.isCheckingHistoricalAddresses = false
                    self.historicalDiscoveryRun = nil
                }
            }
            do {
                let maximumAddressesPerChain = 512
                let candidates = try await engine.extendAddresses(
                    for: latest,
                    receiveCount: max(0, maximumAddressesPerChain - latest.receiveAddresses.count),
                    changeCount: max(0, maximumAddressesPerChain - latest.changeAddresses.count)
                )
                try Task.checkCancellation()
                let active = try await self.transactionHistoryClient.activeAddresses(
                    in: candidates.receiveAddresses + candidates.changeAddresses
                )
                try Task.checkCancellation()
                guard self.activeProfileID == profile.id,
                      self.activeProfileGeneration == generation,
                      let current = walletStore.profiles.first(where: { $0.id == profile.id })
                else { return }

                let plan = Self.discoveryPlan(
                    receiveAddresses: candidates.receiveAddresses,
                    changeAddresses: candidates.changeAddresses,
                    activeAddresses: active,
                    currentNextReceiveIndex: current.nextReceiveIndex,
                    currentNextChangeIndex: current.nextChangeIndex
                )
                var discovered = current
                discovered.receiveAddresses = Array(candidates.receiveAddresses.prefix(plan.receiveCount))
                discovered.changeAddresses = Array(candidates.changeAddresses.prefix(plan.changeCount))
                discovered.nextReceiveIndex = plan.nextReceiveIndex
                discovered.nextChangeIndex = plan.nextChangeIndex
                discovered.lastHistoricalDiscoveryAt = Date()
                let normalizedActive = Set(active.map { $0.lowercased() })
                discovered.earliestFreshReceiveIndex = discovered.receiveAddresses.firstIndex {
                    !normalizedActive.contains($0.lowercased())
                }
                let addressesChanged = discovered.receiveAddresses != current.receiveAddresses
                    || discovered.changeAddresses != current.changeAddresses
                    || discovered.nextReceiveIndex != current.nextReceiveIndex
                    || discovered.nextChangeIndex != current.nextChangeIndex
                let didPersist = walletStore.update(discovered)
                if !didPersist {
                    // A failed write must not make this session believe the
                    // historical check will survive an app restart.
                    discovered.lastHistoricalDiscoveryAt = current.lastHistoricalDiscoveryAt
                    _ = walletStore.update(discovered)
                    self.historicalDiscoveryError = "The updated address range could not be saved. Check device storage, then retry the address check."
                }
                if addressesChanged {
                    await self.refresh(
                        profile: discovered,
                        walletStore: walletStore,
                        engine: engine,
                        preferences: preferences,
                        force: true,
                        includeTransactionHistory: true,
                        forceTransactionHistory: true
                    )
                    if case .failed = self.state {
                        self.historicalDiscoveryError = "New addresses were found, but current UTXOs could not be refreshed. Reconnect and try again."
                    }
                }
            } catch is CancellationError {
                self.lastHistoricalDiscoveryAttempt.removeValue(forKey: profile.id)
            } catch {
                guard self.activeProfileID == profile.id,
                      self.activeProfileGeneration == generation else { return }
                self.historicalDiscoveryError = "Historical address coverage could not be checked. Cached addresses and current UTXOs remain available. Pull to refresh to retry."
            }
        }
        historicalDiscoveryRun = (profile.id, generation, task)
        await task.value
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

        let requestedNetwork = activeNetwork
        do {
            let fetchedScore = try await transactionHistoryClient.virtualBlueScore(network: requestedNetwork)
            guard activeNetwork == requestedNetwork else {
                virtualBlueScoreRefreshInFlight = false
                return
            }
            rememberVirtualBlueScore(fetchedScore)
        } catch {
            // Keep the last node-driven score when a transient request fails.
        }

        virtualBlueScoreRefreshInFlight = false
    }

    func rememberVirtualBlueScore(_ score: UInt64) {
        guard score > (virtualBlueScore ?? 0) else { return }
        virtualBlueScore = score
        let cacheKey = activeNetwork == .testnet10
            ? Self.cachedTestnetVirtualBlueScoreKey : Self.cachedVirtualBlueScoreKey
        defaults.set(String(score), forKey: cacheKey)
    }

    func observeVirtualBlueScore(_ score: UInt64) {
        guard score > (latestObservedVirtualBlueScore ?? virtualBlueScore ?? 0) else { return }
        latestObservedVirtualBlueScore = score
        let now = Date()
        if lastVirtualBlueScorePersistenceAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
            persistObservedVirtualBlueScore()
        }
    }

    func persistObservedVirtualBlueScore() {
        guard let score = latestObservedVirtualBlueScore else { return }
        rememberVirtualBlueScore(score)
        lastVirtualBlueScorePersistenceAt = Date()
    }

    func transactionGraph(
        transactionID: String,
        profile: WalletProfile
    ) async throws -> TransactionGraphDetails {
        let cachedGraph = await TransactionGraphCache.shared.graph(
            profileID: profile.id,
            transactionID: transactionID
        )
        if let cachedGraph,
           !TransactionGraphCache.shared.shouldRefresh(cachedGraph, profileID: profile.id) {
            return cachedGraph
        }
        guard isNetworkAvailable else {
            if let cachedGraph { return cachedGraph }
            throw URLError(.notConnectedToInternet)
        }
        do {
            guard let graph = try await transactionHistoryClient.transactionGraph(
                id: transactionID,
                for: profile
            ) else {
                throw TransactionHistoryError.invalidResponse
            }
            await TransactionGraphCache.shared.save(
                [graph],
                profileID: profile.id,
                markRefreshed: true
            )
            return graph
        } catch {
            if let cachedGraph { return cachedGraph }
            throw error
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        virtualBlueScore = defaults.string(forKey: Self.cachedVirtualBlueScoreKey)
            .flatMap(UInt64.init)
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
        forceTransactionHistory: Bool = false,
        keepTransactionProgressThroughReconciliation: Bool = false,
        addressDiscoveryPolicy: AddressDiscoveryPolicy = .lightweight,
        onWalletReady: (() -> Void)? = nil
    ) async {
        if activeProfileID != profile.id {
            preload(profile: profile)
        }
        let generation = activeProfileGeneration
        let request = RefreshRequest(
            profile: profile,
            walletStore: walletStore,
            engine: engine,
            preferences: preferences,
            force: force,
            minimumInterval: minimumInterval,
            includeTransactionHistory: includeTransactionHistory && profile.network == "mainnet",
            forceTransactionHistory: forceTransactionHistory && profile.network == "mainnet",
            keepTransactionProgressThroughReconciliation: keepTransactionProgressThroughReconciliation,
            addressDiscoveryPolicy: addressDiscoveryPolicy,
            onWalletReady: onWalletReady.map { [$0] } ?? []
        )

        if let run = refreshRun,
           run.profileID == profile.id,
           run.generation == generation {
            if !force,
               (!includeTransactionHistory || run.includesHistory),
               (!forceTransactionHistory || run.forcesHistory),
               (!keepTransactionProgressThroughReconciliation || run.keepsHistoryProgress),
               (addressDiscoveryPolicy == .lightweight
                   || run.discoveryPolicy == .comprehensive) {
                await run.task.value
                if activeProfileID == profile.id,
                   activeProfileGeneration == generation,
                   state == .connected {
                    onWalletReady?()
                }
                return
            }
            if queuedRefresh == nil {
                queuedRefresh = request
            } else {
                queuedRefresh?.merge(request)
            }
            await run.task.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var nextRequest: RefreshRequest? = request
            while let current = nextRequest,
                  !Task.isCancelled,
                  self.activeProfileID == profile.id,
                  self.activeProfileGeneration == generation {
                let latestProfile = current.walletStore.profiles.first {
                    $0.id == profile.id
                } ?? current.profile
                await self.performRefresh(
                    profile: latestProfile,
                    walletStore: current.walletStore,
                    engine: current.engine,
                    preferences: current.preferences,
                    force: current.force,
                    minimumInterval: current.minimumInterval,
                    includeTransactionHistory: current.includeTransactionHistory,
                    forceTransactionHistory: current.forceTransactionHistory,
                    keepTransactionProgressThroughReconciliation:
                        current.keepTransactionProgressThroughReconciliation,
                    addressDiscoveryPolicy: current.addressDiscoveryPolicy,
                    onWalletReady: {
                        current.onWalletReady.forEach { $0() }
                    }
                )
                nextRequest = self.queuedRefresh
                self.queuedRefresh = nil
            }
            if self.activeProfileID == profile.id,
               self.activeProfileGeneration == generation {
                self.refreshRun = nil
            }
        }
        refreshRun = (
            profile.id,
            generation,
            includeTransactionHistory,
            forceTransactionHistory,
            keepTransactionProgressThroughReconciliation,
            addressDiscoveryPolicy,
            task
        )
        await task.value
    }

    func refreshAfterBroadcast(
        profileID: UUID,
        walletStore: WalletStore,
        protectedVaultStore: ProtectedVaultStore,
        engine: KasSignerEngine,
        preferences: AppPreferences
    ) async {
        guard let profile = walletStore.profiles.first(where: { $0.id == profileID }),
              walletStore.selectedProfileID == profileID else { return }
        await refresh(
            profile: profile,
            walletStore: walletStore,
            engine: engine,
            preferences: preferences,
            force: true,
            includeTransactionHistory: false
        )
        await reconcilePendingTransactions(
            profile: walletStore.profiles.first(where: { $0.id == profileID }) ?? profile,
            walletStore: walletStore
        )
        await protectedVaultStore.refreshAllOnChain(
            profileID: profileID,
            engine: engine,
            preferences: preferences
        )
    }

    private func performRefresh(
        profile: WalletProfile,
        walletStore: WalletStore,
        engine: KasSignerEngine,
        preferences: AppPreferences,
        force: Bool,
        minimumInterval: TimeInterval,
        includeTransactionHistory: Bool,
        forceTransactionHistory: Bool,
        keepTransactionProgressThroughReconciliation: Bool,
        addressDiscoveryPolicy: AddressDiscoveryPolicy,
        onWalletReady: (() -> Void)?
    ) async {
        guard isNetworkAvailable else {
            state = .failed("No internet connection.")
            if profile.requiresInitialDiscovery {
                initialDiscoveryProgress = nil
                initialDiscoveryError = "Connect to the internet and retry discovery. The wallet has not been opened."
            } else if profile.requiresInitialHistorySync {
                transactionHistoryError = "Connect to the internet, then retry the initial transaction sync."
            }
            return
        }

        if activeProfileID != profile.id {
            preload(profile: profile)
        }
        let profileGeneration = activeProfileGeneration

        // An initial history run belongs to the wallet, not to the SwiftUI
        // activation task. Rejoin it instead of repeating wallet discovery or
        // starting a second transaction request after an activation change.
        if includeTransactionHistory,
           !profile.requiresInitialDiscovery,
           profile.requiresInitialHistorySync,
           let run = initialHistoryRun,
           run.profileID == profile.id,
           run.generation == profileGeneration {
            await run.task.value
            return
        }

        if !force,
           !profile.requiresInitialHistorySync,
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

            let shouldRunComprehensiveDiscovery = beganWithInitialDiscovery
                || addressDiscoveryPolicy == .comprehensive

            if beganWithInitialDiscovery && preferences.activeNodeMode == .custom {
                state = .failed("Complete discovery requires Automatic Nodes.")
                initialDiscoveryProgress = nil
                initialDiscoveryError = "Complete historical discovery needs the public address indexer. Cancel this import, select Automatic Nodes in Settings, then import again."
                return
            }

            if shouldRunComprehensiveDiscovery,
               preferences.activeNodeMode == .automatic,
               resumableCheckpoint == nil {
                do {
                    profileToSync = try await discoverWalletHistory(
                        profile: profileToSync,
                        engine: engine
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch where !beganWithInitialDiscovery {
                    discoveryNotice = "Complete historical address discovery could not be refreshed. KasSigner kept the account's previously discovered addresses and synchronized current UTXOs instead."
                    initialDiscoveryProgress = DiscoveryProgress(
                        title: "Synchronizing wallet",
                        detail: "Loading current UTXOs from the selected Kaspa node…",
                        fraction: 0.68
                    )
                    initialDiscoveryStage = "Synchronizing UTXOs"
                }
                guard activeProfileID == profile.id,
                      activeProfileGeneration == profileGeneration else { return }
            }

            if let resumableCheckpoint {
                profileToSync = resumableCheckpoint.profile
                initialDiscoveryProgress = DiscoveryProgress(
                    title: "Synchronizing wallet",
                    detail: "Rechecking current UTXOs from the selected Kaspa node…",
                    fraction: 0.68
                )
                initialDiscoveryStage = "Synchronizing UTXOs"
            }

            let (result, discoveredProfile) = try await syncWithAddressDiscovery(
                profile: profileToSync,
                walletStore: walletStore,
                engine: engine,
                preferences: preferences
            )
            if beganWithInitialDiscovery {
                initialDiscoveryCheckpoint = InitialDiscoveryCheckpoint(
                    profile: discoveredProfile
                )
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
                && (!beganWithInitialDiscovery || preferences.activeNodeMode == .automatic)
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
            onWalletReady?()

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
                if completedProfile.requiresInitialHistorySync {
                    await runOrJoinInitialHistory(
                        profile: completedProfile,
                        walletStore: walletStore
                    )
                } else {
                    // Completed wallets keep their cached history visible.
                    // Indexer work must not hold up later node/UTXO refreshes.
                    Task { @MainActor [weak self] in
                        await self?.refreshTransactionHistory(
                            profile: completedProfile,
                            walletStore: walletStore,
                            force: forceTransactionHistory || beganWithInitialDiscovery,
                            keepProgressVisible: keepTransactionProgressThroughReconciliation
                        )
                    }
                }
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

    func runOrJoinInitialHistory(
        profile: WalletProfile,
        walletStore: WalletStore
    ) async {
        guard activeProfileID == profile.id,
              profile.requiresInitialHistorySync else { return }
        let generation = activeProfileGeneration
        if let run = initialHistoryRun,
           run.profileID == profile.id,
           run.generation == generation {
            await run.task.value
            return
        }

        let runID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshTransactionHistory(
                profile: profile,
                walletStore: walletStore,
                force: true,
                keepProgressVisible: true
            )
        }
        initialHistoryRun = (runID, profile.id, generation, task)
        await task.value
        if activeProfileID == profile.id,
           activeProfileGeneration == generation,
           initialHistoryRun?.id == runID,
           initialHistoryReadyToRevealProfileID != profile.id {
            initialHistoryRun = nil
        }
    }

    func refreshTransactionHistory(
        profile: WalletProfile,
        walletStore: WalletStore,
        force: Bool = false,
        keepProgressVisible: Bool = false
    ) async {
        guard activeProfileID == profile.id else { return }
        let generation = activeProfileGeneration
        let request = HistoryRefreshRequest(
            profile: profile,
            walletStore: walletStore,
            force: force,
            keepProgressVisible: keepProgressVisible
        )

        if let run = historyRefreshRun,
           run.profileID == profile.id,
           run.generation == generation {
            if !force, (!keepProgressVisible || run.keepsProgress) {
                await run.task.value
                return
            }
            if queuedHistoryRefresh == nil {
                queuedHistoryRefresh = request
            } else {
                queuedHistoryRefresh?.merge(request)
            }
            await run.task.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var nextRequest: HistoryRefreshRequest? = request
            while let current = nextRequest,
                  !Task.isCancelled,
                  self.activeProfileID == profile.id,
                  self.activeProfileGeneration == generation {
                await self.performTransactionHistoryRefresh(
                    profile: current.profile,
                    walletStore: current.walletStore,
                    force: current.force,
                    keepProgressVisible: current.keepProgressVisible
                )
                // A completed initial load already satisfies requests that
                // arrived while its cards were still hidden for reconciliation.
                if self.initialHistoryReadyToRevealProfileID == profile.id {
                    self.queuedHistoryRefresh = nil
                }
                nextRequest = self.queuedHistoryRefresh
                self.queuedHistoryRefresh = nil
            }
            if self.activeProfileID == profile.id,
               self.activeProfileGeneration == generation {
                self.historyRefreshRun = nil
            }
        }
        historyRefreshRun = (profile.id, generation, keepProgressVisible, task)
        await task.value
    }

    private func performTransactionHistoryRefresh(
        profile: WalletProfile,
        walletStore: WalletStore,
        force: Bool,
        keepProgressVisible: Bool
    ) async {
        guard activeProfileID == profile.id else { return }
        let profileGeneration = activeProfileGeneration
        let showProgress = keepProgressVisible || profile.requiresInitialHistorySync
        if transactionHistoryProfilesInFlight[profile.id] == profileGeneration { return }
        if !force,
           let lastAttempt = lastTransactionHistoryAttempt[profile.id],
           Date().timeIntervalSince(lastAttempt) < 30 {
            return
        }

        lastTransactionHistoryAttempt[profile.id] = Date()
        transactionHistoryProfilesInFlight[profile.id] = profileGeneration
        if profile.requiresInitialHistorySync {
            initialHistoryReadyToRevealProfileID = nil
        }
        isRefreshingTransactionHistory = true
        if showProgress {
            transactionHistoryProgress = TransactionHistoryProgress(
                profileID: profile.id,
                completedAddresses: 0,
                totalAddresses: 0,
                phase: .locatingAddresses
            )
            scheduleTransactionProgressStall(profileID: profile.id, generation: profileGeneration)
        }
        transactionHistoryError = nil
        var committedCompleteHistory = false
        defer {
            let isCurrentProfile = activeProfileID == profile.id
                && activeProfileGeneration == profileGeneration
            if isCurrentProfile {
                transactionProgressStallTask?.cancel()
                transactionProgressStallTask = nil
            }
            if transactionHistoryProfilesInFlight[profile.id] == profileGeneration {
                transactionHistoryProfilesInFlight.removeValue(forKey: profile.id)
            }
            if isCurrentProfile {
                isRefreshingTransactionHistory = !transactionHistoryProfilesInFlight.isEmpty
                if showProgress, committedCompleteHistory {
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
        }

        do {
            if profile.requiresInitialHistorySync,
               let pending = pendingInitialHistoryPersistence,
               pending.profileID == profile.id,
               pending.generation == profileGeneration {
                committedCompleteHistory = await commitIndexedTransactionHistory(
                    pending.history,
                    profile: profile,
                    walletStore: walletStore
                )
                return
            }

            let history = try await transactionHistoryClient.transactions(
                for: profile
            ) { [weak self] completed, total, isRetrying in
                guard let self,
                      self.activeProfileID == profile.id,
                      self.activeProfileGeneration == profileGeneration else { return }
                if showProgress {
                    self.transactionHistoryProgress = TransactionHistoryProgress(
                        profileID: profile.id,
                        completedAddresses: completed,
                        totalAddresses: total,
                        phase: isRetrying ? .retryingThrottledAddresses : .loadingAddresses
                    )
                    self.scheduleTransactionProgressStall(
                        profileID: profile.id,
                        generation: profileGeneration
                    )
                }
            }
            guard activeProfileID == profile.id,
                  activeProfileGeneration == profileGeneration else { return }
            committedCompleteHistory = await commitIndexedTransactionHistory(
                history,
                profile: profile,
                walletStore: walletStore
            )
        } catch {
            guard activeProfileID == profile.id,
                  activeProfileGeneration == profileGeneration else { return }
            guard !Task.isCancelled,
                  !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            transactionHistoryError = error.localizedDescription
        }
    }

    @discardableResult
    func commitIndexedTransactionHistory(
        _ history: TransactionHistorySyncResult,
        profile: WalletProfile,
        walletStore: WalletStore
    ) async -> Bool {
        guard activeProfileID == profile.id else { return false }
        let generation = activeProfileGeneration
        guard walletStore.mergeSyncedTransactions(history.transactions, profileID: profile.id) else {
            if profile.requiresInitialHistorySync {
                pendingInitialHistoryPersistence = (profile.id, generation, history)
            }
            transactionHistoryError = "Transaction history was found but could not be saved on this device. Free up storage or unlock the device, then retry."
            return false
        }
        await TransactionGraphCache.shared.save(history.graphs, profileID: profile.id)
        guard activeProfileID == profile.id,
              activeProfileGeneration == generation else { return false }
        transactionHistoryUpdatedAt = Date()
        if profile.requiresInitialHistorySync {
            initialHistoryReadyToRevealProfileID = profile.id
        }
        pendingInitialHistoryPersistence = nil
        transactionHistoryError = nil
        return true
    }

    func retryInitialHistoryPersistenceIfNeeded(
        profile: WalletProfile,
        walletStore: WalletStore
    ) async -> Bool {
        guard activeProfileID == profile.id else { return false }
        if initialHistoryReadyToRevealProfileID == profile.id {
            completeTransactionHistoryReconciliation(
                profileID: profile.id,
                walletStore: walletStore
            )
            return true
        }
        guard let pending = pendingInitialHistoryPersistence,
              pending.profileID == profile.id,
              pending.generation == activeProfileGeneration else { return false }
        if await commitIndexedTransactionHistory(
            pending.history,
            profile: profile,
            walletStore: walletStore
        ) {
            completeTransactionHistoryReconciliation(
                profileID: profile.id,
                walletStore: walletStore
            )
        }
        return true
    }

    private func scheduleTransactionProgressStall(profileID: UUID, generation: UInt64) {
        transactionProgressStallTask?.cancel()
        transactionProgressStallTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled,
                  let self,
                  self.activeProfileID == profileID,
                  self.activeProfileGeneration == generation,
                  self.transactionHistoryProfilesInFlight[profileID] == generation,
                  let progress = self.transactionHistoryProgress,
                  progress.profileID == profileID,
                  progress.phase != .finalizing else { return }
            self.transactionHistoryProgress = TransactionHistoryProgress(
                profileID: profileID,
                completedAddresses: progress.completedAddresses,
                totalAddresses: progress.totalAddresses,
                phase: .waitingForIndexer
            )
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

    func completeTransactionHistoryReconciliation(
        profileID: UUID,
        walletStore: WalletStore,
        allowInitialReveal: Bool = true
    ) {
        guard transactionHistoryProfilesInFlight[profileID] == nil else { return }
        if !allowInitialReveal,
           initialHistoryReadyToRevealProfileID == profileID {
            return
        }
        var didRevealInitialHistory = false
        if allowInitialReveal,
           initialHistoryReadyToRevealProfileID == profileID,
           walletStore.profiles.contains(where: { $0.id == profileID && $0.requiresInitialHistorySync }) {
            guard walletStore.completeInitialHistorySync(profileID: profileID) else {
                transactionHistoryError = "Transaction history was saved, but its completion state could not be saved on this device. Free up storage or unlock the device, then retry."
                transactionHistoryProgress = nil
                isRefreshingTransactionHistory = false
                return
            }
            didRevealInitialHistory = true
            transactionHistoryError = nil
        }
        if initialHistoryReadyToRevealProfileID == profileID {
            initialHistoryReadyToRevealProfileID = nil
        }
        if didRevealInitialHistory,
           initialHistoryRun?.profileID == profileID {
            initialHistoryRun = nil
        }
        guard transactionHistoryProgress?.profileID == profileID else { return }
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

    private func discoverWalletHistory(
        profile: WalletProfile,
        engine: KasSignerEngine
    ) async throws -> WalletProfile {
        let maximumAddressesPerChain = 512
        let trailingGap = 50

        initialDiscoveryError = nil
        discoveryNotice = nil
        if profile.requiresInitialDiscovery {
            initialDiscoveryCheckpoint = nil
        }
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
        discovered.lastHistoricalDiscoveryAt = Date()
        let normalizedActive = Set(active.map { $0.lowercased() })
        discovered.earliestFreshReceiveIndex = discovered.receiveAddresses.firstIndex {
            !normalizedActive.contains($0.lowercased())
        }

        if plan.reachedSafetyLimit {
            discoveryNotice = "This account has reached the supported 512-address discovery range. Existing discovered addresses remain usable, but KasSigner cannot safely prepare a full 50-address buffer beyond this point."
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
        trailingGap: Int = 50,
        maximumAddressesPerChain: Int = 512
    ) -> DiscoveryPlan {
        let normalizedActive = Set(activeAddresses.map { $0.lowercased() })
        func highestActiveIndex(in addresses: [String]) -> Int? {
            addresses.indices.last {
                normalizedActive.contains(addresses[$0].lowercased())
            }
        }
        func retainedCount(
            highestIndex: Int?,
            currentNextIndex: Int,
            available: Int
        ) -> Int {
            let discoveryFrontier = max(
                currentNextIndex,
                (highestIndex ?? -1) + 1
            )
            return min(
                min(maximumAddressesPerChain, available),
                max(min(trailingGap, available), discoveryFrontier + trailingGap)
            )
        }

        let highestReceive = highestActiveIndex(in: receiveAddresses)
        let highestChange = highestActiveIndex(in: changeAddresses)
        let warningBoundary = maximumAddressesPerChain - trailingGap
        return DiscoveryPlan(
            receiveCount: retainedCount(
                highestIndex: highestReceive,
                currentNextIndex: currentNextReceiveIndex,
                available: receiveAddresses.count
            ),
            changeCount: retainedCount(
                highestIndex: highestChange,
                currentNextIndex: currentNextChangeIndex,
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
            reachedSafetyLimit: max(
                currentNextReceiveIndex,
                (highestReceive ?? -1) + 1
            ) >= warningBoundary
                || max(
                    currentNextChangeIndex,
                    (highestChange ?? -1) + 1
                ) >= warningBoundary
        )
    }

    private func syncWithAddressDiscovery(
        profile: WalletProfile,
        walletStore: WalletStore,
        engine: KasSignerEngine,
        preferences: AppPreferences
    ) async throws -> (WalletSyncPayload, WalletProfile) {
        // Testnet hot wallets only need enough prederived change addresses for
        // the largest send type. Avoid expanding every account to the mainnet
        // discovery buffer before its first network refresh can complete.
        let freshAddressBuffer = profile.network == KaspaNetwork.testnet10.rawValue ? 8 : 50
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

            let targetReceiveCount = min(
                maximumAddressesPerChain,
                current.nextReceiveIndex + freshAddressBuffer
            )
            let targetChangeCount = min(
                maximumAddressesPerChain,
                current.nextChangeIndex + freshAddressBuffer
            )
            let receiveCount = max(
                0,
                targetReceiveCount - current.receiveAddresses.count
            )
            let changeCount = max(
                0,
                targetChangeCount - current.changeAddresses.count
            )

            if receiveCount == 0 && changeCount == 0 {
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
        refreshRun?.task.cancel()
        refreshRun = nil
        queuedRefresh = nil
        historyRefreshRun?.task.cancel()
        historyRefreshRun = nil
        queuedHistoryRefresh = nil
        historicalDiscoveryRun?.task.cancel()
        historicalDiscoveryRun = nil
        isCheckingHistoricalAddresses = false
        historicalDiscoveryError = nil
        lastHistoricalDiscoveryAttempt.removeAll()
        initialHistoryRun?.task.cancel()
        initialHistoryRun = nil
        transactionProgressStallTask?.cancel()
        transactionProgressStallTask = nil
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
        initialHistoryReadyToRevealProfileID = nil
        pendingInitialHistoryPersistence = nil
        isRefreshingTransactionHistory = false
        transactionHistoryProgress = nil
        state = isNetworkAvailable ? .idle : .failed("No internet connection.")
    }

    private func friendlyMessage(for error: Error, preferences: AppPreferences) -> String {
        let message = error.localizedDescription.lowercased()

        if !isNetworkAvailable {
            return "No internet connection."
        }

        if preferences.activeNodeMode == .custom {
            if preferences.activeCustomNodeURL.isEmpty {
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
