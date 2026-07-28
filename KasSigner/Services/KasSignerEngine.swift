import Foundation
@preconcurrency import WebKit

struct AddressValidationResult: Codable {
    let valid: Bool
    let network: String?
    let normalized: String?
    let reason: String?
}

struct FeeEstimate: Decodable, Equatable {
    let lowSompiPerGram: UInt64
    let normalSompiPerGram: UInt64
    let prioritySompiPerGram: UInt64
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

struct SendDraftInput: Encodable, Hashable {
    let transactionID: String
    let index: UInt32
    let amountSompi: UInt64
    let scriptPublicKey: String
    let blockDAAScore: UInt64

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

        self.transactionID = transactionID.lowercased()
        self.index = utxo.index
        self.amountSompi = utxo.amount
        self.scriptPublicKey = scriptPublicKey.lowercased()
        self.blockDAAScore = utxo.blockDAAScore
    }

    private enum CodingKeys: String, CodingKey {
        case transactionID = "tx_id"
        case index
        case amountSompi = "amount"
        case scriptPublicKey = "script_public_key"
        case blockDAAScore = "block_daa_score"
    }

    var outpointKey: String {
        "\(transactionID):\(index)"
    }
}

struct SendDraft {
    let profile: WalletProfile
    let selectedInputs: [SendDraftInput]
    let destination: String
    let amountSompi: UInt64
    let feeSompi: UInt64
    let selectedTotalSompi: UInt64

    init(
        profile: WalletProfile,
        selectedUTXOs: [WalletUTXO],
        destination: String,
        amountSompi: UInt64,
        feeSompi: UInt64
    ) throws {
        let destination = destination.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !destination.isEmpty else {
            throw SendDraftError.emptyDestination
        }

        guard amountSompi > 0 else {
            throw SendDraftError.zeroAmount
        }

        guard !selectedUTXOs.isEmpty else {
            throw SendDraftError.noSelectedInputs
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

        let required = amountSompi.addingReportingOverflow(feeSompi)

        guard !required.overflow else {
            throw SendDraftError.requiredTotalOverflow
        }

        guard required.partialValue <= selectedTotalSompi else {
            throw SendDraftError.insufficientSelectedInputs
        }

        self.profile = profile
        self.selectedInputs = selectedInputs
        self.destination = destination
        self.amountSompi = amountSompi
        self.feeSompi = feeSompi
        self.selectedTotalSompi = selectedTotalSompi
    }
}

enum SendDraftError: LocalizedError {
    case emptyDestination
    case zeroAmount
    case noSelectedInputs
    case invalidTransactionID
    case invalidScriptPublicKey
    case zeroValueInput
    case duplicateOutpoint
    case inputTotalOverflow
    case requiredTotalOverflow
    case insufficientSelectedInputs

    var errorDescription: String? {
        switch self {
        case .emptyDestination:
            return "The destination address is empty."
        case .zeroAmount:
            return "The send amount must be greater than zero."
        case .noSelectedInputs:
            return "No UTXOs were selected."
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
        }
    }
}



struct PSKTSummary: Decodable {
    let totalInputSompi: UInt64?
    let totalOutputSompi: UInt64?
    let feeSompi: UInt64?
    let inputCount: Int?
    let outputCount: Int?
    let inputs: [PSKTSummaryInput]?
    let outputs: [PSKTSummaryOutput]?

    private enum CodingKeys: String, CodingKey {
        case totalInputSompi = "total_in_sompi"
        case totalOutputSompi = "total_out_sompi"
        case feeSompi = "fee_sompi"
        case inputCount = "input_count"
        case outputCount = "output_count"
        case inputs
        case outputs
    }
}

struct PSKTSummaryInput: Decodable {
    let txID: String?
    let index: UInt32?

    private enum CodingKeys: String, CodingKey {
        case txID = "prev_tx_id"
        case index = "prev_index"
    }
}

struct PSKTSummaryOutput: Decodable {
    let address: String?
    let amountSompi: UInt64?

    private enum CodingKeys: String, CodingKey {
        case address
        case amountSompi = "amount_sompi"
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

    @Published var rpcNotifications: [String] = []
    @Published var rpcNotificationVersion = 0

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
    private var hasStarted = false

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        // The engine contains no private keys. Using the default store allows
        // WebKit to cache the local WASM module instead of recompiling it on
        // every launch.
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(self, name: "kaspi")
        configuration.setURLSchemeHandler(
            schemeHandler,
            forURLScheme: KasSignerSchemeHandler.scheme
        )

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        if #available(iOS 16.4, *) {
            view.isInspectable = true
        }
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

    func importKpub(_ kpub: String) async throws -> WalletImportResult {
        try await ensureReady()

        let payload = try JSONSerialization.data(
            withJSONObject: ["kpub": kpub]
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


    func buildUnsignedPSKB(
        from draft: SendDraft,
        nodeConfiguration: [String: Any]
    ) async throws -> String {
        try await ensureReady()

        let wallet: [String: Any] = [
            "kpub": draft.profile.kpub,
            "receive_addresses": draft.profile.receiveAddresses,
            "change_addresses": draft.profile.changeAddresses
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

        let result = try await webView.callAsyncJavaScript(
            """
            return await window.kaspi.buildUnsignedPSKB(
                wallet,
                destination,
                amountSompi,
                feeSompi,
                utxosJSON,
                nodeConfig
            );
            """,
            arguments: [
                "wallet": wallet,
                "destination": draft.destination,
                "amountSompi": String(draft.amountSompi),
                "feeSompi": String(draft.feeSompi),
                "utxosJSON": utxosJSON,
                "nodeConfig": nodeConfiguration
            ],
            in: nil,
            contentWorld: .page
        )

        guard let pskb = result as? String else {
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
            "return window.kaspi.mergeSignedKSPTIntoPSKB(signedKSPTHex, originalPSKBHex);",
            arguments: [
                "signedKSPTHex": signedKSPTHex,
                "originalPSKBHex": originalPSKBHex
            ],
            in: nil,
            contentWorld: .page
        )

        guard let merged = result as? String else {
            throw EngineError.invalidResponse
        }

        return merged
    }

    func broadcastSignedKSPT(
        signedKSPTHex: String,
        wsURL: String
    ) async throws -> String {
        try await ensureReady()

        let result = try await webView.callAsyncJavaScript(
            """
            return window.kaspi.broadcastSignedKSPT(
                signedKSPTHex,
                wsURL
            );
            """,
            arguments: [
                "signedKSPTHex": signedKSPTHex,
                "wsURL": wsURL
            ],
            in: nil,
            contentWorld: .page
        )

        guard let txid = result as? String else {
            throw NSError(
                domain: "KasSigner",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Broadcast returned an invalid transaction id."
                ]
            )
        }

        return txid
    }


    func summarizePSKB(_ wireHex: String) async throws -> PSKTSummary {
        try await ensureReady()

        let result = try await webView.callAsyncJavaScript(
            "return window.kaspi.summarizePSKB(wireHex);",
            arguments: [
                "wireHex": wireHex
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
            "change_addresses": profile.changeAddresses
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

    func extendAddresses(
        for profile: WalletProfile,
        receiveCount: Int = 20,
        changeCount: Int = 20
    ) async throws -> WalletImportResult {
        try await ensureReady()

        let wallet: [String: Any] = [
            "kpub": profile.kpub,
            "receive_addresses": profile.receiveAddresses,
            "change_addresses": profile.changeAddresses
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
              derived.receiveAddresses.allSatisfy({ $0.hasPrefix("kaspa:") }),
              derived.changeAddresses.allSatisfy({ $0.hasPrefix("kaspa:") })
        else {
            throw EngineError.javascript("Derived addresses failed uniqueness or mainnet validation.")
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
            string: "\(KasSignerSchemeHandler.scheme)://engine/bridge.html"
        ) else {
            statusText = "KasSigner startup URL invalid"
            return
        }

        guard webView.url == nil, !webView.isLoading else { return }
        webView.load(URLRequest(url: url))
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

        case "status":
            if let text = body["message"] as? String {
                statusText = text
            }

        case "error":
            isReady = false
            statusText = (body["message"] as? String)
                ?? "KasSigner failed to start"

        case "rpc_notifications":
            rpcNotifications =
                body["notifications"] as? [String] ?? []
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
