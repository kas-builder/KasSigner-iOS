import Foundation
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct ProtectedVaultRecoveryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct ProtectedVaultRecoveryBackup: Codable {
    let version: Int
    let walletFingerprint: String
    let vaults: [ProtectedVault]
    let setupDrafts: [ProtectedVaultSetupDraft]
}

private struct ProtectedVaultPersistentState: Codable {
    var version = 1
    var vaults: [ProtectedVault] = []
    var setupDrafts: [ProtectedVaultSetupDraft] = []
    var lastOpenedAtByItemKey: [String: Date] = [:]
    var walletFingerprintsByProfileID: [String: String] = [:]
    var refreshStatesByVaultID: [String: ProtectedVaultRefreshState]? = nil
}

struct ProtectedVaultRefreshInfo: Codable, Equatable {
    let checkedAt: Date
    let network: String
    let nodeLabel: String
}

struct ProtectedVaultRefreshState: Codable, Equatable {
    private(set) var isRefreshing = false
    private(set) var lastSuccessfulInfo: ProtectedVaultRefreshInfo?
    private(set) var lastAttemptAt: Date?
    private(set) var attemptedNetwork: String?
    private(set) var attemptedNodeLabel: String?
    private(set) var errorMessage: String?

    var isStale: Bool { errorMessage != nil }

    init(lastSuccessfulInfo: ProtectedVaultRefreshInfo? = nil) {
        self.lastSuccessfulInfo = lastSuccessfulInfo
    }

    mutating func begin(at date: Date, network: String, nodeLabel: String) {
        isRefreshing = true
        lastAttemptAt = date
        attemptedNetwork = network
        attemptedNodeLabel = nodeLabel
    }

    mutating func succeed(with info: ProtectedVaultRefreshInfo) {
        isRefreshing = false
        lastSuccessfulInfo = info
        lastAttemptAt = info.checkedAt
        attemptedNetwork = info.network
        attemptedNodeLabel = info.nodeLabel
        errorMessage = nil
    }

    mutating func fail(message: String) {
        isRefreshing = false
        errorMessage = message
    }

    mutating func markInterrupted() {
        fail(message: "The previous refresh did not finish. Retry to verify current on-chain data.")
    }
}

@MainActor
enum ProtectedVaultNodeLabel {
    static func make(preferences: AppPreferences) -> String {
        guard preferences.activeNodeMode == .custom,
              let components = URLComponents(string: preferences.activeCustomNodeURL),
              let host = components.host else {
            return preferences.activeNodeMode.title
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(host)\(port)"
    }
}

struct ProtectedVaultSetupDraft: Codable, Equatable, Identifiable {
    enum Step: String, Codable {
        case rules
        case review
        case destinations
        case reviewDetails
    }

    let id: UUID
    let profileID: UUID
    let createdAt: Date
    var approvedAddressCount: Int
    var approvedAddresses: [String]
    var recoveryAddress: String
    var recoveryPath: ProtectedVault.RecoveryPath
    var delayDays: Int
    var delayHours: Int
    var delayMinutes: Int
    var selectedUTXOIDs: [String]
    var feeChoiceRawValue: String
    var customFeeText: String
    var step: Step

    init(
        id: UUID = UUID(),
        profileID: UUID,
        createdAt: Date = .now,
        approvedAddressCount: Int,
        approvedAddresses: [String],
        recoveryAddress: String,
        recoveryPath: ProtectedVault.RecoveryPath,
        delayDays: Int,
        delayHours: Int,
        delayMinutes: Int,
        selectedUTXOIDs: [String],
        feeChoiceRawValue: String = "normal",
        customFeeText: String = "",
        step: Step = .review
    ) {
        self.id = id
        self.profileID = profileID
        self.createdAt = createdAt
        self.approvedAddressCount = approvedAddressCount
        self.approvedAddresses = approvedAddresses
        self.recoveryAddress = recoveryAddress
        self.recoveryPath = recoveryPath
        self.delayDays = delayDays
        self.delayHours = delayHours
        self.delayMinutes = delayMinutes
        self.selectedUTXOIDs = selectedUTXOIDs
        self.feeChoiceRawValue = feeChoiceRawValue
        self.customFeeText = customFeeText
        self.step = step
    }

    func reassociated(to profileID: UUID) -> Self {
        Self(id: id, profileID: profileID, createdAt: createdAt,
             approvedAddressCount: approvedAddressCount,
             approvedAddresses: approvedAddresses, recoveryAddress: recoveryAddress,
             recoveryPath: recoveryPath, delayDays: delayDays,
             delayHours: delayHours, delayMinutes: delayMinutes,
             selectedUTXOIDs: selectedUTXOIDs, feeChoiceRawValue: feeChoiceRawValue,
             customFeeText: customFeeText, step: step)
    }
}

struct ProtectedVault: Identifiable, Codable, Equatable {
    struct PendingWithdrawal: Codable, Equatable, Identifiable {
        enum CompletionOutcome: String, Codable {
            case recovery
            case delayCompleted
        }

        let id: UUID
        let destinationAddress: String
        let pendingAddress: String
        let transactionID: String
        let completionTransactionID: String?
        let completionOutcome: CompletionOutcome?
        let createdAt: Date
        let pendingBlockDAAScore: UInt64?
        let completionReviewRequested: Bool?
        let completedAt: Date?

        init(id: UUID = UUID(), destinationAddress: String, pendingAddress: String,
             transactionID: String, createdAt: Date = .now,
             completionTransactionID: String? = nil,
             completionOutcome: CompletionOutcome? = nil,
             pendingBlockDAAScore: UInt64? = nil,
             completionReviewRequested: Bool? = nil, completedAt: Date? = nil) {
            self.id = id
            self.destinationAddress = destinationAddress
            self.pendingAddress = pendingAddress
            self.transactionID = transactionID
            self.completionTransactionID = completionTransactionID
            self.completionOutcome = completionOutcome
            self.createdAt = createdAt
            self.pendingBlockDAAScore = pendingBlockDAAScore
            self.completionReviewRequested = completionReviewRequested
            self.completedAt = completedAt
        }
    }

    enum RecoveryPath: String, Codable, CaseIterable, Identifiable {
        case cancelPendingWithdrawal = "Cancel pending withdrawal only"
        case emergencyAnytime = "Emergency Recovery 24/7"

        var id: Self { self }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            switch value {
            case "Cancel pending withdrawal only":
                self = .cancelPendingWithdrawal
            case "Emergency recovery at any time", "Emergency Recovery 24/7":
                self = .emergencyAnytime
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown protected vault recovery path: \(value)"
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    enum Status: String, Codable {
        case localDraft
        case fundingBroadcast
        case active
        case pendingWithdrawal
        case incompatibleFunding
        case spent

        var title: String {
            switch self {
            case .localDraft: "Awaiting Funding"
            case .fundingBroadcast: "Transaction Being Broadcasted"
            case .active: "Funded"
            case .pendingWithdrawal: "Security Delay in Progress"
            case .incompatibleFunding: "Needs Attention"
            case .spent: "Spent"
            }
        }
    }

    let id: UUID
    let profileID: UUID
    var name: String?
    let amount: Decimal
    let usesSendMaxFunding: Bool
    let approvedAddress: String
    let approvedAddresses: [String]
    let recoveryAddress: String?
    let recoveryPath: RecoveryPath?
    let delayDays: Int
    let delayHours: Int
    let delayMinutes: Int
    let ownerDerivationIndex: Int?
    let ownerPublicKey: String?
    let redeemScriptHex: String?
    let vaultAddress: String?
    let createdAt: Date
    let status: Status
    let fundingTransactionID: String?
    let approvedWithdrawalTransactionID: String?
    let fundedAt: Date?
    let lockedSompi: UInt64?
    let fundingOutpoints: [String]
    let covenantIDs: [String]
    let pendingWithdrawals: [PendingWithdrawal]

    init(
        id: UUID = UUID(),
        profileID: UUID,
        name: String? = nil,
        amount: Decimal,
        usesSendMaxFunding: Bool = false,
        approvedAddresses: [String],
        recoveryAddress: String? = nil,
        recoveryPath: RecoveryPath? = nil,
        delayDays: Int,
        delayHours: Int,
        delayMinutes: Int,
        ownerDerivationIndex: Int? = nil,
        ownerPublicKey: String? = nil,
        redeemScriptHex: String? = nil,
        vaultAddress: String? = nil,
        createdAt: Date = .now,
        status: Status = .localDraft,
        fundingTransactionID: String? = nil,
        approvedWithdrawalTransactionID: String? = nil,
        fundedAt: Date? = nil,
        lockedSompi: UInt64? = nil,
        fundingOutpoints: [String] = [],
        covenantIDs: [String] = [],
        pendingWithdrawals: [PendingWithdrawal] = []
    ) {
        self.id = id
        self.profileID = profileID
        self.name = name
        self.amount = amount
        self.usesSendMaxFunding = usesSendMaxFunding
        precondition(!approvedAddresses.isEmpty)
        self.approvedAddress = approvedAddresses[0]
        self.approvedAddresses = approvedAddresses
        self.recoveryAddress = recoveryAddress
        self.recoveryPath = recoveryPath
        self.delayDays = delayDays
        self.delayHours = delayHours
        self.delayMinutes = delayMinutes
        self.ownerDerivationIndex = ownerDerivationIndex
        self.ownerPublicKey = ownerPublicKey
        self.redeemScriptHex = redeemScriptHex
        self.vaultAddress = vaultAddress
        self.createdAt = createdAt
        self.status = status
        self.fundingTransactionID = fundingTransactionID
        self.approvedWithdrawalTransactionID = approvedWithdrawalTransactionID
        self.fundedAt = fundedAt
        self.lockedSompi = lockedSompi
        self.fundingOutpoints = fundingOutpoints
        self.covenantIDs = covenantIDs
        self.pendingWithdrawals = pendingWithdrawals
    }

    var delaySummary: String {
        var components: [String] = []
        if delayDays > 0 {
            components.append("\(delayDays) \(delayDays == 1 ? "day" : "days")")
        }
        if delayHours > 0 {
            components.append("\(delayHours) \(delayHours == 1 ? "hour" : "hours")")
        }
        if delayMinutes > 0 {
            components.append("\(delayMinutes) \(delayMinutes == 1 ? "minute" : "minutes")")
        }
        return components.joined(separator: ", ")
    }

    var lockedAmount: Decimal? {
        lockedSompi.map { Decimal($0) / Decimal(100_000_000) }
    }

    var displayName: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? "Protected Vault" : trimmedName
    }

    private enum CodingKeys: String, CodingKey {
        case id, profileID, name, amount, usesSendMaxFunding, approvedAddress, approvedAddresses, recoveryAddress, recoveryPath, delayDays, delayHours
        case delayMinutes, ownerDerivationIndex, ownerPublicKey, redeemScriptHex
        case vaultAddress, createdAt, status, fundingTransactionID, approvedWithdrawalTransactionID, fundedAt
        case lockedSompi, fundingOutpoints, covenantIDs, pendingWithdrawals
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        profileID = try values.decode(UUID.self, forKey: .profileID)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        amount = try values.decode(Decimal.self, forKey: .amount)
        usesSendMaxFunding = try values.decodeIfPresent(Bool.self, forKey: .usesSendMaxFunding) ?? false
        approvedAddress = try values.decode(String.self, forKey: .approvedAddress)
        approvedAddresses = try values.decodeIfPresent([String].self, forKey: .approvedAddresses)
            ?? [approvedAddress]
        recoveryAddress = try values.decodeIfPresent(String.self, forKey: .recoveryAddress)
        recoveryPath = try values.decodeIfPresent(RecoveryPath.self, forKey: .recoveryPath)
        delayDays = try values.decode(Int.self, forKey: .delayDays)
        delayHours = try values.decode(Int.self, forKey: .delayHours)
        delayMinutes = try values.decode(Int.self, forKey: .delayMinutes)
        ownerDerivationIndex = try values.decodeIfPresent(Int.self, forKey: .ownerDerivationIndex)
        ownerPublicKey = try values.decodeIfPresent(String.self, forKey: .ownerPublicKey)
        redeemScriptHex = try values.decodeIfPresent(String.self, forKey: .redeemScriptHex)
        vaultAddress = try values.decodeIfPresent(String.self, forKey: .vaultAddress)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        status = try values.decodeIfPresent(Status.self, forKey: .status) ?? .localDraft
        fundingTransactionID = try values.decodeIfPresent(String.self, forKey: .fundingTransactionID)
        approvedWithdrawalTransactionID = try values.decodeIfPresent(String.self, forKey: .approvedWithdrawalTransactionID)
        fundedAt = try values.decodeIfPresent(Date.self, forKey: .fundedAt)
        lockedSompi = try values.decodeIfPresent(UInt64.self, forKey: .lockedSompi)
        fundingOutpoints = try values.decodeIfPresent([String].self, forKey: .fundingOutpoints) ?? []
        covenantIDs = try values.decodeIfPresent([String].self, forKey: .covenantIDs) ?? []
        pendingWithdrawals = try values.decodeIfPresent([PendingWithdrawal].self, forKey: .pendingWithdrawals) ?? []
    }
}

extension ProtectedVault {
    func reassociated(to profileID: UUID) -> Self {
        Self(id: id, profileID: profileID, name: name, amount: amount,
             usesSendMaxFunding: usesSendMaxFunding,
             approvedAddresses: approvedAddresses,
             recoveryAddress: recoveryAddress, recoveryPath: recoveryPath,
             delayDays: delayDays, delayHours: delayHours,
             delayMinutes: delayMinutes, ownerDerivationIndex: ownerDerivationIndex,
             ownerPublicKey: ownerPublicKey, redeemScriptHex: redeemScriptHex,
             vaultAddress: vaultAddress, createdAt: createdAt, status: status,
             fundingTransactionID: fundingTransactionID,
             approvedWithdrawalTransactionID: approvedWithdrawalTransactionID,
             fundedAt: fundedAt, lockedSompi: lockedSompi,
             fundingOutpoints: fundingOutpoints, covenantIDs: covenantIDs,
             pendingWithdrawals: pendingWithdrawals)
    }
}

struct ProtectedVaultDescriptor: Decodable, Equatable {
    let ownerDerivationIndex: Int
    let ownerDerivationPath: String
    let ownerPublicKey: String
    let redeemScriptHex: String
    let scriptHashHex: String
    let vaultAddress: String
    let delayDAA: UInt64
    let scriptVersion: Int?
    let recoveryAddress: String?
    let recoveryPath: String?

    enum CodingKeys: String, CodingKey {
        case ownerDerivationIndex = "owner_derivation_index"
        case ownerDerivationPath = "owner_derivation_path"
        case ownerPublicKey = "owner_public_key"
        case redeemScriptHex = "redeem_script_hex"
        case scriptHashHex = "script_hash_hex"
        case vaultAddress = "vault_address"
        case delayDAA = "delay_daa"
        case scriptVersion = "script_version"
        case recoveryAddress = "recovery_address"
        case recoveryPath = "recovery_path"
    }
}

struct ProtectedVaultPendingDescriptor: Decodable, Equatable {
    let pendingAddress: String
    let redeemScriptHex: String
    let destinationAddress: String
    let recoveryAddress: String
    let delayDAA: UInt64

    enum CodingKeys: String, CodingKey {
        case pendingAddress = "pending_address"
        case redeemScriptHex = "redeem_script_hex"
        case destinationAddress = "destination_address"
        case recoveryAddress = "recovery_address"
        case delayDAA = "delay_daa"
    }
}

struct ProtectedVaultFundingPlan: Equatable {
    let inputs: [WalletUTXO]
    let depositSompi: UInt64
    let feeSompi: UInt64
    let inputTotalSompi: UInt64
    let changeSompi: UInt64

    init(vault: ProtectedVault, inputs: [WalletUTXO], feeSompi: UInt64) throws {
        guard !inputs.isEmpty else {
            throw ProtectedVaultFundingPlanError.noInputs
        }
        guard inputs.count <= UTXOCoinControlStore.maximumSelectedUTXOs else {
            throw ProtectedVaultFundingPlanError.tooManyInputs
        }
        guard Set(inputs.map(\.id)).count == inputs.count else {
            throw ProtectedVaultFundingPlanError.duplicateInput
        }
        guard feeSompi > 0 else {
            throw ProtectedVaultFundingPlanError.invalidFee
        }

        var inputTotalSompi: UInt64 = 0
        for input in inputs {
            let addition = inputTotalSompi.addingReportingOverflow(input.amount)
            guard !addition.overflow else {
                throw ProtectedVaultFundingPlanError.inputTotalOverflow
            }
            inputTotalSompi = addition.partialValue
        }

        let depositSompi: UInt64
        if vault.usesSendMaxFunding {
            guard inputTotalSompi > feeSompi else {
                throw ProtectedVaultFundingPlanError.insufficientInput
            }
            depositSompi = inputTotalSompi - feeSompi
        } else {
            var sourceAmount = vault.amount
            var scaledAmount = Decimal()
            var roundedAmount = Decimal()
            NSDecimalMultiplyByPowerOf10(&scaledAmount, &sourceAmount, 8, .plain)
            NSDecimalRound(&roundedAmount, &scaledAmount, 0, .plain)

            guard scaledAmount == roundedAmount,
                  roundedAmount > 0,
                  roundedAmount <= Decimal(UInt64.max)
            else {
                throw ProtectedVaultFundingPlanError.invalidDepositAmount
            }

            depositSompi = NSDecimalNumber(decimal: roundedAmount).uint64Value
        }

        let required = depositSompi.addingReportingOverflow(feeSompi)
        guard !required.overflow, inputTotalSompi >= required.partialValue else {
            throw ProtectedVaultFundingPlanError.insufficientInput
        }

        self.inputs = inputs
        self.depositSompi = depositSompi
        self.feeSompi = feeSompi
        self.inputTotalSompi = inputTotalSompi
        self.changeSompi = inputTotalSompi - required.partialValue
    }
}

enum ProtectedVaultFundingPlanError: LocalizedError, Equatable {
    case noInputs
    case tooManyInputs
    case duplicateInput
    case invalidFee
    case invalidDepositAmount
    case inputTotalOverflow
    case insufficientInput

    var errorDescription: String? {
        switch self {
        case .noInputs:
            return "Select at least one funding UTXO."
        case .tooManyInputs:
            return "A funding transaction can use at most 8 selected UTXOs."
        case .duplicateInput:
            return "The funding selection contains a duplicate UTXO."
        case .invalidFee:
            return "The funding fee must be greater than zero."
        case .invalidDepositAmount:
            return "The vault deposit must be a positive amount with no more than 8 decimal places."
        case .inputTotalOverflow:
            return "The selected UTXO total is too large."
        case .insufficientInput:
            return "The selected UTXOs cannot cover the vault deposit and fee."
        }
    }
}

struct ProtectedVaultFundingSelectionSession: Equatable {
    private(set) var profileID: UUID?

    mutating func begin(profileID: UUID) -> Bool {
        guard self.profileID != profileID else { return false }
        self.profileID = profileID
        return true
    }
}

struct VerifiedProtectedVaultFunding: Equatable {
    let depositSompi: UInt64
    let feeSompi: UInt64
    let changeSompi: UInt64
    let inputCount: Int
    let selectedOutpoints: [String]
    let selectedInputsMatchDecodedPSKB: Bool
    let vaultDepositMatches: Bool
    let changeOutputsMatchWallet: Bool
    let feeMatchesInputOutputTotals: Bool
}

enum ProtectedVaultFundingVerificationError: LocalizedError, Equatable {
    case inputCountMismatch
    case missingInputOutpoint
    case inputOutpointMismatch
    case missingOutputs
    case invalidOutput
    case depositMismatch
    case unknownOutput
    case invalidFeeArithmetic
    case exactFeeMismatch
    case changeAddressUnavailable
    case changeMismatch
    case missingCovenantBinding

    var errorDescription: String? {
        switch self {
        case .inputCountMismatch:
            return "The built transaction input count does not match the selected UTXOs."
        case .missingInputOutpoint:
            return "The built transaction contains an input without a valid outpoint."
        case .inputOutpointMismatch:
            return "The built transaction inputs do not exactly match the selected UTXOs."
        case .missingOutputs:
            return "The built transaction contains no outputs."
        case .invalidOutput:
            return "The built transaction contains an invalid output."
        case .depositMismatch:
            return "The built transaction does not contain exactly one matching vault deposit."
        case .unknownOutput:
            return "The built transaction contains an unknown output."
        case .invalidFeeArithmetic:
            return "The built transaction fee arithmetic is invalid."
        case .exactFeeMismatch:
            return "The fee encoded in the transaction does not match the custom fee you entered."
        case .changeAddressUnavailable:
            return "No unused wallet change address is available."
        case .changeMismatch:
            return "The built transaction change does not match the expected unused wallet change address."
        case .missingCovenantBinding:
            return "The vault deposit is missing its required consensus covenant binding."
        }
    }
}

enum ProtectedVaultFundingVerifier {
    static func verify(
        summary: PSKTSummary,
        plan: ProtectedVaultFundingPlan,
        vaultAddress: String,
        expectedChangeAddress: String?,
        requiresExactFee: Bool
    ) throws -> VerifiedProtectedVaultFunding {
        guard let inputs = summary.inputs,
              inputs.count == plan.inputs.count,
              summary.inputCount == nil || summary.inputCount == inputs.count
        else {
            throw ProtectedVaultFundingVerificationError.inputCountMismatch
        }

        let selectedOutpoints = Set(plan.inputs.map {
            "\($0.txID.lowercased()):\($0.index)"
        })
        let builtOutpoints = Set(try inputs.map { input -> String in
            guard let txID = input.txID?.lowercased(), let index = input.index else {
                throw ProtectedVaultFundingVerificationError.missingInputOutpoint
            }
            return "\(txID):\(index)"
        })
        guard builtOutpoints == selectedOutpoints else {
            throw ProtectedVaultFundingVerificationError.inputOutpointMismatch
        }

        guard let outputs = summary.outputs, !outputs.isEmpty,
              summary.outputCount == nil || summary.outputCount == outputs.count
        else {
            throw ProtectedVaultFundingVerificationError.missingOutputs
        }

        let normalizedVaultAddress = normalize(vaultAddress)
        let normalizedChangeAddress = expectedChangeAddress.map(normalize)
        var depositMatches = 0
        var changeMatches = 0

        for output in outputs {
            guard let address = output.address.map(normalize),
                  let amount = output.amountSompi,
                  amount > 0
            else {
                throw ProtectedVaultFundingVerificationError.invalidOutput
            }

            if address == normalizedVaultAddress && amount == plan.depositSompi {
                guard summary.transactionVersion == 1,
                      output.covenantAuthorizingInput == 0,
                      output.covenantID?.count == 64,
                      output.covenantID?.allSatisfy(\.isHexDigit) == true
                else {
                    throw ProtectedVaultFundingVerificationError.missingCovenantBinding
                }
                depositMatches += 1
            } else if let normalizedChangeAddress,
                      address == normalizedChangeAddress {
                guard output.covenantAuthorizingInput == nil,
                      output.covenantID == nil else {
                    throw ProtectedVaultFundingVerificationError.unknownOutput
                }
                changeMatches += 1
            } else {
                throw ProtectedVaultFundingVerificationError.unknownOutput
            }
        }

        guard depositMatches == 1 else {
            throw ProtectedVaultFundingVerificationError.depositMismatch
        }

        guard let totalInput = summary.totalInputSompi,
              let totalOutput = summary.totalOutputSompi,
              let fee = summary.feeSompi,
              totalInput == plan.inputTotalSompi,
              totalInput >= totalOutput,
              totalInput - totalOutput == fee
        else {
            throw ProtectedVaultFundingVerificationError.invalidFeeArithmetic
        }

        if requiresExactFee && fee != plan.feeSompi {
            throw ProtectedVaultFundingVerificationError.exactFeeMismatch
        }

        let remainder = totalInput.subtractingReportingOverflow(plan.depositSompi)
        guard !remainder.overflow else {
            throw ProtectedVaultFundingVerificationError.invalidFeeArithmetic
        }
        let change = remainder.partialValue.subtractingReportingOverflow(fee)
        guard !change.overflow else {
            throw ProtectedVaultFundingVerificationError.invalidFeeArithmetic
        }

        if change.partialValue > 0 {
            guard expectedChangeAddress != nil else {
                throw ProtectedVaultFundingVerificationError.changeAddressUnavailable
            }
            guard changeMatches == 1,
                  outputs.contains(where: {
                      $0.address.map(normalize) == normalizedChangeAddress
                          && $0.amountSompi == change.partialValue
                  })
            else {
                throw ProtectedVaultFundingVerificationError.changeMismatch
            }
        } else if changeMatches != 0 {
            throw ProtectedVaultFundingVerificationError.changeMismatch
        }

        return VerifiedProtectedVaultFunding(
            depositSompi: plan.depositSompi,
            feeSompi: fee,
            changeSompi: change.partialValue,
            inputCount: inputs.count,
            selectedOutpoints: plan.inputs.map { "\($0.txID):\($0.index)" },
            selectedInputsMatchDecodedPSKB: true,
            vaultDepositMatches: true,
            changeOutputsMatchWallet: true,
            feeMatchesInputOutputTotals: true
        )
    }

    private static func normalize(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum SignedProtectedVaultFundingVerificationError: LocalizedError, Equatable {
    case transactionChanged
    case missingSignatures

    var errorDescription: String? {
        switch self {
        case .transactionChanged:
            return "The returned signed transaction does not match the verified unsigned funding transaction."
        case .missingSignatures:
            return "The returned transaction is missing a required M5 signature."
        }
    }
}

enum SignedProtectedVaultFundingVerifier {
    static func verify(unsigned: PSKTSummary, signed: PSKTSummary) throws {
        guard unsigned.totalInputSompi == signed.totalInputSompi,
              unsigned.totalOutputSompi == signed.totalOutputSompi,
              unsigned.feeSompi == signed.feeSompi,
              unsigned.inputCount == signed.inputCount,
              unsigned.outputCount == signed.outputCount,
              transactionInputs(unsigned.inputs) == transactionInputs(signed.inputs),
              transactionOutputs(unsigned.outputs) == transactionOutputs(signed.outputs)
        else {
            throw SignedProtectedVaultFundingVerificationError.transactionChanged
        }

        guard signed.finalizeReady == true,
              signed.inputs?.allSatisfy({ ($0.signaturesPresent ?? 0) >= 1 }) == true
        else {
            throw SignedProtectedVaultFundingVerificationError.missingSignatures
        }
    }

    private static func transactionInputs(
        _ inputs: [PSKTSummaryInput]?
    ) -> [String]? {
        inputs?.map {
            [
                $0.txID?.lowercased() ?? "",
                $0.index.map(String.init) ?? "",
                $0.amountSompi.map(String.init) ?? "",
                $0.scriptHex?.lowercased() ?? ""
            ].joined(separator: ":")
        }
    }

    private static func transactionOutputs(
        _ outputs: [PSKTSummaryOutput]?
    ) -> [String]? {
        outputs?.map {
            [
                $0.amountSompi.map(String.init) ?? "",
                $0.scriptHex?.lowercased() ?? "",
                $0.address?.lowercased() ?? "",
                $0.covenantAuthorizingInput.map(String.init) ?? "",
                $0.covenantID?.lowercased() ?? ""
            ].joined(separator: ":")
        }
    }
}

/// A UTXO observed at a protected-vault stage. A covenant tag makes an output
/// a candidate; the PSKB builder and verifier still validate its exact binding.
struct ProtectedVaultStageOutput: Identifiable, Equatable {
    enum Classification: Equatable {
        case covenantTagged
        case unsupportedDeposit
    }

    let utxo: WalletUTXO

    var id: String { utxo.id.lowercased() }

    var classification: Classification {
        guard let covenantID = utxo.covenantID,
              covenantID.count == 64,
              covenantID.allSatisfy(\.isHexDigit) else {
            return .unsupportedDeposit
        }
        return .covenantTagged
    }

    var isCovenantTagged: Bool { classification == .covenantTagged }

    func canCoverFee(_ feeSompi: UInt64) -> Bool {
        isCovenantTagged && utxo.amount > feeSompi
    }

    static func classify(_ utxos: [WalletUTXO]) -> [ProtectedVaultStageOutput] {
        utxos.map { ProtectedVaultStageOutput(utxo: $0) }
    }
}

@MainActor
final class ProtectedVaultStore: ObservableObject {
    @Published private(set) var vaults: [ProtectedVault] = []
    @Published private(set) var setupDrafts: [ProtectedVaultSetupDraft] = []
    @Published private(set) var storageError: String?
    @Published private(set) var refreshStates: [UUID: ProtectedVaultRefreshState] = [:]

    private let protectedFileName = "protected-vault-state.json"
    private let storageKey = "kassigner.protectedVaults.v1"
    private let setupDraftStorageKey = "kassigner.protectedVaultSetupDrafts.v1"
    private let lastOpenedStorageKey = "kassigner.protectedVaultLastOpened.v1"
    private let defaults: UserDefaults
    private let protectedStorage: ProtectedWalletStorage
    private var lastOpenedAtByItemKey: [String: Date] = [:]
    private var walletFingerprintsByProfileID: [String: String] = [:]
    private var refreshStatesByVaultID: [String: ProtectedVaultRefreshState] = [:]

    init(defaults: UserDefaults = .standard,
         protectedStorage: ProtectedWalletStorage = .shared) {
        self.defaults = defaults
        self.protectedStorage = protectedStorage
        load()
    }

    private static func fingerprint(for profile: WalletProfile) -> String {
        let identity = "\(profile.network.lowercased()):\(profile.kpub)"
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    func registerWallet(_ profile: WalletProfile) -> Bool {
        let key = profile.id.uuidString
        let fingerprint = Self.fingerprint(for: profile)
        if walletFingerprintsByProfileID[key] == fingerprint { return true }
        return commit {
            walletFingerprintsByProfileID[key] = fingerprint
        }
    }

    @discardableResult
    func reassociateVaults(to profile: WalletProfile) -> Bool {
        let fingerprint = Self.fingerprint(for: profile)
        let oldIDs = Set(walletFingerprintsByProfileID.compactMap { key, value in
            value == fingerprint && key != profile.id.uuidString ? UUID(uuidString: key) : nil
        })
        guard !oldIDs.isEmpty else { return registerWallet(profile) }
        return commit {
            vaults = vaults.map { vault in
                guard oldIDs.contains(vault.profileID) else { return vault }
                return vault.reassociated(to: profile.id)
            }
            setupDrafts = setupDrafts.map { draft in
                guard oldIDs.contains(draft.profileID) else { return draft }
                return draft.reassociated(to: profile.id)
            }
            walletFingerprintsByProfileID[profile.id.uuidString] = fingerprint
            for oldID in oldIDs {
                walletFingerprintsByProfileID.removeValue(forKey: oldID.uuidString)
            }
        }
    }

    func recoverLegacyOrphanedVaults(to profile: WalletProfile,
                                     knownProfileIDs: Set<UUID>,
                                     engine: KasSignerEngine) async throws -> Int {
        guard storageError == nil else {
            throw KasSignerEngine.EngineError.javascript(storageError ?? "Vault storage is unavailable.")
        }
        var matchedVaultIDs = Set<UUID>()
        for vault in vaults where !knownProfileIDs.contains(vault.profileID)
            && walletFingerprintsByProfileID[vault.profileID.uuidString] == nil {
            guard let index = vault.ownerDerivationIndex, index >= 0,
                  !vault.approvedAddresses.isEmpty,
                  let recovery = vault.recoveryAddress,
                  let path = vault.recoveryPath,
                  let owner = vault.ownerPublicKey,
                  let script = vault.redeemScriptHex,
                  let address = vault.vaultAddress,
                  (0...365).contains(vault.delayDays),
                  (0...23).contains(vault.delayHours),
                  (0...59).contains(vault.delayMinutes) else { continue }
            let minutes = vault.delayDays * 1440 + vault.delayHours * 60 + vault.delayMinutes
            guard minutes > 0,
                  let derived = try? await engine.deriveProtectedVault(
                    profile: profile, receiveIndex: index,
                    approvedAddresses: vault.approvedAddresses,
                    recoveryAddress: recovery,
                    emergencyAnytime: path == .emergencyAnytime,
                    delayDAA: UInt64(minutes) * 600
                  ),
                  derived.ownerPublicKey.caseInsensitiveCompare(owner) == .orderedSame,
                  derived.redeemScriptHex.caseInsensitiveCompare(script) == .orderedSame,
                  derived.vaultAddress.caseInsensitiveCompare(address) == .orderedSame
            else { continue }
            matchedVaultIDs.insert(vault.id)
        }
        guard !matchedVaultIDs.isEmpty else { return 0 }
        let count = matchedVaultIDs.count
        guard commit({
            vaults = vaults.map { matchedVaultIDs.contains($0.id)
                ? $0.reassociated(to: profile.id) : $0 }
            walletFingerprintsByProfileID[profile.id.uuidString] = Self.fingerprint(for: profile)
        }) else {
            throw KasSignerEngine.EngineError.javascript("Recovered vault records could not be saved.")
        }
        return count
    }

    func recoveryDocument(for profile: WalletProfile) throws -> ProtectedVaultRecoveryDocument {
        guard storageError == nil else {
            throw KasSignerEngine.EngineError.javascript(storageError ?? "Vault storage is unavailable.")
        }
        let backup = ProtectedVaultRecoveryBackup(
            version: 1, walletFingerprint: Self.fingerprint(for: profile),
            vaults: vaults(for: profile.id), setupDrafts: setupDrafts(for: profile.id)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return ProtectedVaultRecoveryDocument(data: try encoder.encode(backup))
    }

    func restoreRecoveryDocument(_ document: ProtectedVaultRecoveryDocument,
                                 for profile: WalletProfile,
                                 engine: KasSignerEngine) async throws -> Int {
        guard storageError == nil else {
            throw KasSignerEngine.EngineError.javascript(storageError ?? "Vault storage is unavailable.")
        }
        guard document.data.count <= 2_000_000 else {
            throw KasSignerEngine.EngineError.javascript("The vault recovery file is too large.")
        }
        let backup = try JSONDecoder().decode(ProtectedVaultRecoveryBackup.self, from: document.data)
        guard backup.version == 1,
              backup.walletFingerprint == Self.fingerprint(for: profile),
              profile.network == KaspaNetwork.testnet10.rawValue else {
            throw KasSignerEngine.EngineError.javascript("This recovery file does not belong to the selected Testnet 10 account.")
        }
        guard Set(backup.vaults.map(\.id)).count == backup.vaults.count else {
            throw KasSignerEngine.EngineError.javascript("The recovery file contains duplicate vault records.")
        }
        guard Set(backup.setupDrafts.map(\.id)).count == backup.setupDrafts.count else {
            throw KasSignerEngine.EngineError.javascript("The recovery file contains duplicate setup drafts.")
        }
        for incoming in backup.vaults {
            if let current = vaults.first(where: { $0.id == incoming.id }),
               current.vaultAddress?.caseInsensitiveCompare(incoming.vaultAddress ?? "") != .orderedSame {
                throw KasSignerEngine.EngineError.javascript("A saved vault conflicts with the recovery file.")
            }
        }
        for vault in backup.vaults {
            guard let index = vault.ownerDerivationIndex,
                  index >= 0,
                  !vault.approvedAddresses.isEmpty,
                  let recovery = vault.recoveryAddress,
                  let path = vault.recoveryPath,
                  let owner = vault.ownerPublicKey,
                  let script = vault.redeemScriptHex,
                  let address = vault.vaultAddress,
                  (0...365).contains(vault.delayDays),
                  (0...23).contains(vault.delayHours),
                  (0...59).contains(vault.delayMinutes) else {
                throw KasSignerEngine.EngineError.javascript("The recovery file contains an incomplete vault descriptor.")
            }
            let minutes = vault.delayDays * 1440 + vault.delayHours * 60 + vault.delayMinutes
            guard minutes > 0 else {
                throw KasSignerEngine.EngineError.javascript("The recovery file contains an invalid security delay.")
            }
            let derived = try await engine.deriveProtectedVault(
                profile: profile, receiveIndex: index,
                approvedAddresses: vault.approvedAddresses,
                recoveryAddress: recovery,
                emergencyAnytime: path == .emergencyAnytime,
                delayDAA: UInt64(minutes) * 600
            )
            guard derived.scriptVersion == 2,
                  derived.ownerPublicKey.caseInsensitiveCompare(owner) == .orderedSame,
                  derived.redeemScriptHex.caseInsensitiveCompare(script) == .orderedSame,
                  derived.vaultAddress.caseInsensitiveCompare(address) == .orderedSame else {
                throw KasSignerEngine.EngineError.javascript("A vault descriptor does not match this wallet and its covenant rules.")
            }
            for pending in vault.pendingWithdrawals {
                let expected = try await engine.deriveProtectedVaultPendingWithRecovery(
                    vault: vault, destination: pending.destinationAddress
                )
                guard expected.pendingAddress.caseInsensitiveCompare(pending.pendingAddress) == .orderedSame else {
                    throw KasSignerEngine.EngineError.javascript("A pending withdrawal address does not match its covenant rules.")
                }
            }
        }
        let existingIDs = Set(vaults.map(\.id))
        let imported = backup.vaults.filter { !existingIDs.contains($0.id) }.map {
            $0.reassociated(to: profile.id)
        }
        let existingDraftIDs = Set(setupDrafts.map(\.id))
        let importedDrafts = backup.setupDrafts.filter { !existingDraftIDs.contains($0.id) }.map {
            $0.reassociated(to: profile.id)
        }
        guard commit({
            vaults.append(contentsOf: imported)
            setupDrafts.append(contentsOf: importedDrafts)
            walletFingerprintsByProfileID[profile.id.uuidString] = Self.fingerprint(for: profile)
        }) else {
            throw KasSignerEngine.EngineError.javascript("The restored vault records could not be saved.")
        }
        return imported.count
    }

    func vaults(for profileID: UUID) -> [ProtectedVault] {
        vaults
            .filter { $0.profileID == profileID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func watchedAddresses(for profileID: UUID?) -> [String] {
        guard let profileID else { return [] }
        return Array(Set(vaults(for: profileID).flatMap { vault in
            [vault.vaultAddress].compactMap { $0 }
                + vault.pendingWithdrawals
                    .filter { $0.completedAt == nil }
                    .map(\.pendingAddress)
        })).sorted()
    }

    func setupDrafts(for profileID: UUID) -> [ProtectedVaultSetupDraft] {
        setupDrafts
            .filter { $0.profileID == profileID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func setupDraft(id: UUID) -> ProtectedVaultSetupDraft? {
        setupDrafts.first { $0.id == id }
    }

    func lastOpenedAt(id: UUID, profileID: UUID) -> Date? {
        lastOpenedAtByItemKey[lastOpenedItemKey(id: id, profileID: profileID)]
    }

    func refreshState(for vaultID: UUID) -> ProtectedVaultRefreshState {
        refreshStates[vaultID] ?? refreshStatesByVaultID[vaultID.uuidString] ?? ProtectedVaultRefreshState()
    }

    private func setRefreshState(_ state: ProtectedVaultRefreshState, for vaultID: UUID) {
        refreshStates[vaultID] = state
        _ = commit { refreshStatesByVaultID[vaultID.uuidString] = state }
    }

    func recordOpened(id: UUID, profileID: UUID, at date: Date = .now) {
        _ = commit {
            lastOpenedAtByItemKey[lastOpenedItemKey(id: id, profileID: profileID)] = date
        }
    }

    @discardableResult
    func saveSetupDraft(_ draft: ProtectedVaultSetupDraft) -> Bool {
        commit {
            if let index = setupDrafts.firstIndex(where: { $0.id == draft.id }) {
                setupDrafts[index] = draft
            } else {
                setupDrafts.append(draft)
            }
        }
    }

    func removeSetupDraft(id: UUID) {
        _ = commit { setupDrafts.removeAll { $0.id == id } }
    }

    @discardableResult
    func add(_ vault: ProtectedVault) -> Bool {
        guard !vaults.contains(where: { $0.id == vault.id }) else { return true }
        return commit { vaults.append(vault) }
    }

    func remove(id: UUID) {
        if commit({
            vaults.removeAll { $0.id == id }
            refreshStatesByVaultID.removeValue(forKey: id.uuidString)
        }) {
            refreshStates.removeValue(forKey: id)
        }
    }

    func rename(id: UUID, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = vaults.firstIndex(where: { $0.id == id }) else { return }
        _ = commit { vaults[index].name = trimmedName }
    }

    @discardableResult
    func recordFundingBroadcast(id: UUID, transactionID: String) -> Bool {
        update(id: id) { vault in
            replacing(vault, status: .fundingBroadcast,
                fundingTransactionID: transactionID, fundedAt: vault.fundedAt ?? .now,
                lockedSompi: vault.lockedSompi, fundingOutpoints: vault.fundingOutpoints,
                covenantIDs: vault.covenantIDs)
        }
    }

    @discardableResult
    func recordApprovedSpend(id: UUID, transactionID: String) -> Bool {
        update(id: id) { vault in
            replacing(
                vault, status: .spent,
                fundingTransactionID: vault.fundingTransactionID, fundedAt: vault.fundedAt,
                approvedWithdrawalTransactionID: transactionID,
                lockedSompi: 0, fundingOutpoints: [], covenantIDs: []
            )
        }
    }

    @discardableResult
    func recordPendingWithdrawal(id: UUID, destination: String,
                                 pendingAddress: String, transactionID: String,
                                 pendingBalanceSompi: UInt64? = nil,
                                 pendingBlockDAAScore: UInt64? = nil) -> Bool {
        update(id: id) { vault in
            let prior = vault.pendingWithdrawals.first {
                $0.pendingAddress == pendingAddress && $0.completedAt == nil
            }
            let pending = ProtectedVault.PendingWithdrawal(
                id: prior?.id ?? UUID(),
                destinationAddress: destination, pendingAddress: pendingAddress,
                transactionID: transactionID,
                createdAt: prior?.createdAt ?? .now,
                completionTransactionID: nil,
                pendingBlockDAAScore: pendingBlockDAAScore ?? prior?.pendingBlockDAAScore,
                completionReviewRequested: prior?.completionReviewRequested
            )
            let existing = vault.pendingWithdrawals.filter { item in
                !(item.pendingAddress == pendingAddress && item.completedAt == nil)
            }
            return replacing(vault, status: .pendingWithdrawal,
                fundingTransactionID: vault.fundingTransactionID, fundedAt: vault.fundedAt,
                lockedSompi: pendingBalanceSompi ?? vault.lockedSompi,
                fundingOutpoints: [], covenantIDs: [],
                pendingWithdrawals: existing + [pending])
        }
    }

    func rememberPendingDestination(id: UUID, destination: String, pendingAddress: String) {
        update(id: id) { vault in
            guard !vault.pendingWithdrawals.contains(where: {
                $0.pendingAddress == pendingAddress && $0.completedAt == nil
            }) else { return vault }
            let pending = ProtectedVault.PendingWithdrawal(
                destinationAddress: destination, pendingAddress: pendingAddress,
                transactionID: ""
            )
            return replacing(vault, status: vault.status,
                fundingTransactionID: vault.fundingTransactionID, fundedAt: vault.fundedAt,
                lockedSompi: vault.lockedSompi, fundingOutpoints: vault.fundingOutpoints,
                covenantIDs: vault.covenantIDs,
                pendingWithdrawals: vault.pendingWithdrawals + [pending])
        }
    }

    @discardableResult
    func completePendingWithdrawal(
        id: UUID,
        pendingID: UUID,
        transactionID: String,
        outcome: ProtectedVault.PendingWithdrawal.CompletionOutcome
    ) -> Bool {
        update(id: id) { vault in
            let pending = vault.pendingWithdrawals.map { item in
                item.id == pendingID
                    ? ProtectedVault.PendingWithdrawal(id: item.id,
                        destinationAddress: item.destinationAddress,
                        pendingAddress: item.pendingAddress,
                        transactionID: item.transactionID,
                        createdAt: item.createdAt,
                        completionTransactionID: transactionID,
                        completionOutcome: outcome,
                        pendingBlockDAAScore: item.pendingBlockDAAScore,
                        completionReviewRequested: nil,
                        completedAt: .now)
                    : item
            }
            return replacing(vault, status: .spent,
                fundingTransactionID: vault.fundingTransactionID, fundedAt: vault.fundedAt,
                lockedSompi: 0, fundingOutpoints: [], covenantIDs: [],
                pendingWithdrawals: pending)
        }
    }

    func setCompletionReviewRequested(id: UUID, pendingID: UUID, requested: Bool) {
        update(id: id) { vault in
            let pending = vault.pendingWithdrawals.map { item in
                guard item.id == pendingID, item.completedAt == nil else { return item }
                return ProtectedVault.PendingWithdrawal(
                    id: item.id,
                    destinationAddress: item.destinationAddress,
                    pendingAddress: item.pendingAddress,
                    transactionID: item.transactionID,
                    createdAt: item.createdAt,
                    completionTransactionID: item.completionTransactionID,
                    completionOutcome: item.completionOutcome,
                    pendingBlockDAAScore: item.pendingBlockDAAScore,
                    completionReviewRequested: requested ? true : nil,
                    completedAt: item.completedAt
                )
            }
            return replacing(
                vault,
                status: vault.status,
                fundingTransactionID: vault.fundingTransactionID,
                fundedAt: vault.fundedAt,
                lockedSompi: vault.lockedSompi,
                fundingOutpoints: vault.fundingOutpoints,
                covenantIDs: vault.covenantIDs,
                pendingWithdrawals: pending
            )
        }
    }

    @discardableResult
    func updateOnChainFunding(id: UUID, utxos: [WalletUTXO]) -> Bool {
        var total: UInt64 = 0
        for utxo in utxos {
            let addition = total.addingReportingOverflow(utxo.amount)
            guard !addition.overflow else { return false }
            total = addition.partialValue
        }
        return update(id: id) { vault in
            let covenantIDs = utxos.compactMap(\.covenantID).sorted()
            let onChainStatus: ProtectedVault.Status
            let onChainBalance: UInt64
            let onChainOutpoints: [String]
            let onChainCovenantIDs: [String]
            // An approved withdrawal is terminal for this vault record. A
            // concurrent address refresh can return a stale funding UTXO,
            // and a later empty refresh must not regress the status to
            // Funding Broadcast after that withdrawal has been recorded.
            if vault.status == .spent || vault.approvedWithdrawalTransactionID != nil {
                onChainStatus = .spent
                onChainBalance = 0
                onChainOutpoints = []
                onChainCovenantIDs = []
            } else if utxos.isEmpty {
                onChainStatus = vault.status == .pendingWithdrawal
                    ? .pendingWithdrawal
                    : (vault.fundingTransactionID == nil ? .localDraft : .fundingBroadcast)
                onChainOutpoints = []
                onChainCovenantIDs = []
                // While a delayed withdrawal is in progress, the original vault
                // address is expected to be empty. Preserve its last known value.
                onChainBalance = vault.status == .pendingWithdrawal ? (vault.lockedSompi ?? 0) : 0
            } else if utxos.allSatisfy({
                ProtectedVaultStageOutput(utxo: $0).isCovenantTagged
            }) {
                onChainStatus = .active
                onChainBalance = total
                onChainOutpoints = utxos.map(\.id).sorted()
                onChainCovenantIDs = covenantIDs
            } else {
                onChainStatus = .incompatibleFunding
                onChainBalance = total
                onChainOutpoints = utxos.map(\.id).sorted()
                onChainCovenantIDs = covenantIDs
            }
            return replacing(vault,
                status: onChainStatus,
                fundingTransactionID: vault.fundingTransactionID, fundedAt: vault.fundedAt,
                lockedSompi: onChainBalance, fundingOutpoints: onChainOutpoints,
                covenantIDs: onChainCovenantIDs)
        }
    }

    @discardableResult
    func refreshOnChain(
        id: UUID,
        engine: KasSignerEngine,
        preferences: AppPreferences
    ) async throws -> [WalletUTXO] {
        guard let vault = vaults.first(where: { $0.id == id }),
              let address = vault.vaultAddress else { return [] }

        let now = Date()
        let network = preferences.network.title
        let nodeLabel = ProtectedVaultNodeLabel.make(preferences: preferences)
        var state = refreshState(for: id)
        state.begin(at: now, network: network, nodeLabel: nodeLabel)
        setRefreshState(state, for: id)

        do {
            let result = try await engine.syncAddress(
                address,
                nodeConfiguration: preferences.nodeConfiguration
            )
            var pendingResults: [(ProtectedVault.PendingWithdrawal, [WalletUTXO])] = []
            if preferences.network == .testnet10 {
                for pending in vault.pendingWithdrawals where pending.completedAt == nil {
                    let pendingResult = try await engine.syncAddress(
                        pending.pendingAddress,
                        nodeConfiguration: preferences.nodeConfiguration
                    )
                    pendingResults.append((pending, pendingResult.utxos))
                }
            }

            guard updateOnChainFunding(id: id, utxos: result.utxos) else {
                throw KasSignerEngine.EngineError.javascript(
                    "The refreshed vault data could not be saved."
                )
            }
            for (pending, utxos) in pendingResults {
                if let pendingUTXO = ProtectedVaultStageOutput.classify(utxos)
                    .filter({ $0.isCovenantTagged })
                    .map(\.utxo)
                    .sorted(by: { $0.id < $1.id })
                    .first {
                    guard recordPendingWithdrawal(
                        id: vault.id,
                        destination: pending.destinationAddress,
                        pendingAddress: pending.pendingAddress,
                        transactionID: pending.transactionID,
                        pendingBalanceSompi: pendingUTXO.amount,
                        pendingBlockDAAScore: pendingUTXO.blockDAAScore
                    ) else {
                        throw KasSignerEngine.EngineError.javascript(
                            "The refreshed withdrawal data could not be saved."
                        )
                    }
                }
            }

            let info = ProtectedVaultRefreshInfo(
                checkedAt: Date(), network: network, nodeLabel: nodeLabel
            )
            var refreshedState = refreshState(for: id)
            refreshedState.succeed(with: info)
            setRefreshState(refreshedState, for: id)
            guard storageError == nil else {
                throw KasSignerEngine.EngineError.javascript(
                    "The vault refresh status could not be saved."
                )
            }
            return result.utxos
        } catch {
            var failedState = refreshState(for: id)
            failedState.fail(message: Self.refreshFailureMessage())
            setRefreshState(failedState, for: id)
            throw error
        }
    }

    private static func refreshFailureMessage() -> String {
        // Keep raw connection errors off-screen because they may echo custom
        // node URLs containing credentials or tokens.
        return "Could not refresh on-chain data. Check the network connection and try again."
    }

    func refreshAllOnChain(
        profileID: UUID,
        engine: KasSignerEngine,
        preferences: AppPreferences
    ) async {
        for vault in vaults(for: profileID) {
            do {
                _ = try await refreshOnChain(
                    id: vault.id,
                    engine: engine,
                    preferences: preferences
                )
            } catch {
                // A failed lookup is retried on the next node event or activation.
            }
        }
    }

    @discardableResult
    private func update(id: UUID, transform: (ProtectedVault) -> ProtectedVault) -> Bool {
        guard let index = vaults.firstIndex(where: { $0.id == id }) else { return false }
        return commit { vaults[index] = transform(vaults[index]) }
    }

    private func replacing(_ vault: ProtectedVault, status: ProtectedVault.Status,
                           fundingTransactionID: String?, fundedAt: Date?,
                           approvedWithdrawalTransactionID: String? = nil,
                           lockedSompi: UInt64?, fundingOutpoints: [String],
                           covenantIDs: [String],
                           pendingWithdrawals: [ProtectedVault.PendingWithdrawal]? = nil) -> ProtectedVault {
        ProtectedVault(id: vault.id, profileID: vault.profileID, name: vault.name, amount: vault.amount,
            usesSendMaxFunding: vault.usesSendMaxFunding,
            approvedAddresses: vault.approvedAddresses,
            recoveryAddress: vault.recoveryAddress, recoveryPath: vault.recoveryPath,
            delayDays: vault.delayDays,
            delayHours: vault.delayHours, delayMinutes: vault.delayMinutes,
            ownerDerivationIndex: vault.ownerDerivationIndex, ownerPublicKey: vault.ownerPublicKey,
            redeemScriptHex: vault.redeemScriptHex, vaultAddress: vault.vaultAddress,
            createdAt: vault.createdAt, status: status,
            fundingTransactionID: fundingTransactionID,
            approvedWithdrawalTransactionID: approvedWithdrawalTransactionID ?? vault.approvedWithdrawalTransactionID,
            fundedAt: fundedAt,
            lockedSompi: lockedSompi, fundingOutpoints: fundingOutpoints,
            covenantIDs: covenantIDs,
            pendingWithdrawals: pendingWithdrawals ?? vault.pendingWithdrawals)
    }

    private func load() {
        do {
            if let saved = try protectedStorage.loadIfPresent(
                ProtectedVaultPersistentState.self, fileName: protectedFileName
            ) {
                guard saved.version == 1 else {
                    storageError = "This vault registry version is not supported. Its file was left intact."
                    return
                }
                vaults = saved.vaults
                setupDrafts = saved.setupDrafts
                lastOpenedAtByItemKey = saved.lastOpenedAtByItemKey
                walletFingerprintsByProfileID = saved.walletFingerprintsByProfileID
                refreshStatesByVaultID = saved.refreshStatesByVaultID ?? [:]
                var restoredRefreshStates: [UUID: ProtectedVaultRefreshState] = [:]
                for (key, savedState) in refreshStatesByVaultID {
                    guard let id = UUID(uuidString: key) else { continue }
                    var state = savedState
                    if state.isRefreshing { state.markInterrupted() }
                    restoredRefreshStates[id] = state
                }
                refreshStates = restoredRefreshStates
                refreshStatesByVaultID = Dictionary(uniqueKeysWithValues: refreshStates.map { ($0.key.uuidString, $0.value) })
                return
            }
        } catch {
            storageError = "The protected vault registry could not be read. Its file was left intact: \(error.localizedDescription)"
            return
        }
        do {
            if let data = defaults.data(forKey: storageKey) {
                vaults = try JSONDecoder().decode([ProtectedVault].self, from: data)
            }
            if let data = defaults.data(forKey: setupDraftStorageKey) {
                setupDrafts = try JSONDecoder().decode([ProtectedVaultSetupDraft].self, from: data)
            }
            if let data = defaults.data(forKey: lastOpenedStorageKey) {
                lastOpenedAtByItemKey = try JSONDecoder().decode([String: Date].self, from: data)
            }
        } catch {
            storageError = "Legacy vault data could not be decoded. It was left intact: \(error.localizedDescription)"
            vaults = []
            setupDrafts = []
            lastOpenedAtByItemKey = [:]
            return
        }
        guard persist() else { return }
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: setupDraftStorageKey)
        defaults.removeObject(forKey: lastOpenedStorageKey)
    }

    @discardableResult
    private func commit(_ change: () -> Void) -> Bool {
        guard storageError == nil else { return false }
        let previousVaults = vaults
        let previousDrafts = setupDrafts
        let previousDates = lastOpenedAtByItemKey
        let previousFingerprints = walletFingerprintsByProfileID
        let previousRefreshStates = refreshStatesByVaultID
        change()
        guard persist() else {
            vaults = previousVaults
            setupDrafts = previousDrafts
            lastOpenedAtByItemKey = previousDates
            walletFingerprintsByProfileID = previousFingerprints
            refreshStatesByVaultID = previousRefreshStates
            return false
        }
        return true
    }

    private func persist() -> Bool {
        let state = ProtectedVaultPersistentState(
            vaults: vaults, setupDrafts: setupDrafts,
            lastOpenedAtByItemKey: lastOpenedAtByItemKey,
            walletFingerprintsByProfileID: walletFingerprintsByProfileID,
            refreshStatesByVaultID: refreshStatesByVaultID
        )
        guard protectedStorage.save(state, fileName: protectedFileName) else {
            storageError = "The vault registry could not be saved. Check device storage before continuing."
            return false
        }
        return true
    }

    private func lastOpenedItemKey(id: UUID, profileID: UUID) -> String {
        "\(profileID.uuidString):\(id.uuidString)"
    }
}
