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

struct SendLabelDraft: Equatable {
    var text = ""
    var includeInTransactionCard = true
    var includeInChangeUTXOCards = false

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasSelection: Bool {
        !trimmedText.isEmpty && (includeInTransactionCard || includeInChangeUTXOCards)
    }
}

/// Local metadata only: never encoded into the PSKT or signing QR payload.
struct BroadcastLabelAssignment {
    let profile: WalletProfile
    let draft: SendLabelDraft
    let changeOutputs: [PlannedChangeOutput]
    let changeOutputIndices: [UInt32]

    static func make(profile: WalletProfile, draft: SendLabelDraft,
                     changeOutputs: [PlannedChangeOutput],
                     outputs: [PSKTSummaryOutput]) -> BroadcastLabelAssignment? {
        let ownedChangeAddresses = Set(profile.changeAddresses.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let eligibleChange = changeOutputs.filter {
            $0.amountSompi > 0 && ownedChangeAddresses.contains($0.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        // Match the verified change plan by address AND amount, consuming each
        // planned output once. A wallet-owned payment is not automatically change.
        var remaining: [String: Int] = [:]
        for change in eligibleChange {
            remaining["\(change.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(change.amountSompi)", default: 0] += 1
        }
        let indices = outputs.enumerated().compactMap { index, output -> UInt32? in
            guard let address = output.address, let amount = output.amountSompi else { return nil }
            let key = "\(address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(amount)"
            guard remaining[key, default: 0] > 0, let outputIndex = UInt32(exactly: index) else { return nil }
            remaining[key, default: 0] -= 1
            return outputIndex
        }
        var effectiveDraft = draft
        effectiveDraft.includeInChangeUTXOCards = draft.includeInChangeUTXOCards && !indices.isEmpty
        guard effectiveDraft.hasSelection else { return nil }
        return BroadcastLabelAssignment(profile: profile, draft: effectiveDraft,
                                        changeOutputs: eligibleChange, changeOutputIndices: indices)
    }
}

private struct WalletCardMetadata: Codable {
    var labels: [String: String] = [:]
    var kycStatuses: [String: UTXOKYCStatus] = [:]
    var knownUTXOIDs: Set<String> = []
    var hasKnownUTXOBaseline = false
    // Protected legacy files stay intact. Remember migrations so clearing a
    // label or badge cannot resurrect an older value on a later activation.
    var migratedProfileIDs: Set<UUID> = []
}

@MainActor
final class UTXOCoinControlStore: ObservableObject {
    nonisolated static let maximumSelectedUTXOs = 8

    @Published private(set) var selectedOutpoints: Set<String> = []
    @Published private(set) var labels: [String: String] = [:]
    @Published private(set) var kycStatuses: [String: UTXOKYCStatus] = [:]
    @Published var persistenceAlert: String?

    private let protectedStorage: ProtectedWalletStorage
    private let defaults: UserDefaults
    private var activeProfile: WalletProfile?
    private var metadata = WalletCardMetadata()
    private var storageAvailable = true

    init(protectedStorage: ProtectedWalletStorage = .shared, defaults: UserDefaults = .standard) {
        self.protectedStorage = protectedStorage
        self.defaults = defaults
    }

    func activate(profile: WalletProfile?) {
        guard activeProfile?.id != profile?.id || !storageAvailable else { return }
        activeProfile = profile
        selectedOutpoints = []
        metadata = WalletCardMetadata()
        labels = [:]
        kycStatuses = [:]
        storageAvailable = true
        guard let profile else { return }
        do {
            metadata = try loadMetadata(for: profile)
            labels = metadata.labels
            kycStatuses = metadata.kycStatuses
            persistenceAlert = nil
        } catch {
            storageAvailable = false
            persistenceAlert = "Saved labels and UTXO badges could not be loaded. Changes are disabled to protect your saved data. Check device storage and reopen the wallet."
        }
    }

    /// Preserve even wallets that have not been opened since upgrading.
    func migrateExistingWallets(_ profiles: [WalletProfile]) {
        for profile in profiles {
            guard prepareForRemoval(profile) else { return }
        }
    }

    @discardableResult
    func prepareForRemoval(_ profile: WalletProfile) -> Bool {
        do {
            _ = try loadMetadata(for: profile)
            return true
        } catch {
            persistenceAlert = "Saved labels and UTXO badges could not be preserved. Check device storage and try again."
            return false
        }
    }

    func isSelected(_ utxo: WalletUTXO) -> Bool {
        selectedOutpoints.contains(utxo.id)
    }

    @discardableResult
    func toggle(_ utxo: WalletUTXO) -> Bool {
        if selectedOutpoints.contains(utxo.id) {
            selectedOutpoints.remove(utxo.id)
        } else {
            guard selectedOutpoints.count < Self.maximumSelectedUTXOs else { return false }
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

    func clearSelection() { selectedOutpoints.removeAll() }

    func label(for utxo: WalletUTXO) -> String { labels[normalized(utxo.id)] ?? "" }

    func setLabel(_ value: String, for utxo: WalletUTXO) {
        setLabel(value, key: normalized(utxo.id))
    }

    func label(forTransactionID transactionID: String) -> String {
        labels[transactionLabelKey(transactionID)] ?? ""
    }

    func setLabel(_ value: String, forTransactionID transactionID: String) {
        setLabel(value, key: transactionLabelKey(transactionID))
    }

    private func setLabel(_ value: String, key: String) {
        var updated = metadata
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { updated.labels.removeValue(forKey: key) }
        else { updated.labels[key] = trimmed }
        _ = commit(updated)
    }

    func kycStatus(for utxo: WalletUTXO) -> UTXOKYCStatus? {
        kycStatuses[normalized(utxo.id)]
    }

    func setKYCStatus(_ status: UTXOKYCStatus?, for utxo: WalletUTXO) {
        var updated = metadata
        let key = normalized(utxo.id)
        if let status { updated.kycStatuses[key] = status }
        else { updated.kycStatuses.removeValue(forKey: key) }
        // A deliberate removal must stay removed when defaults run again.
        updated.knownUTXOIDs.insert(key)
        _ = commit(updated)
    }

    func applyDefaultKYCStatus(to utxos: [WalletUTXO], defaultStatus: UTXOKYCStatus?) {
        guard storageAvailable, activeProfile != nil else { return }
        let currentIDs = Set(utxos.map { normalized($0.id) })
        var updated = metadata
        if !metadata.hasKnownUTXOBaseline {
            updated.knownUTXOIDs.formUnion(currentIDs)
            updated.hasKnownUTXOBaseline = true
        } else {
            let newIDs = currentIDs.subtracting(metadata.knownUTXOIDs)
            guard !newIDs.isEmpty else { return }
            if let defaultStatus {
                for id in newIDs where updated.kycStatuses[id] == nil {
                    updated.kycStatuses[id] = defaultStatus
                }
            }
            updated.knownUTXOIDs.formUnion(newIDs)
        }
        _ = commit(updated)
    }

    func selectedUTXOs(from utxos: [WalletUTXO]) -> [WalletUTXO] {
        utxos.filter { selectedOutpoints.contains($0.id) }
    }

    /// Wallet removal discards selection only. Stable metadata and legacy
    /// migration sources remain available for future imports.
    func removeProfileSession(profileID: UUID) {
        defaults.removeObject(forKey: "kassigner.utxoSelection.v1." + profileID.uuidString)
        if activeProfile?.id == profileID { activate(profile: nil) }
    }

    /// Call only after broadcast succeeds. Save both card choices atomically,
    /// using the originating wallet, independently of the current selection.
    @discardableResult
    func saveBroadcastLabels(_ assignment: BroadcastLabelAssignment?, transactionID: String) -> Bool {
        guard let assignment, assignment.draft.hasSelection else { return true }
        let transactionID = normalized(transactionID)
        guard !transactionID.isEmpty else {
            persistenceAlert = "The transaction was broadcast, but its label could not be saved because its transaction ID was missing."
            return false
        }
        do {
            var saved = try loadMetadata(for: assignment.profile)
            if assignment.draft.includeInTransactionCard {
                saved.labels[transactionLabelKey(transactionID)] = assignment.draft.trimmedText
            }
            if assignment.draft.includeInChangeUTXOCards {
                for index in assignment.changeOutputIndices {
                    saved.labels["\(transactionID):\(index)"] = assignment.draft.trimmedText
                }
            }
            guard protectedStorage.save(saved, fileName: fileName(assignment.profile)) else {
                throw CocoaError(.fileWriteUnknown)
            }
            if activeProfile?.stableIdentity == assignment.profile.stableIdentity {
                metadata = saved
                labels = saved.labels
                kycStatuses = saved.kycStatuses
            }
            return true
        } catch {
            persistenceAlert = "The transaction was broadcast, but its label could not be saved. Check device storage before editing its labels again."
            return false
        }
    }

    private func loadMetadata(for profile: WalletProfile) throws -> WalletCardMetadata {
        var saved = try protectedStorage.loadIfPresent(WalletCardMetadata.self, fileName: fileName(profile))
            ?? WalletCardMetadata()
        guard !saved.migratedProfileIDs.contains(profile.id) else { return saved }
        let suffix = profile.id.uuidString.lowercased()
        let oldLabels = try legacy([String: String].self, fileName: "utxo-labels-\(suffix).json",
                                   key: "kassigner.utxoLabels.v1." + profile.id.uuidString) ?? [:]
        let oldStatuses = try legacy([String: UTXOKYCStatus].self, fileName: "utxo-kyc-statuses-\(suffix).json",
                                     key: "kassigner.utxoKYCStatuses.v1." + profile.id.uuidString) ?? [:]
        let oldKnownIDs = try legacy(Set<String>.self, fileName: "utxo-known-ids-\(suffix).json",
                                     key: "kassigner.knownUTXOs.v1." + profile.id.uuidString)
        for key in oldLabels.keys.sorted() where saved.labels[normalized(key)] == nil {
            saved.labels[normalized(key)] = oldLabels[key]
        }
        for key in oldStatuses.keys.sorted() where saved.kycStatuses[normalized(key)] == nil {
            saved.kycStatuses[normalized(key)] = oldStatuses[key]
        }
        if let oldKnownIDs {
            saved.knownUTXOIDs.formUnion(oldKnownIDs.map(normalized))
            saved.hasKnownUTXOBaseline = true
        }
        saved.migratedProfileIDs.insert(profile.id)
        guard protectedStorage.save(saved, fileName: fileName(profile)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Only remove unprotected legacy copies after the protected record's
        // write and read-back verification succeeded.
        for prefix in ["kassigner.utxoLabels.v1.", "kassigner.utxoKYCStatuses.v1.", "kassigner.knownUTXOs.v1."] {
            defaults.removeObject(forKey: prefix + profile.id.uuidString)
        }
        return saved
    }

    private func legacy<Value: Decodable>(_ type: Value.Type, fileName: String, key: String) throws -> Value? {
        if let saved = try protectedStorage.loadIfPresent(type, fileName: fileName) { return saved }
        guard let data = defaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    private func commit(_ updated: WalletCardMetadata) -> Bool {
        guard storageAvailable, let profile = activeProfile else {
            persistenceAlert = "Your labels and UTXO badges could not be saved. Check device storage and reopen the wallet."
            return false
        }
        guard protectedStorage.save(updated, fileName: fileName(profile)) else {
            persistenceAlert = "Your label or UTXO badge change could not be saved. The previous value is still in place. Check device storage and try again."
            return false
        }
        metadata = updated
        labels = updated.labels
        kycStatuses = updated.kycStatuses
        return true
    }

    private func fileName(_ profile: WalletProfile) -> String {
        "wallet-card-metadata-\(profile.stableIdentity).json"
    }

    private func normalized(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func transactionLabelKey(_ transactionID: String) -> String {
        "transaction:" + normalized(transactionID)
    }
}
