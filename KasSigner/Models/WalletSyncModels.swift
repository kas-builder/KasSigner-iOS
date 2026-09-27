import Foundation
import UIKit
import UniformTypeIdentifiers

enum PrivatePasteboard {
    static func copy(_ value: String, expiresAfter: TimeInterval = 120) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: value]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(expiresAfter)
            ]
        )
    }
}

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
    let derivationChain: String?
    let derivationIndex: UInt32?

    var id: String { "\(txID):\(index)" }
    var amountKas: Double { Double(amount) / 100_000_000 }

    init(
        txID: String,
        index: UInt32,
        amount: UInt64,
        scriptPublicKey: [UInt8],
        blockDAAScore: UInt64,
        covenantID: String?,
        derivationChain: String? = nil,
        derivationIndex: UInt32? = nil
    ) {
        self.txID = txID
        self.index = index
        self.amount = amount
        self.scriptPublicKey = scriptPublicKey
        self.blockDAAScore = blockDAAScore
        self.covenantID = covenantID
        self.derivationChain = derivationChain
        self.derivationIndex = derivationIndex
    }

    enum CodingKeys: String, CodingKey {
        case txID = "tx_id"
        case index
        case amount
        case scriptPublicKey = "script_public_key"
        case blockDAAScore = "block_daa_score"
        case covenantID = "covenant_id"
        case derivationChain = "derivation_chain"
        case derivationIndex = "derivation_index"
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


enum UTXOKYCStatus: String, Codable, CaseIterable, Identifiable {
    case kyc
    case nonKYC

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kyc: "KYC"
        case .nonKYC: "Non-KYC"
        }
    }
}

@MainActor
final class UTXOCoinControlStore: ObservableObject {
    nonisolated static let maximumSelectedUTXOs = 8

    @Published private(set) var selectedOutpoints: Set<String> = []
    @Published private(set) var labels: [String: String] = [:]
    @Published private(set) var kycStatuses: [String: UTXOKYCStatus] = [:]

    private let selectedPrefix = "kassigner.utxoSelection.v1."
    private let labelsPrefix = "kassigner.utxoLabels.v1."
    private let kycStatusesPrefix = "kassigner.utxoKYCStatuses.v1."
    private let protectedStorage: ProtectedWalletStorage
    private let defaults: UserDefaults
    private var activeProfileID: UUID?

    init(
        protectedStorage: ProtectedWalletStorage = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.protectedStorage = protectedStorage
        self.defaults = defaults
    }

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
        return true
    }

    @discardableResult
    func selectAll(_ utxos: [WalletUTXO]) -> Int {
        let selected = utxos.prefix(Self.maximumSelectedUTXOs)
        selectedOutpoints = Set(selected.map(\.id))
        return utxos.count - selected.count
    }

    func clearSelection() {
        selectedOutpoints.removeAll()
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

    func kycStatus(for utxo: WalletUTXO) -> UTXOKYCStatus? {
        kycStatuses[utxo.id]
    }

    func setKYCStatus(_ status: UTXOKYCStatus?, for utxo: WalletUTXO) {
        if let status {
            kycStatuses[utxo.id] = status
        } else {
            kycStatuses.removeValue(forKey: utxo.id)
        }
        saveKYCStatuses()
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
        defaults.removeObject(forKey: selectedPrefix + profileID.uuidString)
        defaults.removeObject(forKey: labelsPrefix + profileID.uuidString)
        defaults.removeObject(forKey: kycStatusesPrefix + profileID.uuidString)
        protectedStorage.remove(fileName: labelsFileName(profileID: profileID))
        protectedStorage.remove(fileName: kycStatusesFileName(profileID: profileID))

        if activeProfileID == profileID {
            activeProfileID = nil
            selectedOutpoints = []
            labels = [:]
            kycStatuses = [:]
        }
    }

    private func load() {
        guard let profileID = activeProfileID else {
            selectedOutpoints = []
            labels = [:]
            kycStatuses = [:]
            return
        }

        let labelsKey = labelsPrefix + profileID.uuidString

        // UTXO selection belongs to the current in-memory send attempt only.
        selectedOutpoints = []
        defaults.removeObject(forKey: selectedPrefix + profileID.uuidString)

        if let protectedLabels = protectedStorage.load(
            [String: String].self,
            fileName: labelsFileName(profileID: profileID)
        ) {
            labels = protectedLabels
        } else if let data = defaults.data(forKey: labelsKey),
                  let decoded = try? JSONDecoder().decode(
                      [String: String].self,
                      from: data
                  ) {
            labels = decoded
            if protectedStorage.save(
                decoded,
                fileName: labelsFileName(profileID: profileID)
            ) {
                defaults.removeObject(forKey: labelsKey)
            }
        } else {
            labels = [:]
        }

        let kycStatusesKey = kycStatusesPrefix + profileID.uuidString
        if let protectedStatuses = protectedStorage.load(
            [String: UTXOKYCStatus].self,
            fileName: kycStatusesFileName(profileID: profileID)
        ) {
            kycStatuses = protectedStatuses
        } else if let data = defaults.data(forKey: kycStatusesKey),
                  let decoded = try? JSONDecoder().decode(
                      [String: UTXOKYCStatus].self,
                      from: data
                  ) {
            kycStatuses = decoded
            if protectedStorage.save(
                decoded,
                fileName: kycStatusesFileName(profileID: profileID)
            ) {
                defaults.removeObject(forKey: kycStatusesKey)
            }
        } else {
            kycStatuses = [:]
        }
    }

    private func saveLabels() {
        guard let profileID = activeProfileID else { return }
        _ = protectedStorage.save(
            labels,
            fileName: labelsFileName(profileID: profileID)
        )
    }

    private func saveKYCStatuses() {
        guard let profileID = activeProfileID else { return }
        _ = protectedStorage.save(
            kycStatuses,
            fileName: kycStatusesFileName(profileID: profileID)
        )
    }

    private func labelsFileName(profileID: UUID) -> String {
        "utxo-labels-\(profileID.uuidString.lowercased()).json"
    }

    private func kycStatusesFileName(profileID: UUID) -> String {
        "utxo-kyc-statuses-\(profileID.uuidString.lowercased()).json"
    }

    private func transactionLabelKey(_ transactionID: String) -> String {
        "transaction:" + transactionID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
