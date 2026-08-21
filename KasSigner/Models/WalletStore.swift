import Foundation

enum WalletTransactionDirection: String, Codable, Equatable {
    case sent
    case received
}

enum WalletTransactionStatus: String, Codable, Equatable {
    case pending
    case confirmed
}

struct WalletTransaction: Identifiable, Codable, Equatable {
    let id: UUID
    let profileID: UUID
    let transactionID: String
    let destination: String
    let amountSompi: UInt64
    let feeSompi: UInt64
    let broadcastAt: Date
    let direction: WalletTransactionDirection
    let status: WalletTransactionStatus

    init(
        id: UUID = UUID(),
        profileID: UUID,
        transactionID: String,
        destination: String,
        amountSompi: UInt64,
        feeSompi: UInt64,
        broadcastAt: Date,
        direction: WalletTransactionDirection,
        status: WalletTransactionStatus
    ) {
        self.id = id
        self.profileID = profileID
        self.transactionID = transactionID
        self.destination = destination
        self.amountSompi = amountSompi
        self.feeSompi = feeSompi
        self.broadcastAt = broadcastAt
        self.direction = direction
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case profileID
        case transactionID
        case destination
        case amountSompi
        case feeSompi
        case broadcastAt
        case direction
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        transactionID = try container.decode(String.self, forKey: .transactionID)
        destination = try container.decode(String.self, forKey: .destination)
        amountSompi = try container.decode(UInt64.self, forKey: .amountSompi)
        feeSompi = try container.decode(UInt64.self, forKey: .feeSompi)
        broadcastAt = try container.decode(Date.self, forKey: .broadcastAt)
        direction = try container.decodeIfPresent(
            WalletTransactionDirection.self,
            forKey: .direction
        ) ?? .sent
        status = try container.decodeIfPresent(
            WalletTransactionStatus.self,
            forKey: .status
        ) ?? .pending
    }

    func preservingID(_ id: UUID) -> WalletTransaction {
        WalletTransaction(
            id: id,
            profileID: profileID,
            transactionID: transactionID,
            destination: destination,
            amountSompi: amountSompi,
            feeSompi: feeSompi,
            broadcastAt: broadcastAt,
            direction: direction,
            status: status
        )
    }
}

private final class WalletTransactionCache {
    private let fileManager: FileManager
    private let directoryURL: URL?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        directoryURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appending(path: "KasSigner", directoryHint: .isDirectory)
            .appending(path: "TransactionHistory", directoryHint: .isDirectory)
    }

    func load(profileID: UUID) -> [WalletTransaction]? {
        guard let fileURL = fileURL(profileID: profileID),
              let data = try? Data(contentsOf: fileURL),
              let transactions = try? JSONDecoder().decode(
                  [WalletTransaction].self,
                  from: data
              ) else {
            return nil
        }

        return transactions.filter { $0.profileID == profileID }
    }

    @discardableResult
    func save(_ transactions: [WalletTransaction], profileID: UUID) -> Bool {
        guard let directoryURL,
              let fileURL = fileURL(profileID: profileID),
              let data = try? JSONEncoder().encode(
                  transactions.filter { $0.profileID == profileID }
              ) else {
            return false
        }

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func remove(profileID: UUID) {
        guard let fileURL = fileURL(profileID: profileID) else { return }
        try? fileManager.removeItem(at: fileURL)
    }

    private func fileURL(profileID: UUID) -> URL? {
        directoryURL?.appending(
            path: profileID.uuidString.lowercased() + ".json",
            directoryHint: .notDirectory
        )
    }
}

@MainActor
final class WalletStore: ObservableObject {
    @Published private(set) var profiles: [WalletProfile] = []
    @Published private(set) var transactions: [WalletTransaction] = []
    @Published private(set) var pendingTransactions: [WalletTransaction] = []
    @Published private(set) var transactionRevision: UInt64 = 0
    @Published var selectedProfileID: UUID? {
        didSet {
            guard !isLoading else { return }
            save()
        }
    }

    private let storageKey = "kassigner.walletProfiles.v1"
    private let transactionsStorageKey = "kassigner.walletTransactions.v1"
    private let selectionKey = "kassigner.selectedWalletProfile.v1"
    private let receiveIndexKeyPrefix = "kassigner.lastViewedReceiveIndex.v1."
    private let transactionCache = WalletTransactionCache()
    private var isLoading = true

    init() {
        load()
        isLoading = false
    }

    var selectedProfile: WalletProfile? {
        guard let selectedProfileID else { return profiles.first }
        return profiles.first(where: { $0.id == selectedProfileID }) ?? profiles.first
    }

    func add(_ profile: WalletProfile) {
        profiles.append(profile)
        selectedProfileID = profile.id
        save()
    }

    func update(_ profile: WalletProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        save()
    }

    @discardableResult
    func reserveChangeAddress(profileID: UUID, index: Int) -> Bool {
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }),
              index == profiles[profileIndex].nextChangeIndex
        else {
            return false
        }

        profiles[profileIndex].nextChangeIndex = index + 1
        save()
        return true
    }

    func lastViewedReceiveIndex(for profileID: UUID, addressCount: Int) -> Int {
        guard addressCount > 0 else { return 0 }
        let stored = UserDefaults.standard.integer(
            forKey: receiveIndexKeyPrefix + profileID.uuidString
        )
        return min(max(0, stored), addressCount - 1)
    }

    func setLastViewedReceiveIndex(_ index: Int, for profileID: UUID, addressCount: Int) {
        guard addressCount > 0 else { return }
        let clamped = min(max(0, index), addressCount - 1)
        UserDefaults.standard.set(
            clamped,
            forKey: receiveIndexKeyPrefix + profileID.uuidString
        )
    }

    func recordBroadcastedTransaction(
        profileID: UUID,
        transactionID: String,
        destination: String,
        amountSompi: UInt64,
        feeSompi: UInt64
    ) {
        let normalizedTransactionID = transactionID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedTransactionID.isEmpty else { return }

        let pendingTransaction = WalletTransaction(
            profileID: profileID,
            transactionID: normalizedTransactionID,
            destination: destination,
            amountSompi: amountSompi,
            feeSompi: feeSompi,
            broadcastAt: Date(),
            direction: .sent,
            status: .pending
        )

        var updatedPending = pendingTransactions
        if let existingIndex = updatedPending.firstIndex(where: {
            $0.profileID == profileID
                && $0.transactionID.caseInsensitiveCompare(normalizedTransactionID) == .orderedSame
        }) {
            updatedPending[existingIndex] = pendingTransaction.preservingID(
                updatedPending[existingIndex].id
            )
        } else {
            updatedPending.append(pendingTransaction)
        }

        pendingTransactions = updatedPending
        rebuildPublishedTransactions()
        transactionRevision &+= 1
        save()
    }

    func recordObservedUTXOTransactions(
        profileID: UUID,
        addedUTXOs: [WalletUTXO]
    ) {
        let pendingIDs = Set(pendingTransactions.filter { $0.profileID == profileID }
            .map { $0.transactionID.lowercased() })
        let existingIDs = Set(transactions.filter { $0.profileID == profileID }
            .map { $0.transactionID.lowercased() })
        let grouped = Dictionary(grouping: addedUTXOs) { $0.txID.lowercased() }
        var additions: [WalletTransaction] = []

        for (transactionID, utxos) in grouped {
            guard !transactionID.isEmpty,
                  !pendingIDs.contains(transactionID),
                  !existingIDs.contains(transactionID) else { continue }

            additions.append(
                WalletTransaction(
                    profileID: profileID,
                    transactionID: transactionID,
                    destination: "Multiple senders",
                    amountSompi: utxos.reduce(UInt64(0)) { $0 &+ $1.amount },
                    feeSompi: 0,
                    broadcastAt: Date(),
                    direction: .received,
                    status: .confirmed
                )
            )
        }

        guard !additions.isEmpty else { return }
        transactions = transactions + additions
        transactionRevision &+= 1
        save()
    }

    func mergeSyncedTransactions(
        _ syncedTransactions: [WalletTransaction],
        profileID: UUID
    ) {
        let existingForProfile = transactions.filter { $0.profileID == profileID }
        let existingByID = Dictionary(
            existingForProfile.map { ($0.transactionID.lowercased(), $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let syncedIDs = Set(syncedTransactions.map { $0.transactionID.lowercased() })
        let confirmed = syncedTransactions.map { transaction in
            guard let existing = existingByID[transaction.transactionID.lowercased()] else {
                return transaction
            }
            return transaction.preservingID(existing.id)
        }
        let pending = pendingTransactions.filter {
            $0.profileID == profileID
                && !syncedIDs.contains($0.transactionID.lowercased())
        }
        pendingTransactions.removeAll {
            $0.profileID == profileID
                && syncedIDs.contains($0.transactionID.lowercased())
        }
        let retainedPending = existingForProfile.filter {
            $0.status == .pending && !syncedIDs.contains($0.transactionID.lowercased())
        }

        transactions = transactions.filter { $0.profileID != profileID }
            + confirmed
            + pending
            + retainedPending.filter { retained in
                !pending.contains { $0.transactionID.caseInsensitiveCompare(retained.transactionID) == .orderedSame }
            }
        transactionRevision &+= 1
        save()
    }

    func mergeResolvedTransactions(
        _ resolvedTransactions: [WalletTransaction],
        profileID: UUID
    ) {
        guard !resolvedTransactions.isEmpty else { return }
        var updated = transactions

        for transaction in resolvedTransactions where transaction.profileID == profileID {
            if let index = updated.firstIndex(where: {
                $0.profileID == profileID
                    && $0.transactionID.caseInsensitiveCompare(transaction.transactionID) == .orderedSame
            }) {
                updated[index] = transaction.preservingID(updated[index].id)
            } else {
                updated.append(transaction)
            }
        }

        let resolvedIDs = Set(resolvedTransactions.map { $0.transactionID.lowercased() })
        pendingTransactions.removeAll {
            $0.profileID == profileID
                && resolvedIDs.contains($0.transactionID.lowercased())
        }
        transactions = updated
        transactionRevision &+= 1
        save()
    }

    func reloadCachedTransactions(profileID: UUID) {
        guard let cached = transactionCache.load(profileID: profileID) else { return }
        transactions = transactions.filter { $0.profileID != profileID } + cached
        pendingTransactions = pendingTransactions.filter { $0.profileID != profileID }
            + cached.filter { $0.status == .pending }
        transactionRevision &+= 1
    }

    func remove(at offsets: IndexSet) {
        let removedProfileIDs = offsets.compactMap { index in
            profiles.indices.contains(index) ? profiles[index].id : nil
        }

        for profileID in removedProfileIDs {
            UserDefaults.standard.removeObject(
                forKey: receiveIndexKeyPrefix + profileID.uuidString
            )
            transactionCache.remove(profileID: profileID)
        }

        transactions.removeAll { removedProfileIDs.contains($0.profileID) }
        pendingTransactions.removeAll { removedProfileIDs.contains($0.profileID) }

        profiles.remove(atOffsets: offsets)
        if let selectedProfileID, !profiles.contains(where: { $0.id == selectedProfileID }) {
            self.selectedProfileID = profiles.first?.id
        }
        save()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([WalletProfile].self, from: data) {
            profiles = decoded
            if let raw = UserDefaults.standard.string(forKey: selectionKey),
               let id = UUID(uuidString: raw),
               decoded.contains(where: { $0.id == id }) {
                selectedProfileID = id
            } else {
                selectedProfileID = decoded.first?.id
            }
        }

        let legacyTransactions: [WalletTransaction]
        if let data = UserDefaults.standard.data(forKey: transactionsStorageKey),
           let decoded = try? JSONDecoder().decode([WalletTransaction].self, from: data) {
            legacyTransactions = decoded
        } else {
            legacyTransactions = []
        }

        var migratedLegacyHistory = false
        transactions = profiles.flatMap { profile in
            if let cached = transactionCache.load(profileID: profile.id) {
                return cached
            }

            let legacyForProfile = legacyTransactions.filter {
                $0.profileID == profile.id
            }
            if !legacyForProfile.isEmpty {
                migratedLegacyHistory = true
            }
            return legacyForProfile
        }
        pendingTransactions = transactions.filter { $0.status == .pending }

        if migratedLegacyHistory {
            persistTransactionCache()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        persistTransactionCache()
        UserDefaults.standard.set(selectedProfileID?.uuidString, forKey: selectionKey)
    }

    private func persistTransactionCache() {
        for profile in profiles {
            transactionCache.save(
                transactions.filter { $0.profileID == profile.id },
                profileID: profile.id
            )
        }
    }

    private func rebuildPublishedTransactions() {
        let pendingKeys = Set(pendingTransactions.map {
            "\($0.profileID.uuidString.lowercased()):\($0.transactionID.lowercased())"
        })
        transactions = transactions.filter {
            !pendingKeys.contains(
                "\($0.profileID.uuidString.lowercased()):\($0.transactionID.lowercased())"
            )
        } + pendingTransactions
    }
}
