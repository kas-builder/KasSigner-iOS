import Foundation

struct WalletBalanceInfo: Codable, Equatable {
    let totalSompi: UInt64
    let totalKas: Double
    let utxoCount: Int
    let fundedAddresses: Int
    let fundedReceiveIndices: [Int]
    let fundedChangeIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case totalSompi = "total_sompi"
        case totalKas = "total_kas"
        case utxoCount = "utxo_count"
        case fundedAddresses = "funded_addresses"
        case fundedReceiveIndices = "funded_receive_indices"
        case fundedChangeIndices = "funded_change_indices"
    }
}

struct WalletUTXO: Codable, Equatable, Identifiable {
    let txID: String
    let index: UInt32
    let amount: UInt64
    let scriptPublicKey: [UInt8]
    let blockDAAScore: UInt64
    let covenantID: String?

    var id: String { "\(txID):\(index)" }
    var amountKas: Double { Double(amount) / 100_000_000 }

    enum CodingKeys: String, CodingKey {
        case txID = "tx_id"
        case index
        case amount
        case scriptPublicKey = "script_public_key"
        case blockDAAScore = "block_daa_score"
        case covenantID = "covenant_id"
    }
}

struct WalletSyncPayload: Codable, Equatable {
    let balance: WalletBalanceInfo
    let utxos: [WalletUTXO]
    let nodeURL: String
    let resolverName: String
    let syncedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case balance
        case utxos
        case nodeURL = "node_url"
        case resolverName = "resolver_name"
        case syncedAt = "synced_at"
    }
}


@MainActor
final class UTXOCoinControlStore: ObservableObject {
    nonisolated static let maximumSelectedUTXOs = 8

    @Published private(set) var selectedOutpoints: Set<String> = []
    @Published private(set) var labels: [String: String] = [:]

    private let selectedPrefix = "kassigner.utxoSelection.v1."
    private let labelsPrefix = "kassigner.utxoLabels.v1."
    private var activeProfileID: UUID?

    func activate(profileID: UUID?) {
        guard activeProfileID != profileID else { return }
        activeProfileID = profileID
        load()
    }

    func isSelected(_ utxo: WalletUTXO) -> Bool {
        selectedOutpoints.contains(utxo.id)
    }

    @discardableResult
    func toggle(_ utxo: WalletUTXO) -> Bool {
        if selectedOutpoints.contains(utxo.id) {
            selectedOutpoints.remove(utxo.id)
        } else {
            guard selectedOutpoints.count < Self.maximumSelectedUTXOs else {
                return false
            }
            selectedOutpoints.insert(utxo.id)
        }
        saveSelection()
        return true
    }

    @discardableResult
    func selectAll(_ utxos: [WalletUTXO]) -> Int {
        let selected = utxos.prefix(Self.maximumSelectedUTXOs)
        selectedOutpoints = Set(selected.map(\.id))
        saveSelection()
        return utxos.count - selected.count
    }

    func clearSelection() {
        selectedOutpoints.removeAll()
        saveSelection()
    }

    func label(for utxo: WalletUTXO) -> String {
        labels[utxo.id] ?? ""
    }

    func setLabel(_ value: String, for utxo: WalletUTXO) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            labels.removeValue(forKey: utxo.id)
        } else {
            labels[utxo.id] = trimmed
        }
        saveLabels()
    }

    func label(forTransactionID transactionID: String) -> String {
        labels[transactionLabelKey(transactionID)] ?? ""
    }

    func setLabel(_ value: String, forTransactionID transactionID: String) {
        let key = transactionLabelKey(transactionID)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            labels.removeValue(forKey: key)
        } else {
            labels[key] = trimmed
        }
        saveLabels()
    }

    func selectedUTXOs(from utxos: [WalletUTXO]) -> [WalletUTXO] {
        utxos.filter { selectedOutpoints.contains($0.id) }
    }

    func removeData(profileID: UUID) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: selectedPrefix + profileID.uuidString)
        defaults.removeObject(forKey: labelsPrefix + profileID.uuidString)

        if activeProfileID == profileID {
            activeProfileID = nil
            selectedOutpoints = []
            labels = [:]
        }
    }

    private func load() {
        guard let profileID = activeProfileID else {
            selectedOutpoints = []
            labels = [:]
            return
        }

        let defaults = UserDefaults.standard
        let selectedKey = selectedPrefix + profileID.uuidString
        let labelsKey = labelsPrefix + profileID.uuidString

        selectedOutpoints = Set(defaults.stringArray(forKey: selectedKey) ?? [])

        if let data = defaults.data(forKey: labelsKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            labels = decoded
        } else {
            labels = [:]
        }
    }

    private func saveSelection() {
        guard let profileID = activeProfileID else { return }
        UserDefaults.standard.set(
            Array(selectedOutpoints).sorted(),
            forKey: selectedPrefix + profileID.uuidString
        )
    }

    private func saveLabels() {
        guard let profileID = activeProfileID,
              let data = try? JSONEncoder().encode(labels)
        else { return }
        UserDefaults.standard.set(
            data,
            forKey: labelsPrefix + profileID.uuidString
        )
    }

    private func transactionLabelKey(_ transactionID: String) -> String {
        "transaction:" + transactionID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
