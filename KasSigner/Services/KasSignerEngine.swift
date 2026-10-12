import Foundation
@preconcurrency import WebKit

struct AddressValidationResult: Codable {
    let valid: Bool
    let network: String?
    let normalized: String?
    let reason: String?
}

struct FeeEstimate: Decodable, Equatable {
    let lowSompiPerGram: Double
    let normalSompiPerGram: Double
    let prioritySompiPerGram: Double
    let suggestedFee: UInt64
    let lowSeconds: Double
    let normalSeconds: Double
    let prioritySeconds: Double

    private enum CodingKeys: String, CodingKey {
        case lowSompiPerGram = "low_sompi_per_gram"
        case normalSompiPerGram = "normal_sompi_per_gram"
        case prioritySompiPerGram = "priority_sompi_per_gram"
        case suggestedFee = "suggested_fee"
        case lowSeconds = "low_seconds"
        case normalSeconds = "normal_seconds"
        case prioritySeconds = "priority_seconds"
    }
}

struct ChangeFeePlan: Decodable, Equatable {
    let feeSompi: UInt64
    let availableChangeSompi: UInt64
    let amountsSompi: [UInt64]

    private enum CodingKeys: String, CodingKey {
        case feeSompi = "fee_sompi"
        case availableChangeSompi = "available_change_sompi"
        case amountsSompi = "amounts_sompi"
    }
}

struct SendDraftInput: Encodable, Hashable {
    let transactionID: String
    let index: UInt32
    let amountSompi: UInt64
    let scriptPublicKey: String
    let blockDAAScore: UInt64
    let derivationChain: String
    let derivationIndex: UInt32

    init(utxo: WalletUTXO) throws {
        let transactionID = utxo.txID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let scriptPublicKey = utxo.scriptPublicKey
            .map { String(format: "%02x", $0) }
            .joined()

        guard transactionID.count == 64,
              transactionID.allSatisfy({ $0.isHexDigit })
        else {
            throw SendDraftError.invalidTransactionID
        }

        guard !scriptPublicKey.isEmpty,
              scriptPublicKey.count.isMultiple(of: 2),
              scriptPublicKey.allSatisfy({ $0.isHexDigit })
        else {
            throw SendDraftError.invalidScriptPublicKey
        }

        guard utxo.amount > 0 else {
            throw SendDraftError.zeroValueInput
        }

        guard let derivationChain = utxo.derivationChain,
              derivationChain == "receive" || derivationChain == "change",
              let derivationIndex = utxo.derivationIndex
        else {
            throw SendDraftError.unresolvedInputDerivation(outpoint: utxo.id)
        }

        self.transactionID = transactionID.lowercased()
        self.index = utxo.index
        self.amountSompi = utxo.amount
        self.scriptPublicKey = scriptPublicKey.lowercased()
        self.blockDAAScore = utxo.blockDAAScore
        self.derivationChain = derivationChain
        self.derivationIndex = derivationIndex
    }

    private enum CodingKeys: String, CodingKey {
        case transactionID = "tx_id"
        case index
        case amountSompi = "amount"
        case scriptPublicKey = "script_public_key"
        case blockDAAScore = "block_daa_score"
        case derivationChain = "derivation_chain"
        case derivationIndex = "derivation_index"
    }

    var outpointKey: String {
        "\(transactionID):\(index)"
    }
}

struct SendDraft {
    let profile: WalletProfile
    let transactionType: SendTransactionType
    let selectedInputs: [SendDraftInput]
    let recipients: [SendDraftRecipient]
    let destination: String
    let amountSompi: UInt64
    let feeSompi: UInt64
    let feeRateSompiPerGram: Double
    let usesExactFee: Bool
    let sendMax: Bool
    let changeOutputs: [PlannedChangeOutput]
    let selectedTotalSompi: UInt64

    init(
        profile: WalletProfile,
        transactionType: SendTransactionType = .standard,
        selectedUTXOs: [WalletUTXO],
        recipients: [SendDraftRecipient],
        feeSompi: UInt64,
        feeRateSompiPerGram: Double,
        usesExactFee: Bool,
        sendMax: Bool,
        changeOutputs: [PlannedChangeOutput] = []
    ) throws {
        guard !recipients.isEmpty, recipients.count <= 4 else {
            throw SendDraftError.emptyDestination
        }
        guard transactionType != .decoy || recipients.count == 1 else {
            throw SendDraftError.tooManyRecipientsForDecoy
        }
        let normalizedRecipients = recipients.map {
            SendDraftRecipient(
                address: $0.address.trimmingCharacters(in: .whitespacesAndNewlines),
                amountSompi: $0.amountSompi
            )
        }
        guard normalizedRecipients.allSatisfy({ !$0.address.isEmpty }) else {
            throw SendDraftError.emptyDestination
        }
        guard Set(normalizedRecipients.map { $0.address.lowercased() }).count == normalizedRecipients.count else {
            throw SendDraftError.duplicateRecipient
        }
        guard normalizedRecipients.allSatisfy({ $0.amountSompi > 0 }) else {
            throw SendDraftError.zeroAmount
        }

        guard !selectedUTXOs.isEmpty else {
            throw SendDraftError.noSelectedInputs
        }

        guard selectedUTXOs.count <= UTXOCoinControlStore.maximumSelectedUTXOs
        else {
            throw SendDraftError.tooManySelectedInputs
        }

        let selectedInputs = try selectedUTXOs.map { utxo in
            try SendDraftInput(utxo: utxo)
        }

        guard Set(selectedInputs.map { $0.outpointKey }).count == selectedInputs.count
        else {
            throw SendDraftError.duplicateOutpoint
        }

        var selectedTotalSompi: UInt64 = 0

        for input in selectedInputs {
            let addition = selectedTotalSompi.addingReportingOverflow(
                input.amountSompi
            )

            guard !addition.overflow else {
                throw SendDraftError.inputTotalOverflow
            }

            selectedTotalSompi = addition.partialValue
        }

        let recipientTotal = normalizedRecipients.reduce(into: UInt64?.some(0)) { total, recipient in
            guard let current = total else { return }
            let addition = current.addingReportingOverflow(recipient.amountSompi)
            total = addition.overflow ? nil : addition.partialValue
        }
        guard let recipientTotal else { throw SendDraftError.requiredTotalOverflow }
        let required = recipientTotal.addingReportingOverflow(feeSompi)

        guard !required.overflow else {
            throw SendDraftError.requiredTotalOverflow
        }

        guard required.partialValue <= selectedTotalSompi else {
            throw SendDraftError.insufficientSelectedInputs
        }

        self.profile = profile
        self.transactionType = transactionType
        self.selectedInputs = selectedInputs
        self.recipients = normalizedRecipients
        self.destination = normalizedRecipients[0].address
        self.amountSompi = normalizedRecipients[0].amountSompi
        self.feeSompi = feeSompi
        self.feeRateSompiPerGram = feeRateSompiPerGram
        self.usesExactFee = usesExactFee
        self.sendMax = sendMax
        self.changeOutputs = changeOutputs
        self.selectedTotalSompi = selectedTotalSompi
    }
}

enum SendDraftError: LocalizedError {
    case emptyDestination
    case duplicateRecipient
    case tooManyRecipientsForDecoy
    case zeroAmount
    case noSelectedInputs
    case tooManySelectedInputs
    case invalidTransactionID
    case invalidScriptPublicKey
    case zeroValueInput
    case duplicateOutpoint
    case inputTotalOverflow
    case requiredTotalOverflow
    case insufficientSelectedInputs
    case unresolvedInputDerivation(outpoint: String)

    var errorDescription: String? {
        switch self {
        case .emptyDestination:
            return "The destination address is empty."
        case .duplicateRecipient:
            return "Each destination address may be used only once."
        case .tooManyRecipientsForDecoy:
            return "Decoy Transaction supports exactly one recipient."
        case .zeroAmount:
            return "The send amount must be greater than zero."
        case .noSelectedInputs:
            return "No UTXOs were selected."
        case .tooManySelectedInputs:
            return "A transaction can use at most 8 selected UTXOs."
        case .invalidTransactionID:
            return "A selected UTXO has an invalid transaction ID."
        case .invalidScriptPublicKey:
            return "A selected UTXO has an invalid script public key."
        case .zeroValueInput:
            return "A selected UTXO has a zero amount."
        case .duplicateOutpoint:
            return "The selected UTXOs contain a duplicate outpoint."
        case .inputTotalOverflow:
            return "The selected UTXO total is too large."
        case .requiredTotalOverflow:
            return "The amount and fee total is too large."
        case .insufficientSelectedInputs:
            return "The selected UTXOs cannot cover the amount and fee."
        case let .unresolvedInputDerivation(outpoint):
            return "The selected UTXO \(outpoint) could not be matched to a receive or change address in this wallet."
        }
    }
}

struct SendDraftRecipient: Codable, Equatable {
    let address: String
    let amountSompi: UInt64

    private enum CodingKeys: String, CodingKey {
        case address
        case amountSompi = "amount_sompi"
    }
}



struct PSKTSummary: Decodable, Equatable {
    let transactionVersion: UInt16?
    let totalInputSompi: UInt64?
    let totalOutputSompi: UInt64?
    let feeSompi: UInt64?
    let inputCount: Int?
    let outputCount: Int?
    let inputs: [PSKTSummaryInput]?
    let outputs: [PSKTSummaryOutput]?
    let finalizeReady: Bool?

    init(
        totalInputSompi: UInt64?, totalOutputSompi: UInt64?, feeSompi: UInt64?,
        inputCount: Int?, outputCount: Int?, inputs: [PSKTSummaryInput]?,
        outputs: [PSKTSummaryOutput]?, finalizeReady: Bool? = nil,
        transactionVersion: UInt16? = nil
    ) {
        self.transactionVersion = transactionVersion
        self.totalInputSompi = totalInputSompi
        self.totalOutputSompi = totalOutputSompi
        self.feeSompi = feeSompi
        self.inputCount = inputCount
        self.outputCount = outputCount
        self.inputs = inputs
        self.outputs = outputs
        self.finalizeReady = finalizeReady
    }

    private enum CodingKeys: String, CodingKey {
        case transactionVersion = "tx_version"
        case totalInputSompi = "total_in_sompi"
        case totalOutputSompi = "total_out_sompi"
        case feeSompi = "fee_sompi"
        case inputCount = "input_count"
        case outputCount = "output_count"
        case inputs
        case outputs
        case finalizeReady = "finalize_ready"
    }
}

struct PSKTSummaryInput: Decodable, Equatable {
    let txID: String?
    let index: UInt32?
    let amountSompi: UInt64?
    let scriptHex: String?
    let signaturesPresent: Int?

    init(
        txID: String?, index: UInt32?, amountSompi: UInt64? = nil,
        scriptHex: String? = nil, signaturesPresent: Int? = nil
    ) {
        self.txID = txID
        self.index = index
        self.amountSompi = amountSompi
        self.scriptHex = scriptHex
        self.signaturesPresent = signaturesPresent
    }

    private enum CodingKeys: String, CodingKey {
        case txID = "prev_tx_id"
        case index = "prev_index"
        case amountSompi = "amount_sompi"
        case scriptHex = "script_hex"
        case signaturesPresent = "sigs_present"
    }
}

struct PSKTSummaryOutput: Decodable, Equatable {
    let address: String?
    let amountSompi: UInt64?
    let scriptHex: String?
    let covenantAuthorizingInput: UInt16?
    let covenantID: String?

    init(
        address: String?, amountSompi: UInt64?, scriptHex: String? = nil,
        covenantAuthorizingInput: UInt16? = nil, covenantID: String? = nil
    ) {
        self.address = address
        self.amountSompi = amountSompi
        self.scriptHex = scriptHex
        self.covenantAuthorizingInput = covenantAuthorizingInput
        self.covenantID = covenantID
    }

    private enum CodingKeys: String, CodingKey {
        case address
        case amountSompi = "amount_sompi"
        case scriptHex = "script_hex"
        case covenantAuthorizingInput = "covenant_authorizing_input"
        case covenantID = "covenant_id"
    }
}


struct KasSeeQRFrame: Decodable, Hashable {
    let frameNumber: Int
    let totalFrames: Int
    let svg: String

    private enum CodingKeys: String, CodingKey {
        case frameNumber = "frame_num"
        case totalFrames = "total_frames"
        case svg
    }
}

struct QRDecoderProgress: Decodable, Equatable {
    let count: Int
    let total: Int
    let bits: [Bool]

    private enum CodingKeys: String, CodingKey {
        case count
        case total
        case bits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        count = try container.decode(Int.self, forKey: .count)
        total = try container.decode(Int.self, forKey: .total)

        if let booleanBits = try? container.decode(
            [Bool].self,
            forKey: .bits
        ) {
            bits = booleanBits
        } else {
            let numericBits = try container.decode(
                [Int].self,
                forKey: .bits
            )
            bits = numericBits.map { $0 != 0 }
        }
    }
}

@MainActor
final class KasSignerEngine: NSObject, ObservableObject {

    @Published private(set) var rpcNotificationVersion = 0

    enum EngineError: LocalizedError {
        case resourceMissing
        case notReady
        case invalidResponse
        case javascript(String)

        var errorDescription: String? {
            switch self {
            case .resourceMissing:
                return "The embedded KasSigner engine files are missing."
            case .notReady:
                return "KasSigner is still starting."
            case .invalidResponse:
                return "KasSigner returned an unreadable response."
            case .javascript(let message):
                return message
            }
        }
    }

    @Published private(set) var isReady = false
    @Published private(set) var statusText = "Starting KasSigner…"

    private let schemeHandler = KasSignerSchemeHandler()
    private let bridgeLoadToken = UUID().uuidString
    private var hasStarted = false
    private var desiredRuntimeActive = true

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        // The engine is fully bundled and does not need persistent website
        // storage. Keep transaction and wallet bridge state memory-only.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(self, name: "kaspi")
        configuration.setURLSchemeHandler(
            schemeHandler,
            forURLScheme: KasSignerSchemeHandler.scheme
        )

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
#if DEBUG
        if #available(iOS 16.4, *) {
            view.isInspectable = true
        }
#endif
        view.isHidden = true
        return view
    }()

    override init() {
        super.init()
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        loadEngine()
    }

    func attachedWebView() -> WKWebView {
        startIfNeeded()
        return webView
    }

    func setRuntimeActive(_ active: Bool) async {
        desiredRuntimeActive = active

        guard isReady else { return }

        do {
            _ = try await webView.callAsyncJavaScript(
                "await window.kaspi.setRuntimeActive(active);",
                arguments: ["active": active],
                in: nil,
                contentWorld: .page
            )
        } catch {
            // Activation reconciliation will retry after the engine or
            // WebKit content process becomes ready again.
        }
    }

    func buildUTXOSubscriptionRequest(
        address: String,
        requestID: UInt64
    ) async throws -> Data {
        try await ensureReady()

        let result = try await webView.callAsyncJavaScript(
            """
            return Array.from(
                window.kaspi.buildUTXOSubscriptionRequest(address, requestID)
            );
            """,
            arguments: [
                "address": address,
                "requestID": String(requestID)
            ],
            in: nil,
            contentWorld: .page
        )

        guard let values = result as? [NSNumber], !values.isEmpty else {
            throw EngineError.invalidResponse
        }

        return Data(values.map { UInt8(truncating: $0) })
    }

    func addressesOwningUTXOs(
        _ utxos: [WalletUTXO],
        profile: WalletProfile
    ) async throws -> [String] {
        guard !utxos.isEmpty else { return [] }
        try await ensureReady()

        let scripts = utxos.map { utxo in
            utxo.scriptPublicKey.map { String(format: "%02x", $0) }.joined()
        }
        let addresses = profile.receiveAddresses + profile.changeAddresses
        let result = try await webView.callAsyncJavaScript(
            """
            const targets = new Set(scripts.map(value => String(value).toLowerCase()));
            return addresses.filter(address => {
                const script = scriptKey(scriptPublicKeyForAddress(address));
                return targets.has(script.toLowerCase());
            });
            """,
            arguments: [
                "scripts": scripts,
                "addresses": addresses
            ],
            in: nil,
            contentWorld: .page
        )

        guard let matched = result as? [String] else {
            throw EngineError.invalidResponse
        }
        return Array(Set(matched)).sorted()
    }

    func importKpub(_ kpub: String, network: KaspaNetwork = .mainnet) async throws -> WalletImportResult {
        try await ensureReady()

        let payload = try JSONSerialization.data(
            withJSONObject: ["kpub": kpub, "network": network.rawValue]
        )

        guard let json = String(data: payload, encoding: .utf8) else {
            throw EngineError.invalidResponse
        }

        let response: String = try await withCheckedThrowingContinuation {
            continuation in

            webView.evaluateJavaScript(
                "window.kaspi.importKpub(\(json))"
            ) { result, error in
                if let error {
                    continuation.resume(
                        throwing: EngineError.javascript(
                            error.localizedDescription
                        )
                    )
                    return
                }

                guard let text = result as? String else {
                    continuation.resume(
                        throwing: EngineError.invalidResponse
                    )
                    return
                }

                continuation.resume(returning: text)
            }
        }

        guard
            let data = response.data(using: .utf8),
            let wallet = try? JSONDecoder().decode(
                WalletImportResult.self,
                from: data
            ),
            !wallet.receiveAddresses.isEmpty,
            !wallet.changeAddresses.isEmpty
        else {
            throw EngineError.invalidResponse
        }

        return wallet
    }

    func testnetHotWallet(mnemonic: String? = nil) async throws -> TestnetHotWalletImportResult {
        try await ensureReady()
        let result = try await webView.callAsyncJavaScript(
            "return mnemonic == null ? window.kaspi.generateTestnet10Wallet() : window.kaspi.restoreTestnet10Wallet(mnemonic);",
            arguments: ["mnemonic": mnemonic as Any? ?? NSNull()],
            in: nil,
            contentWorld: .page
        )
        guard let json = result as? [String: Any] else { throw EngineError.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(TestnetHotWalletImportResult.self, from: data)
    }


    func validateAddress(
        _ address: String
    ) async throws -> AddressValidationResult {

        try await ensureReady()

        let result = try await webView.callAsyncJavaScript(
            "return window.kaspi.validateAddress(address);",
            arguments: [
                "address": address
            ],
            in: nil,
            contentWorld: .page
        )

        guard
            let json = result as? [String: Any]
        else {
            throw EngineError.invalidResponse
        }

        let data = try JSONSerialization.data(withJSONObject: json)

        return try JSONDecoder().decode(
            AddressValidationResult.self,
            from: data
        )
    }

    func deriveProtectedVault(
        profile: WalletProfile,
        receiveIndex: Int,
        approvedAddresses: [String],
        recoveryAddress: String,
        emergencyAnytime: Bool,
        delayDAA: UInt64
    ) async throws -> ProtectedVaultDescriptor {
        guard profile.network == KaspaNetwork.testnet10.rawValue else {
            throw EngineError.javascript(
                "Protected Vaults are not yet available on Mainnet."
            )
        }
        try await ensureReady()

        let result = try await webView.callAsyncJavaScript(
            "return window.kaspi.deriveProtectedVault(kpub, receiveIndex, approvedAddresses, recoveryAddress, delayDAA, emergencyAnytime, network);",
            arguments: [
                "kpub": profile.kpub,
                "receiveIndex": receiveIndex,
                "approvedAddresses": approvedAddresses,
                "recoveryAddress": recoveryAddress,
                "emergencyAnytime": emergencyAnytime,
                "delayDAA": String(delayDAA),
                "network": profile.network
            ],
            in: nil,
            contentWorld: .page
        )

        guard let json = result as? [String: Any] else {
            throw EngineError.invalidResponse
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(ProtectedVaultDescriptor.self, from: data)
    }


    func getFeeEstimate(
        nodeConfiguration: [String: Any]
    ) async throws -> FeeEstimate {
        try await ensureReady()

        let result = try await webView.callAsyncJavaScript(
            "return await window.kaspi.getFeeEstimate(nodeConfig);",
            arguments: [
                "nodeConfig": nodeConfiguration
            ],
            in: nil,
            contentWorld: .page
        )

        guard let json = result as? String,
              let data = json.data(using: .utf8)
        else {
            throw EngineError.invalidResponse
        }

        do {
            return try JSONDecoder().decode(FeeEstimate.self, from: data)
        } catch {
            throw EngineError.javascript(
                "Kaspa fee estimate could not be decoded: \(error.localizedDescription)"
            )
        }
    }


    func buildUnsignedPSKB(from draft: SendDraft) async throws -> String {
        try await ensureReady()

        let wallet: [String: Any] = [
            "kpub": draft.profile.kpub,
            "receive_addresses": draft.profile.receiveAddresses,
            "change_addresses": draft.profile.changeAddresses,
            "next_receive_index": draft.profile.nextReceiveIndex,
            "next_change_index": draft.profile.nextChangeIndex
        ]

        let utxosData: Data

        do {
            utxosData = try JSONEncoder().encode(draft.selectedInputs)
        } catch {
            throw EngineError.javascript(
                "Selected UTXOs could not be encoded: \(error.localizedDescription)"
            )
        }

        guard let utxosJSON = String(data: utxosData, encoding: .utf8)
        else {
            throw EngineError.invalidResponse
        }

        let changeOutputsData = try JSONEncoder().encode(draft.changeOutputs)
        let recipientsData = try JSONEncoder().encode(draft.recipients)
        guard let changeOutputsJSON = String(data: changeOutputsData, encoding: .utf8),
              let recipientsJSON = String(data: recipientsData, encoding: .utf8) else {
            throw EngineError.invalidResponse
        }

        let result = try await webView.callAsyncJavaScript(
            """
            try {
                const value = await window.kaspi.buildUnsignedPSKB(
                    wallet,
                    transactionMode,
                    recipientsJSON,
                    feeSompi,
                    feeRateSompiPerGram,
                    usesExactFee,
                    sendMax,
                    changeOutputsJSON,
                    utxosJSON
                );
                return { ok: true, value };
            } catch (error) {
                return {
                    ok: false,
                    error: String(error?.message ?? error)
                };
            }
            """,
            arguments: [
                "wallet": wallet,
                "transactionMode": draft.transactionType.rawValue,
                "recipientsJSON": recipientsJSON,
                "feeSompi": String(draft.feeSompi),
                "feeRateSompiPerGram": draft.feeRateSompiPerGram,
                "usesExactFee": draft.usesExactFee,
                "sendMax": draft.sendMax,
                "changeOutputsJSON": changeOutputsJSON,
                "utxosJSON": utxosJSON
            ],
            in: nil,
            contentWorld: .page
        )

        guard let response = result as? [String: Any],
              let succeeded = response["ok"] as? Bool
        else {
            throw EngineError.invalidResponse
        }

        guard succeeded else {
            let message = response["error"] as? String
                ?? "The transaction runtime rejected the selected inputs."
            throw EngineError.javascript(message)
        }

        guard let pskb = response["value"] as? String else {
            throw EngineError.invalidResponse
        }

        let normalized = pskb.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !normalized.isEmpty,
              normalized.count.isMultiple(of: 2),
              normalized.allSatisfy({ $0.isHexDigit })
        else {
            throw EngineError.javascript(
                "The unsigned PSKB response was not valid hexadecimal."
            )
        }

        return normalized.lowercased()
    }

    func planChangeOutputs(from draft: SendDraft) async throws -> ChangeFeePlan {
        try await ensureReady()

        let wallet: [String: Any] = [
            "kpub": draft.profile.kpub,
            "receive_addresses": draft.profile.receiveAddresses,
            "change_addresses": draft.profile.changeAddresses,
            "next_receive_index": draft.profile.nextReceiveIndex,
            "next_change_index": draft.profile.nextChangeIndex
        ]
        let utxosData = try JSONEncoder().encode(draft.selectedInputs)
        let changeOutputsData = try JSONEncoder().encode(draft.changeOutputs)
        let recipientsData = try JSONEncoder().encode(draft.recipients)
        guard let utxosJSON = String(data: utxosData, encoding: .utf8),
              let changeOutputsJSON = String(data: changeOutputsData, encoding: .utf8),
              let recipientsJSON = String(data: recipientsData, encoding: .utf8)
        else {
            throw EngineError.invalidResponse
        }

        let result = try await webView.callAsyncJavaScript(
            """
            try {
                const value = window.kaspi.planChangeOutputs(
                    wallet,
                    transactionMode,
                    recipientsJSON,
                    feeSompi,
                    feeRateSompiPerGram,
                    usesExactFee,
                    changeOutputsJSON,
                    utxosJSON
                );
                return { ok: true, value };
            } catch (error) {
                return { ok: false, error: String(error?.message ?? error) };
            }
            """,
            arguments: [
                "wallet": wallet,
                "transactionMode": draft.transactionType.rawValue,
                "recipientsJSON": recipientsJSON,
                "feeSompi": String(draft.feeSompi),
                "feeRateSompiPerGram": draft.feeRateSompiPerGram,
                "usesExactFee": draft.usesExactFee,
                "changeOutputsJSON": changeOutputsJSON,
                "utxosJSON": utxosJSON
            ],
            in: nil,
            contentWorld: .page
        )
        guard let response = result as? [String: Any],
              let succeeded = response["ok"] as? Bool
        else {
            throw EngineError.invalidResponse
        }
        guard succeeded else {
            throw EngineError.javascript(
                response["error"] as? String ?? "The fee calculation failed."
            )
        }
        guard let json = response["value"] as? String,
              let data = json.data(using: .utf8)
        else {
            throw EngineError.invalidResponse
        }
        return try JSONDecoder().decode(ChangeFeePlan.self, from: data)
    }



    func buildProtectedVaultFundingPSKB(
        profile: WalletProfile,
        selectedInputs: [WalletUTXO],
        vaultAddress: String,
        amountSompi: UInt64,
        feeSompi: UInt64
    ) async throws -> String {
        guard profile.network == KaspaNetwork.testnet10.rawValue else {
            throw EngineError.javascript(
                "Protected Vaults are not yet available on Mainnet."
            )
        }
        try await ensureReady()
        let wallet: [String: Any] = [
            "kpub": profile.kpub,
            "receive_addresses": profile.receiveAddresses,
            "change_addresses": profile.changeAddresses,
            "next_receive_index": profile.nextReceiveIndex,
            "next_change_index": profile.nextChangeIndex
        ]
        let utxosData = try JSONEncoder().encode(selectedInputs)
        guard let utxosJSON = String(data: utxosData, encoding: .utf8) else {
            throw EngineError.invalidResponse
        }
        let result = try await webView.callAsyncJavaScript(
            """
            try {
                const value = await window.kaspi.buildProtectedVaultFundingPSKB(
                    wallet, vaultAddress, amountSompi, feeSompi, utxosJSON
                );
                return { ok: true, value };
            } catch (error) {
                return { ok: false, error: String(error?.message ?? error) };
            }
            """,
            arguments: [
                "wallet": wallet,
                "vaultAddress": vaultAddress,
                "amountSompi": String(amountSompi),
                "feeSompi": String(feeSompi),
                "utxosJSON": utxosJSON
            ],
            in: nil,
            contentWorld: .page
        )
        guard let response = result as? [String: Any] else { throw EngineError.invalidResponse }
        guard response["ok"] as? Bool == true else {
            throw EngineError.javascript(response["error"] as? String ?? "Tagged vault funding failed.")
        }
        guard let value = response["value"] as? String else { throw EngineError.invalidResponse }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized.count.isMultiple(of: 2),
              normalized.allSatisfy(\.isHexDigit) else {
            throw EngineError.javascript("The tagged funding PSKB was not valid hexadecimal.")
        }
        return normalized
    }

    func buildProtectedVaultApprovedSpendPSKB(
        utxo: WalletUTXO,
        redeemScriptHex: String,
        approvedAddress: String,
        feeSompi: UInt64
    ) async throws -> String {
        try await ensureReady()
        let utxoData = try JSONEncoder().encode(utxo)
        guard let utxoJSON = String(data: utxoData, encoding: .utf8) else {
            throw EngineError.invalidResponse
        }
        let result = try await webView.callAsyncJavaScript(
            """
            try {
                const value = window.kaspi.buildProtectedVaultApprovedSpendPSKB(
                    utxoJSON, redeemScriptHex, approvedAddress, feeSompi
                );
                return { ok: true, value };
            } catch (error) {
                return { ok: false, error: String(error?.message ?? error) };
            }
            """,
            arguments: [
                "utxoJSON": utxoJSON,
                "redeemScriptHex": redeemScriptHex,
                "approvedAddress": approvedAddress,
                "feeSompi": String(feeSompi)
            ],
            in: nil,
            contentWorld: .page
        )
        guard let response = result as? [String: Any] else { throw EngineError.invalidResponse }
        guard response["ok"] as? Bool == true else {
            throw EngineError.javascript(
                response["error"] as? String ?? "The vault spend runtime rejected the transaction."
            )
        }
        guard let value = response["value"] as? String else { throw EngineError.invalidResponse }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized.count.isMultiple(of: 2),
              normalized.allSatisfy(\.isHexDigit) else { throw EngineError.invalidResponse }
        return normalized
    }

    func buildProtectedVaultV2SpendPSKB(
        utxo: WalletUTXO,
        vault: ProtectedVault,
        destination: String,
        path: String,
        feeSompi: UInt64
    ) async throws -> String {
        try await ensureReady()
        guard let owner = vault.ownerPublicKey,
              let recovery = vault.recoveryAddress,
              let recoveryPath = vault.recoveryPath else {
            throw EngineError.javascript("Vault recovery rules are missing.")
        }
        let utxoJSON = String(decoding: try JSONEncoder().encode(utxo), as: UTF8.self)
        let delayDAA = try protectedVaultDelayDAA(vault)
        let result = try await webView.callAsyncJavaScript(
            "return window.kaspi.buildProtectedVaultV2SpendPSKB(utxoJSON, owner, approved, recovery, destination, delayDAA, emergency, path, fee);",
            arguments: [
                "utxoJSON": utxoJSON, "owner": owner,
                "approved": vault.approvedAddresses, "recovery": recovery,
                "destination": destination, "delayDAA": String(delayDAA),
                "emergency": recoveryPath == .emergencyAnytime,
                "path": path, "fee": String(feeSompi)
            ], in: nil, contentWorld: .page
        )
        guard let signed = result as? String, !signed.isEmpty else { throw EngineError.invalidResponse }
        return signed
    }

    func buildProtectedVaultV2PendingSpendPSKB(
        utxo: WalletUTXO,
        vault: ProtectedVault,
        committedDestination: String,
        path: String,
        feeSompi: UInt64
    ) async throws -> String {
        try await ensureReady()
        guard let owner = vault.ownerPublicKey, let recovery = vault.recoveryAddress else {
            throw EngineError.javascript("Vault recovery rules are missing.")
        }
        let utxoJSON = String(decoding: try JSONEncoder().encode(utxo), as: UTF8.self)
        let delayDAA = try protectedVaultDelayDAA(vault)
        let result = try await webView.callAsyncJavaScript(
            "return window.kaspi.buildProtectedVaultV2PendingSpendPSKB(utxoJSON, owner, recovery, destination, delayDAA, path, fee);",
            arguments: [
                "utxoJSON": utxoJSON, "owner": owner, "recovery": recovery,
                "destination": committedDestination, "delayDAA": String(delayDAA),
                "path": path, "fee": String(feeSompi)
            ], in: nil, contentWorld: .page
        )
        guard let signed = result as? String, !signed.isEmpty else { throw EngineError.invalidResponse }
        return signed
    }

    func deriveProtectedVaultPendingWithRecovery(
        vault: ProtectedVault,
        destination: String
    ) async throws -> ProtectedVaultPendingDescriptor {
        try await ensureReady()
        guard let owner = vault.ownerPublicKey, let recovery = vault.recoveryAddress else {
            throw EngineError.javascript("Vault recovery rules are missing.")
        }
        let delayDAA = try protectedVaultDelayDAA(vault)
        let result = try await webView.callAsyncJavaScript(
            "return window.kaspi.deriveProtectedVaultPendingWithRecovery(owner, destination, recovery, delayDAA);",
            arguments: ["owner": owner, "destination": destination,
                        "recovery": recovery, "delayDAA": String(delayDAA)],
            in: nil, contentWorld: .page
        )
        guard let json = result as? [String: Any] else { throw EngineError.invalidResponse }
        return try JSONDecoder().decode(
            ProtectedVaultPendingDescriptor.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }

    private func protectedVaultDelayDAA(_ vault: ProtectedVault) throws -> UInt64 {
        guard (0...365).contains(vault.delayDays),
              (0...23).contains(vault.delayHours),
              (0...59).contains(vault.delayMinutes) else {
            throw EngineError.javascript("The saved vault delay is outside the supported range.")
        }
        let minutes = vault.delayDays * 1440 + vault.delayHours * 60 + vault.delayMinutes
        guard minutes > 0 else {
            throw EngineError.javascript("The vault security delay must be greater than zero.")
        }
        return UInt64(minutes) * 600
    }

    func signTestnet10VaultV2PSKB(
        _ wireHex: String,
        mnemonic: String,
        chain: Int,
        index: Int
    ) async throws -> String {
        try await ensureReady()
        let result = try await webView.callAsyncJavaScript(
            "return window.kaspi.signTestnet10VaultV2PSKB(wireHex, mnemonic, chain, index);",
            arguments: ["wireHex": wireHex, "mnemonic": mnemonic,
                        "chain": chain, "index": index],
            in: nil, contentWorld: .page
        )
        guard let signed = result as? String, !signed.isEmpty else { throw EngineError.invalidResponse }
        return signed
    }

    func verifyProtectedVaultApprovedSignature(_ wireHex: String) async throws {
        try await ensureReady()
        let result = try await webView.callAsyncJavaScript(
            """
            try {
                const value = window.kaspi.verifyProtectedVaultApprovedSignature(wireHex);
                return { ok: true, value };
            } catch (error) {
                return { ok: false, error: String(error?.message ?? error) };
            }
            """,
            arguments: ["wireHex": wireHex], in: nil, contentWorld: .page
        )
        guard let response = result as? [String: Any] else { throw EngineError.invalidResponse }
        guard response["ok"] as? Bool == true else {
            throw EngineError.javascript(
                response["error"] as? String ?? "The M5 vault signature could not be verified."
            )
        }
        guard response["value"] as? Bool == true else {
            throw EngineError.javascript("The M5 vault signature could not be verified.")
        }
    }

    func broadcastSignedPSKB(
        _ wireHex: String,
        nodeConfiguration: [String: Any]
    ) async throws -> String {
        try await ensureReady()
        let result = try await webView.callAsyncJavaScript(
            """
            try {
                const value = await window.kaspi.broadcastSignedPSKB(wireHex, nodeConfig);
                return { ok: true, value };
            } catch (error) {
                return { ok: false, error: String(error?.message ?? error) };
            }
            """,
            arguments: ["wireHex": wireHex, "nodeConfig": nodeConfiguration],
            in: nil, contentWorld: .page
        )
        guard let response = result as? [String: Any] else { throw EngineError.invalidResponse }
        guard response["ok"] as? Bool == true else {
            throw EngineError.javascript(response["error"] as? String ?? "The node rejected the vault transaction.")
        }
        guard let txid = response["value"] as? String else { throw EngineError.invalidResponse }
        let normalized = txid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 64, normalized.allSatisfy(\.isHexDigit) else {
            throw EngineError.invalidResponse
        }
        return normalized
    }


    func relayPSKBToKSPT(
        _ wireHex: String
    ) async throws -> String {
        try await ensureReady()

        let result = try await webView.callAsyncJavaScript(
            "return window.kaspi.relayPSKBToKSPT(wireHex);",
            arguments: [
                "wireHex": wireHex
            ],
            in: nil,
            contentWorld: .page
        )

        guard let relay = result as? String else {
            throw EngineError.invalidResponse
        }

        let normalized = relay.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !normalized.isEmpty,
              normalized.count.isMultiple(of: 2),
              normalized.allSatisfy({ $0.isHexDigit })
        else {
            throw EngineError.javascript(
                "The compact KSPT relay was not valid hexadecimal."
            )
        }

        return normalized.lowercased()
    }


    func mergeSignedKSPTIntoPSKB(
        signedKSPTHex: String,
        originalPSKBHex: String
    ) async throws -> String {
        try await ensureReady()

        let result = try await webView.callAsyncJavaScript(
            """
            try {
                const value = await window.kaspi.mergeSignedKSPTIntoPSKB(
                    signedKSPTHex,
                    originalPSKBHex
                );
                return { ok: true, value };
            } catch (error) {
                return {
                    ok: false,
                    error: error instanceof Error
                        ? `${error.name}: ${error.message}`
                        : String(error)
                };
            }
            """,
            arguments: [
                "signedKSPTHex": signedKSPTHex,
                "originalPSKBHex": originalPSKBHex
            ],
            in: nil,
            contentWorld: .page
        )

        guard let response = result as? [String: Any] else {
            throw EngineError.invalidResponse
        }

        guard response["ok"] as? Bool == true else {
            let detail = response["error"] as? String
                ?? "The M5 response could not be merged."
            throw EngineError.javascript("M5 merge failed: \(detail)")
        }

        guard let merged = response["value"] as? String else {
            throw EngineError.invalidResponse
        }

        return merged
    }

    func verifyAndMergeSignedKSPTIntoPSKB(
        signedKSPTHex: String,
        originalRelayKSPTHex: String,
        originalPSKBHex: String
    ) async throws -> String {
        try await ensureReady()

        let result = try await webView.callAsyncJavaScript(
            """
            return window.kaspi.verifyAndMergeSignedKSPTIntoPSKB(
                signedKSPTHex,
                originalRelayKSPTHex,
                originalPSKBHex
            );
            """,
            arguments: [
                "signedKSPTHex": signedKSPTHex,
                "originalRelayKSPTHex": originalRelayKSPTHex,
                "originalPSKBHex": originalPSKBHex
            ],
            in: nil,
            contentWorld: .page
        )

        guard let responseJSON = result as? String,
              let responseData = responseJSON.data(using: .utf8),
              let response = try JSONSerialization.jsonObject(
                with: responseData
              ) as? [String: Any]
        else {
            throw EngineError.invalidResponse
        }

        if let message = response["error"] as? String {
            throw EngineError.javascript(message)
        }

        guard let merged = response["value"] as? String else {
            throw EngineError.invalidResponse
        }

        let normalized = merged.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty,
              normalized.count.isMultiple(of: 2),
              normalized.allSatisfy({ $0.isHexDigit })
        else {
            throw EngineError.javascript(
                "Verified signed PSKB was not valid hexadecimal."
            )
        }
        return normalized.lowercased()
    }

    func finalizeAndBroadcastPSKB(
        _ wireHex: String,
        wsURL: String
    ) async throws -> String {
        try await ensureReady()

        let result = try await webView.callAsyncJavaScript(
            """
            return window.kaspi.finalizeAndBroadcastPSKB(
                wireHex,
                wsURL
            );
            """,
            arguments: [
                "wireHex": wireHex,
                "wsURL": wsURL
            ],
            in: nil,
            contentWorld: .page
        )

        guard let transactionID = result as? String else {
            throw EngineError.invalidResponse
        }
        return transactionID
    }

    func broadcastSignedKSPT(
        signedKSPTHex: String,
        nodeConfiguration: [String: Any]
    ) async throws -> String {
        try await ensureReady()

        let result = try await webView.callAsyncJavaScript(
            """
            try {
                const value = await window.kaspi.broadcastSignedKSPT(
                    signedKSPTHex,
                    nodeConfig
                );
                return { ok: true, value };
            } catch (error) {
                return {
                    ok: false,
                    error: error instanceof Error
                        ? `${error.name}: ${error.message}`
                        : String(error)
                };
            }
            """,
            arguments: [
                "signedKSPTHex": signedKSPTHex,
                "nodeConfig": nodeConfiguration
            ],
            in: nil,
            contentWorld: .page
        )

        guard let response = result as? [String: Any] else {
            throw EngineError.invalidResponse
        }

        guard response["ok"] as? Bool == true else {
            let detail = response["error"] as? String
                ?? "The Kaspa node rejected the transaction."
            throw EngineError.javascript(detail)
        }

        guard let txid = response["value"] as? String else {
            throw EngineError.invalidResponse
        }

        let normalizedTransactionID = txid
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard normalizedTransactionID.count == 64,
              normalizedTransactionID.allSatisfy(\.isHexDigit)
        else {
            throw NSError(
                domain: "KasSigner",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Broadcast returned an invalid transaction id."
                ]
            )
        }

        return normalizedTransactionID
    }


    func summarizePSKB(_ wireHex: String, network: KaspaNetwork = .mainnet) async throws -> PSKTSummary {
        try await ensureReady()

        let result = try await webView.callAsyncJavaScript(
            "return window.kaspi.summarizePSKB(wireHex, network);",
            arguments: [
                "wireHex": wireHex,
                "network": network.rawValue
            ],
            in: nil,
            contentWorld: .page
        )

        guard let json = result as? String,
              let data = json.data(using: .utf8)
        else {
            throw EngineError.invalidResponse
        }

        do {
            return try JSONDecoder().decode(PSKTSummary.self, from: data)
        } catch {
            throw EngineError.javascript(
                "Unable to decode PSKB summary: \(error.localizedDescription)"
            )
        }
    }

    func verifyStandardPSKBSignatures(_ wireHex: String) async throws {
        try await ensureReady()
        let result = try await webView.callAsyncJavaScript(
            """
            try {
                const value = await window.kaspi.verifyStandardPSKBSignatures(
                    wireHex
                );
                return { ok: true, value };
            } catch (error) {
                return {
                    ok: false,
                    error: error instanceof Error
                        ? `${error.name}: ${error.message}`
                        : String(error)
                };
            }
            """,
            arguments: ["wireHex": wireHex],
            in: nil,
            contentWorld: .page
        )

        guard let response = result as? [String: Any] else {
            throw EngineError.invalidResponse
        }

        guard response["ok"] as? Bool == true else {
            let detail = response["error"] as? String
                ?? "The returned M5 signatures could not be checked."
            throw EngineError.javascript(
                "M5 signature verification failed: \(detail)"
            )
        }

        guard response["value"] as? Bool == true else {
            throw EngineError.javascript("The returned M5 signatures are invalid.")
        }
    }

    func signTestnet10FundingPSKB(_ wireHex: String, mnemonic: String) async throws -> String {
        try await ensureReady()
        let result = try await webView.callAsyncJavaScript(
            "return window.kaspi.signTestnet10FundingPSKB(wireHex, mnemonic);",
            arguments: ["wireHex": wireHex, "mnemonic": mnemonic],
            in: nil,
            contentWorld: .page
        )
        guard let signed = result as? String, !signed.isEmpty else {
            throw EngineError.invalidResponse
        }
        return signed
    }

    func finalizeSignedPSKB(_ wireHex: String) async throws -> String {
        try await ensureReady()
        let result = try await webView.callAsyncJavaScript(
            """
            try {
                const value = await window.kaspi.finalizeSignedPSKB(wireHex);
                return { ok: true, value };
            } catch (error) {
                return {
                    ok: false,
                    error: error instanceof Error
                        ? `${error.name}: ${error.message}`
                        : String(error)
                };
            }
            """,
            arguments: ["wireHex": wireHex],
            in: nil,
            contentWorld: .page
        )

        guard let response = result as? [String: Any] else {
            throw EngineError.invalidResponse
        }

        guard response["ok"] as? Bool == true else {
            let detail = response["error"] as? String
                ?? "The signed transaction could not be finalized."
            throw EngineError.javascript(
                "Signed transaction finalization failed: \(detail)"
            )
        }

        guard let finalized = response["value"] as? String,
              !finalized.isEmpty,
              finalized.count.isMultiple(of: 2),
              finalized.allSatisfy(\.isHexDigit)
        else {
            throw EngineError.invalidResponse
        }
        return finalized.lowercased()
    }


    func generateQRFrames(
        from verifiedPSKB: String
    ) async throws -> [KasSeeQRFrame] {
        try await ensureReady()

        let result = try await webView.callAsyncJavaScript(
            "return window.kaspi.generateQRFrames(pskb);",
            arguments: [
                "pskb": verifiedPSKB
            ],
            in: nil,
            contentWorld: .page
        )

        guard let json = result as? String,
              let data = json.data(using: .utf8)
        else {
            throw EngineError.javascript(
                "QR encoder did not return frame JSON."
            )
        }

        do {
            let frames = try JSONDecoder().decode(
                [KasSeeQRFrame].self,
                from: data
            )

            guard !frames.isEmpty,
                  frames.allSatisfy({
                      !$0.svg.isEmpty
                          && $0.frameNumber >= 0
                          && $0.totalFrames == frames.count
                  })
            else {
                throw EngineError.javascript(
                    "QR encoder returned invalid frames."
                )
            }

            return frames.sorted {
                $0.frameNumber < $1.frameNumber
            }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.javascript(
                "QR frame JSON could not be decoded: "
                    + error.localizedDescription
            )
        }
    }
    private func deeplyUnwrapOptional(_ value: Any) -> Any? {
        var current: Any = value

        while true {
            let mirror = Mirror(reflecting: current)

            guard mirror.displayStyle == .optional else {
                return current
            }

            guard let wrappedValue = mirror.children.first?.value else {
                return nil
            }

            current = wrappedValue
        }
    }



    private struct QRFrameDecodeResult: Decodable {
        let complete: Bool
        let payload: String?
        let jsError: String?
    }

    func decodeQRFrame(
        _ frame: String
    ) async throws -> String? {
        try await ensureReady()

        let result = try await webView.callAsyncJavaScript(
            "return window.kaspi.decodeQRFrame(frame);",
            arguments: [
                "frame": frame
            ],
            in: nil,
            contentWorld: .page
        )

        guard let result,
              let unwrapped = deeplyUnwrapOptional(result),
              let json = unwrapped as? String,
              let data = json.data(using: .utf8)
        else {
            throw EngineError.invalidResponse
        }

        let decoded: QRFrameDecodeResult

        do {
            decoded = try JSONDecoder().decode(
                QRFrameDecodeResult.self,
                from: data
            )
        } catch {
            throw EngineError.javascript(
                "QR decoder response could not be decoded: "
                    + error.localizedDescription
            )
        }

        if let jsError = decoded.jsError,
           !jsError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw EngineError.javascript(jsError)
        }

        guard decoded.complete,
              let payload = decoded.payload?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !payload.isEmpty
        else {
            return nil
        }

        return payload
    }

    func decoderProgress() async throws -> QRDecoderProgress {
        try await ensureReady()

        let result = try await webView.callAsyncJavaScript(
            "return JSON.stringify(window.kaspi.decoderProgress());",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )

        guard let result,
              let unwrapped = deeplyUnwrapOptional(result),
              let json = unwrapped as? String,
              let data = json.data(using: .utf8)
        else {
            throw EngineError.invalidResponse
        }

        do {
            return try JSONDecoder().decode(
                QRDecoderProgress.self,
                from: data
            )
        } catch {
            throw EngineError.javascript(
                "QR decoder progress could not be decoded: "
                    + error.localizedDescription
            )
        }
    }

    func resetQRDecoder() async throws {
        try await ensureReady()

        _ = try await webView.callAsyncJavaScript(
            "window.kaspi.resetQRDecoder();",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
    }

    func syncWallet(
        _ profile: WalletProfile,
        nodeConfiguration: [String: Any]
    ) async throws -> WalletSyncPayload {
        try await ensureReady()

        let wallet: [String: Any] = [
            "kpub": profile.kpub,
            "receive_addresses": profile.receiveAddresses,
            "change_addresses": profile.changeAddresses,
            "next_receive_index": profile.nextReceiveIndex,
            "next_change_index": profile.nextChangeIndex
        ]

        let result = try await webView.callAsyncJavaScript(
            "return await window.kaspi.syncWallet(wallet, nodeConfig);",
            arguments: [
                "wallet": wallet,
                "nodeConfig": nodeConfiguration
            ],
            in: nil,
            contentWorld: .page
        )

        guard let json = result as? String,
              let data = json.data(using: .utf8)
        else { throw EngineError.invalidResponse }

        do {
            return try JSONDecoder().decode(WalletSyncPayload.self, from: data)
        } catch {
            throw EngineError.javascript("KasSigner sync response could not be decoded: \(error.localizedDescription)")
        }
    }

    func syncAddress(
        _ address: String,
        nodeConfiguration: [String: Any]
    ) async throws -> WalletSyncPayload {
        try await ensureReady()

        let wallet: [String: Any] = [
            "kpub": "",
            "receive_addresses": [address],
            "change_addresses": [],
            "next_receive_index": 0,
            "next_change_index": 0
        ]
        let result = try await webView.callAsyncJavaScript(
            "return await window.kaspi.syncWallet(wallet, nodeConfig);",
            arguments: ["wallet": wallet, "nodeConfig": nodeConfiguration],
            in: nil,
            contentWorld: .page
        )

        guard let json = result as? String,
              let data = json.data(using: .utf8)
        else { throw EngineError.invalidResponse }

        do {
            return try JSONDecoder().decode(WalletSyncPayload.self, from: data)
        } catch {
            throw EngineError.javascript(
                "Vault balance response could not be decoded: \(error.localizedDescription)"
            )
        }
    }

    func extendAddresses(
        for profile: WalletProfile,
        receiveCount: Int = 20,
        changeCount: Int = 20
    ) async throws -> WalletImportResult {
        try await ensureReady()

        let wallet: [String: Any] = [
            "kpub": profile.kpub,
            "receive_addresses": profile.receiveAddresses,
            "change_addresses": profile.changeAddresses,
            "next_receive_index": profile.nextReceiveIndex,
            "next_change_index": profile.nextChangeIndex
        ]

        let result = try await webView.callAsyncJavaScript(
            "return window.kaspi.extendAddresses(wallet, receiveCount, changeCount);",
            arguments: [
                "wallet": wallet,
                "receiveCount": receiveCount,
                "changeCount": changeCount
            ],
            in: nil,
            contentWorld: .page
        )

        guard let json = result as? String,
              let data = json.data(using: .utf8)
        else { throw EngineError.invalidResponse }

        do {
            let derived = try JSONDecoder().decode(WalletImportResult.self, from: data)
            try validateExtendedAddresses(
                derived,
                original: profile,
                receiveCount: receiveCount,
                changeCount: changeCount
            )
            return derived
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.javascript("KasSigner address derivation failed: \(error.localizedDescription)")
        }
    }

    private func ensureReady(timeoutSeconds: Double = 20) async throws {
        if isReady { return }

        startIfNeeded()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !isReady && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        guard isReady else { throw EngineError.notReady }
    }

    private func validateExtendedAddresses(
        _ derived: WalletImportResult,
        original: WalletProfile,
        receiveCount: Int,
        changeCount: Int
    ) throws {
        let expectedPrefix = original.network == KaspaNetwork.testnet10.rawValue
            ? "kaspatest:" : "kaspa:"
        guard derived.kpub == original.kpub else {
            throw EngineError.javascript("Derived wallet kpub did not match the selected account.")
        }
        guard derived.receiveAddresses.count == original.receiveAddresses.count + receiveCount,
              derived.changeAddresses.count == original.changeAddresses.count + changeCount
        else {
            throw EngineError.javascript("Derived address counts were not sequential.")
        }
        guard derived.receiveAddresses.starts(with: original.receiveAddresses),
              derived.changeAddresses.starts(with: original.changeAddresses)
        else {
            throw EngineError.javascript("Existing derived addresses changed unexpectedly.")
        }
        guard Set(derived.receiveAddresses).count == derived.receiveAddresses.count,
              Set(derived.changeAddresses).count == derived.changeAddresses.count,
              Set(derived.receiveAddresses).isDisjoint(with: Set(derived.changeAddresses)),
              derived.receiveAddresses.allSatisfy({ $0.hasPrefix(expectedPrefix) }),
              derived.changeAddresses.allSatisfy({ $0.hasPrefix(expectedPrefix) })
        else {
            throw EngineError.javascript("Derived addresses failed uniqueness or network validation.")
        }
    }

    private func loadEngine() {
        guard Bundle.main.url(
            forResource: "bridge",
            withExtension: "html",
            subdirectory: "Web"
        ) != nil else {
            statusText = "KasSigner resources missing"
            return
        }

        guard let url = URL(
            string:
                "\(KasSignerSchemeHandler.scheme)://engine/bridge.html"
                + "?load=\(bridgeLoadToken)"
        ) else {
            statusText = "KasSigner startup URL invalid"
            return
        }

        guard webView.url == nil, !webView.isLoading else { return }
        webView.load(
            URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData
            )
        )
    }
}

extension KasSignerEngine: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        isReady = false
        statusText = "KasSigner load failed: \(error.localizedDescription)"
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        isReady = false
        statusText = "KasSigner startup failed: \(error.localizedDescription)"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        statusText = "Restarting KasSigner…"
        webView.reload()
    }
}

extension KasSignerEngine: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard
            message.name == "kaspi",
            let body = message.body as? [String: Any],
            let event = body["event"] as? String
        else {
            return
        }

        switch event {
        case "ready":
            isReady = true
            statusText = "KasSigner"
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.setRuntimeActive(self.desiredRuntimeActive)
            }

        case "status":
            if let text = body["message"] as? String {
                statusText = text
            }

        case "error":
            isReady = false
            statusText = (body["message"] as? String)
                ?? "KasSigner failed to start"

        case "rpc_notifications":
            rpcNotificationVersion += 1

        default:
            break
        }
    }
}

private final class KasSignerSchemeHandler:
    NSObject,
    WKURLSchemeHandler,
    @unchecked Sendable
{
    static let scheme = "kassigner"

    func webView(
        _ webView: WKWebView,
        start urlSchemeTask: WKURLSchemeTask
    ) {
        guard
            let requestURL = urlSchemeTask.request.url,
            requestURL.scheme == Self.scheme,
            requestURL.host == "engine"
        else {
            fail(
                urlSchemeTask,
                code: .badURL,
                message: "Invalid KasSigner resource URL."
            )
            return
        }

        let relativePath = requestURL.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard
            !relativePath.isEmpty,
            !relativePath.contains(".."),
            let resourceRoot = Bundle.main.resourceURL?
                .appendingPathComponent("Web", isDirectory: true)
        else {
            fail(
                urlSchemeTask,
                code: .fileDoesNotExist,
                message: "KasSigner resource path is invalid."
            )
            return
        }

        let fileURL = resourceRoot.appendingPathComponent(relativePath)

        guard
            fileURL.standardizedFileURL.path.hasPrefix(
                resourceRoot.standardizedFileURL.path
            ),
            FileManager.default.fileExists(atPath: fileURL.path)
        else {
            fail(
                urlSchemeTask,
                code: .fileDoesNotExist,
                message: "KasSigner resource was not found: \(relativePath)"
            )
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)

            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType(for: fileURL.pathExtension),
                expectedContentLength: data.count,
                textEncodingName: isText(fileURL.pathExtension)
                    ? "utf-8"
                    : nil
            )

            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(
        _ webView: WKWebView,
        stop urlSchemeTask: WKURLSchemeTask
    ) {}

    private func fail(
        _ task: WKURLSchemeTask,
        code: URLError.Code,
        message: String
    ) {
        task.didFailWithError(
            NSError(
                domain: NSURLErrorDomain,
                code: code.rawValue,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        )
    }

    private func mimeType(for extensionName: String) -> String {
        switch extensionName.lowercased() {
        case "html":
            return "text/html"
        case "js":
            return "text/javascript"
        case "wasm":
            return "application/wasm"
        case "json":
            return "application/json"
        case "css":
            return "text/css"
        default:
            return "application/octet-stream"
        }
    }

    private func isText(_ extensionName: String) -> Bool {
        ["html", "js", "json", "css"].contains(
            extensionName.lowercased()
        )
    }
}
