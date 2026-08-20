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

@MainActor
final class WalletStore: ObservableObject {
    @Published private(set) var profiles: [WalletProfile] = []
    @Published private(set) var transactions: [WalletTransaction] = []
    @Published var selectedProfileID: UUID? { didSet { save() } }

    private let storageKey = "kassigner.walletProfiles.v1"
    private let transactionsStorageKey = "kassigner.walletTransactions.v1"
    private let selectionKey = "kassigner.selectedWalletProfile.v1"
    private let receiveIndexKeyPrefix = "kassigner.lastViewedReceiveIndex.v1."

    init() {
        load()
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

        guard !normalizedTransactionID.isEmpty,
              !transactions.contains(where: {
                  $0.transactionID.caseInsensitiveCompare(normalizedTransactionID) == .orderedSame
              })
        else {
            return
        }

        transactions.append(
            WalletTransaction(
                profileID: profileID,
                transactionID: normalizedTransactionID,
                destination: destination,
                amountSompi: amountSompi,
                feeSompi: feeSompi,
                broadcastAt: Date(),
                direction: .sent,
                status: .pending
            )
        )
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
        let pending = existingForProfile.filter {
            $0.status == .pending && !syncedIDs.contains($0.transactionID.lowercased())
        }

        transactions.removeAll { $0.profileID == profileID }
        transactions.append(contentsOf: confirmed)
        transactions.append(contentsOf: pending)
        save()
    }

    func remove(at offsets: IndexSet) {
        let removedProfileIDs = offsets.compactMap { index in
            profiles.indices.contains(index) ? profiles[index].id : nil
        }

        for profileID in removedProfileIDs {
            UserDefaults.standard.removeObject(
                forKey: receiveIndexKeyPrefix + profileID.uuidString
            )
        }

        transactions.removeAll { removedProfileIDs.contains($0.profileID) }

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

        if let data = UserDefaults.standard.data(forKey: transactionsStorageKey),
           let decoded = try? JSONDecoder().decode([WalletTransaction].self, from: data) {
            transactions = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        if let data = try? JSONEncoder().encode(transactions) {
            UserDefaults.standard.set(data, forKey: transactionsStorageKey)
        }
        UserDefaults.standard.set(selectedProfileID?.uuidString, forKey: selectionKey)
    }
}
