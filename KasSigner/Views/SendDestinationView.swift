import SwiftUI
import UIKit
import WebKit
import CryptoKit
import Combine

struct SendDestinationView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: WalletProfile
    let selectedUTXOs: [WalletUTXO]
    @Binding var showingSendFlow: Bool

    @State private var destinationAddress = ""
    @State private var amountText = ""
    @State private var sendMax = false
    @State private var selectedFee: SendFeeChoice = .normal
    @State private var customFeeText = ""
    @State private var showingScanner = false
    @State private var unsignedPSKB: String?
    @State private var showingBuildError = false
    @State private var buildErrorMessage = ""
    @State private var isBuildingPSKB = false
    @State private var verifiedReview: VerifiedTransactionReview?

    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var walletStore: WalletStore
    @State private var addressValidation: AddressValidationResult?
    @State private var isValidatingAddress = false
    @State private var addressValidationTask: Task<Void, Never>?

    private let accentColor = Color(red: 0.20, green: 0.62, blue: 0.57)

    private var enteredAmountSompi: UInt64? {
        parseKasTextToSompi(amountText)
    }

    private var destinationLooksValid: Bool {
        addressValidation?.valid == true
    }

    private var addressValidationMessage: String? {
        guard !destinationAddress.isEmpty else { return nil }

        if isValidatingAddress {
            return "Validating mainnet address..."
        }

        if destinationLooksValid {
            return "Valid Kaspa address."
        }

        return addressValidation?.reason
            ?? "Invalid Kaspa address."
    }

    private var selectedTotalSompi: UInt64? {
        selectedUTXOs.reduce(into: UInt64?.some(0)) { total, utxo in
            guard let current = total else { return }
            let addition = current.addingReportingOverflow(utxo.amount)
            total = addition.overflow ? nil : addition.partialValue
        }
    }

    private var amountLooksValid: Bool {
        guard let amount = enteredAmountSompi,
              let selectedTotalSompi,
              let requestedFeeSompi
        else {
            return false
        }

        let required = amount.addingReportingOverflow(requestedFeeSompi)
        return amount > 0
            && !required.overflow
            && required.partialValue <= selectedTotalSompi
    }

    private var selectedFeeRateSompiPerGram: Double? {
        guard let fee = syncService.feeEstimate else {
            return nil
        }

        switch selectedFee {
        case .low:
            return fee.lowSompiPerGram

        case .normal:
            return fee.normalSompiPerGram

        case .priority:
            return fee.prioritySompiPerGram

        case .custom:
            return nil
        }
    }

    private var liveFeeDescription: String {
        if selectedFee == .custom {
            return "Enter an exact fee in KAS."
        }

        guard let fee = syncService.feeEstimate,
              let requestedFeeSompi
        else {
            return "Connecting to node for live fee estimate..."
        }

        let feeAmount = formatKas(sompi: requestedFeeSompi)

        switch selectedFee {
        case .low:
            return "Low • \(feeAmount) • \(formatFeeRate(fee.lowSompiPerGram)) sompi/gram"

        case .normal:
            return "Normal • \(feeAmount) • \(formatFeeRate(fee.normalSompiPerGram)) sompi/gram"

        case .priority:
            return "Priority • \(feeAmount) • \(formatFeeRate(fee.prioritySompiPerGram)) sompi/gram"

        case .custom:
            return ""
        }
    }

    private var customFeeSompi: UInt64? {
        parseKasTextToSompi(customFeeText)
    }

    private var requestedFeeSompi: UInt64? {
        switch selectedFee {
        case .custom:
            guard let customFeeSompi, customFeeSompi > 0 else {
                return nil
            }
            return customFeeSompi

        case .low, .normal, .priority:
            guard let fee = syncService.feeEstimate,
                  fee.normalSompiPerGram > 0,
                  let selectedRate = selectedFeeRateSompiPerGram
            else {
                return nil
            }

            // The node's suggested fee is its normal-rate quote. Recover the
            // quoted transaction mass with ceiling division, then apply the
            // user's selected node-provided rate to that same mass.
            let quotedMass = ceil(
                Double(fee.suggestedFee) / fee.normalSompiPerGram
            )
            let selectedFee = quotedMass * selectedRate
            guard selectedFee.isFinite,
                  selectedFee > 0,
                  selectedFee <= Double(UInt64.max)
            else {
                return nil
            }
            return UInt64(selectedFee)
        }
    }

    private var maximumSendSompi: UInt64? {
        guard let selectedTotalSompi,
              let requestedFeeSompi
        else {
            return nil
        }

        let maximum = selectedTotalSompi.subtractingReportingOverflow(
            requestedFeeSompi
        )
        guard !maximum.overflow, maximum.partialValue > 0 else {
            return nil
        }
        return maximum.partialValue
    }

    private var feeLooksValid: Bool {
        guard selectedFee == .custom else { return true }
        guard let fee = customFeeSompi else { return false }
        return fee > 0
    }

    private var canContinue: Bool {
        destinationLooksValid
            && amountLooksValid
            && feeLooksValid
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    destinationCard
                    amountCard
                    feeCard
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))

            Button {
                Task {
                    await buildFirstVerifiedPSKB()
                }
            } label: {
                if isBuildingPSKB {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue || isBuildingPSKB)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .navigationTitle("Destination & Amount")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .onDisappear {
            addressValidationTask?.cancel()
        }
        .onChange(of: selectedFee) { _, _ in
            updateSendMaxAmount()
        }
        .onChange(of: customFeeText) { _, _ in
            updateSendMaxAmount()
        }
        .onChange(of: syncService.feeEstimate) { _, _ in
            updateSendMaxAmount()
        }
        .sheet(isPresented: $showingScanner) {
            QRScannerView { scannedValue in
                let scanned = normalizedAddress(from: scannedValue)
                destinationAddress = scanned
                validateDestinationAddress(scanned)
                showingScanner = false
            }
        }
        .alert("Transaction could not be built", isPresented: $showingBuildError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(buildErrorMessage)
        }
        .navigationDestination(item: $verifiedReview) { review in
            VerifiedTransactionReviewView(
                review: review,
                onComplete: {
                    verifiedReview = nil
                    showingSendFlow = false
                }
            )
        }
    }

    @MainActor
    private func buildFirstVerifiedPSKB() async {
        guard !isBuildingPSKB else { return }

        guard let requestedFeeSompi else {
            showBuildError(
                selectedFee == .custom
                    ? "Enter a valid custom fee."
                    : "A live fee estimate is not available yet."
            )
            return
        }

        let amountSompi: UInt64

        if sendMax {
            guard let selectedTotalSompi else {
                showBuildError("The selected UTXO total is invalid.")
                return
            }

            let maximum = selectedTotalSompi.subtractingReportingOverflow(
                requestedFeeSompi
            )
            guard !maximum.overflow, maximum.partialValue > 0 else {
                showBuildError("The selected UTXOs cannot cover this fee.")
                return
            }

            // Recompute at submission time so a stale text-field value can
            // never send the full input total without deducting the fee.
            amountSompi = maximum.partialValue
            amountText = formatPlainKas(sompi: amountSompi)
        } else {
            guard let enteredAmountSompi else {
                showBuildError("Enter a valid amount.")
                return
            }
            amountSompi = enteredAmountSompi
        }

        isBuildingPSKB = true
        defer { isBuildingPSKB = false }

        do {
            guard let activeProfile = walletStore.profiles.first(
                where: { $0.id == profile.id }
            ) else {
                throw SendVerificationError.walletStateChanged
            }

            // Provisional runtime checkpoint only. Final fee selection will use
            // the exact verified transaction mass.
            let draft = try SendDraft(
                profile: activeProfile,
                selectedUTXOs: selectedUTXOs,
                destination: destinationAddress,
                amountSompi: amountSompi,
                feeSompi: requestedFeeSompi,
                feeRateSompiPerGram: selectedFeeRateSompiPerGram ?? 0,
                usesExactFee: selectedFee == .custom,
                sendMax: sendMax
            )

            let pskb = try await engine.buildUnsignedPSKB(
                from: draft,
                nodeConfiguration: preferences.nodeConfiguration
            )

            let summary = try await engine.summarizePSKB(pskb)

            guard let builtInputs = summary.inputs,
                  builtInputs.count == draft.selectedInputs.count
            else {
                throw SendVerificationError.inputCountMismatch
            }

            let selectedOutpoints = Set(
                draft.selectedInputs.map { $0.outpointKey.lowercased() }
            )

            let builtOutpoints = Set(
                try builtInputs.map { input -> String in
                    guard let txID = input.txID?.lowercased(),
                          let index = input.index
                    else {
                        throw SendVerificationError.missingInputOutpoint
                    }

                    return "\(txID):\(index)"
                }
            )

            guard builtOutpoints == selectedOutpoints else {
                throw SendVerificationError.inputOutpointMismatch
            }

            guard let outputs = summary.outputs,
                  !outputs.isEmpty
            else {
                throw SendVerificationError.missingOutputs
            }

            let normalizedDestination = destinationAddress
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                .lowercased()

            let destinationOutputs = outputs.filter { output in
                output.address?
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    .lowercased() == normalizedDestination
            }

            guard destinationOutputs.count == 1,
                  let builtDestinationAmount = destinationOutputs.first?.amountSompi,
                  builtDestinationAmount > 0,
                  sendMax || builtDestinationAmount == amountSompi
            else {
                throw SendVerificationError.destinationMismatch
            }
            let verifiedAmountSompi = sendMax
                ? builtDestinationAmount
                : amountSompi

            let ownedChangeAddresses = Set(
                activeProfile.changeAddresses.map {
                    $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        .lowercased()
                }
            )

            for output in outputs {
                guard let address = output.address?
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    .lowercased(),
                      let outputAmount = output.amountSompi
                else {
                    throw SendVerificationError.invalidOutput
                }

                let isDestination =
                    address == normalizedDestination
                    && outputAmount == verifiedAmountSompi

                let isWalletChange = ownedChangeAddresses.contains(address)

                guard isDestination || isWalletChange else {
                    throw SendVerificationError.unknownOutput
                }
            }

            guard let totalInput = summary.totalInputSompi,
                  let totalOutput = summary.totalOutputSompi,
                  let reportedFee = summary.feeSompi,
                  totalInput >= totalOutput,
                  totalInput - totalOutput == reportedFee
            else {
                throw SendVerificationError.invalidFeeArithmetic
            }

            if selectedFee == .custom,
               reportedFee != requestedFeeSompi {
                throw SendVerificationError.customFeeMismatch
            }

            let afterAmount = totalInput.subtractingReportingOverflow(
                verifiedAmountSompi
            )
            guard !afterAmount.overflow else {
                throw SendVerificationError.invalidFeeArithmetic
            }

            let afterFee = afterAmount.partialValue.subtractingReportingOverflow(
                reportedFee
            )
            guard !afterFee.overflow else {
                throw SendVerificationError.invalidFeeArithmetic
            }
            let verifiedChangeSompi = afterFee.partialValue

            if verifiedChangeSompi > 0 {
                guard activeProfile.changeAddresses.indices.contains(
                    activeProfile.nextChangeIndex
                ) else {
                    throw SendVerificationError.changeAddressUnavailable
                }

                let expectedChangeAddress = activeProfile.changeAddresses[
                    activeProfile.nextChangeIndex
                ]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                let matchingChangeOutputs = outputs.filter {
                    $0.address?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == expectedChangeAddress
                        && $0.amountSompi == verifiedChangeSompi
                }

                guard matchingChangeOutputs.count == 1 else {
                    throw SendVerificationError.changeAddressMismatch
                }

                guard walletStore.reserveChangeAddress(
                    profileID: activeProfile.id,
                    index: activeProfile.nextChangeIndex
                ) else {
                    throw SendVerificationError.walletStateChanged
                }
            }

            unsignedPSKB = pskb
            verifiedReview = VerifiedTransactionReview(
                profileID: activeProfile.id,
                destination: normalizedDestination,
                amountSompi: verifiedAmountSompi,
                feeSompi: reportedFee,
                changeSompi: verifiedChangeSompi,
                selectedInputCount: builtInputs.count,
                selectedOutpoints: draft.selectedInputs.map { $0.outpointKey },
                unsignedPSKB: pskb,
                verifiedDigest: SHA256.hash(
                    data: Data(pskb.utf8)
                ).map {
                    String(format: "%02x", $0)
                }.joined(),
                selectedInputsVerified: true,
                destinationVerified: true,
                changeVerified: true,
                feeVerified: true
            )
        } catch {
            showBuildError(error.localizedDescription)
        }
    }

    @MainActor
    private func showBuildError(_ message: String) {
        buildErrorMessage = message
        showingBuildError = true
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Destination")
                    .font(.headline)

                Spacer()

                if isValidatingAddress {
                    ProgressView()
                        .controlSize(.small)
                } else if !destinationAddress.isEmpty {
                    Image(
                        systemName: destinationLooksValid
                            ? "checkmark.circle.fill"
                            : "xmark.circle.fill"
                    )
                    .foregroundStyle(
                        destinationLooksValid ? accentColor : .red
                    )
                }
            }

            TextField(
                "kaspa:...",
                text: $destinationAddress,
                axis: .vertical
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.subheadline, design: .monospaced))
            .lineLimit(2...4)
            .padding(12)
            .background(
                Color(.tertiarySystemGroupedBackground),
                in: RoundedRectangle(
                    cornerRadius: 12,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: 12,
                    style: .continuous
                )
                .stroke(
                    destinationAddress.isEmpty
                        ? Color.primary.opacity(0.06)
                        : destinationLooksValid
                            ? accentColor.opacity(0.75)
                            : Color.red.opacity(0.65),
                    lineWidth: 1
                )
            }
            .onChange(of: destinationAddress) { _, newValue in
                let normalized = normalizedAddress(from: newValue)

                if normalized != destinationAddress {
                    destinationAddress = normalized
                    return
                }

                validateDestinationAddress(normalized)
            }

            HStack(spacing: 10) {
                Button {
                    let pasted = normalizedAddress(
                        from: UIPasteboard.general.string ?? ""
                    )
                    destinationAddress = pasted
                    validateDestinationAddress(pasted)
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                }
                .buttonStyle(.bordered)

                Button {
                    showingScanner = true
                } label: {
                    Label("Scan QR", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                }
                .buttonStyle(.bordered)
            }

            if let message = addressValidationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(
                        isValidatingAddress
                            ? .secondary
                            : destinationLooksValid
                                ? accentColor
                                : .red
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(
                cornerRadius: 15,
                style: .continuous
            )
        )
    }

    private var amountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Amount")
                    .font(.headline)

                Spacer()

                Text(selectedTotalText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                TextField("0", text: $amountText)
                    .keyboardType(.decimalPad)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .disabled(sendMax)

                Text("KAS")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(
                Color(.tertiarySystemGroupedBackground),
                in: RoundedRectangle(
                    cornerRadius: 12,
                    style: .continuous
                )
            )

            Toggle("Send Max", isOn: $sendMax)
                .font(.subheadline.weight(.semibold))
                .tint(accentColor)
                .onChange(of: sendMax) { _, enabled in
                    if enabled {
                        if requestedFeeSompi == nil {
                            amountText = ""
                            Task {
                                await refreshFeeEstimateForSendMax()
                            }
                        }
                        updateSendMaxAmount()
                    }
                }
                .disabled(selectedTotalSompi == nil)

            HStack {
                Text("Selected input")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(selectedTotalText)
                    .font(.caption.weight(.semibold).monospacedDigit())
            }

            if !amountText.isEmpty && !amountLooksValid {
                Text(
                    "Amount plus fee must fit within the selected input total."
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(
                cornerRadius: 15,
                style: .continuous
            )
        )
    }

    private func updateSendMaxAmount() {
        guard sendMax, let maximumSendSompi else { return }
        amountText = formatPlainKas(sompi: maximumSendSompi)
    }

    @MainActor
    private func refreshFeeEstimateForSendMax() async {
        guard let activeProfile = walletStore.profiles.first(
            where: { $0.id == profile.id }
        ) else {
            return
        }

        await syncService.refresh(
            profile: activeProfile,
            walletStore: walletStore,
            engine: engine,
            preferences: preferences,
            force: true
        )
        updateSendMaxAmount()
    }

    private var feeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fee")
                .font(.headline)

            Picker("Fee", selection: $selectedFee) {
                ForEach(SendFeeChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            if selectedFee == .custom {
                HStack(spacing: 10) {
                    TextField("0", text: $customFeeText)
                        .keyboardType(.decimalPad)
                        .font(
                            .subheadline
                                .weight(.semibold)
                                .monospacedDigit()
                        )

                    Text("KAS")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(
                    Color(.tertiarySystemGroupedBackground),
                    in: RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    )
                )
            } else {
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(
                cornerRadius: 15,
                style: .continuous
            )
        )
    }

    private func validateDestinationAddress(_ address: String) {
        addressValidationTask?.cancel()
        addressValidation = nil

        let trimmed = address
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            isValidatingAddress = false
            return
        }

        isValidatingAddress = true

        addressValidationTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            do {
                let result = try await engine.validateAddress(trimmed)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    addressValidation = result
                    isValidatingAddress = false

                    if result.valid,
                       let normalized = result.normalized,
                       normalized != destinationAddress {
                        destinationAddress = normalized
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    addressValidation = AddressValidationResult(
                        valid: false,
                        network: nil,
                        normalized: nil,
                        reason: error.localizedDescription
                    )
                    isValidatingAddress = false
                }
            }
        }
    }

    private func normalizedAddress(from rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .replacingOccurrences(
                of: "kaspa://",
                with: "kaspa:",
                options: [.caseInsensitive]
            )
    }

    private func parseKasTextToSompi(_ text: String) -> UInt64? {
        let raw = text
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")

        guard !raw.isEmpty,
              !raw.contains("-"),
              !raw.lowercased().contains("e")
        else { return nil }

        let parts = raw.split(
            separator: ".",
            omittingEmptySubsequences: false
        )

        guard parts.count <= 2 else { return nil }

        let wholeText = String(parts[0])
        let fractionalText = parts.count == 2
            ? String(parts[1])
            : ""

        guard !wholeText.isEmpty,
              wholeText.allSatisfy(\.isNumber),
              fractionalText.allSatisfy(\.isNumber),
              fractionalText.count <= 8,
              let whole = UInt64(wholeText)
        else {
            return nil
        }

        let wholeSompi = whole.multipliedReportingOverflow(
            by: 100_000_000
        )

        guard !wholeSompi.overflow else { return nil }

        let paddedFraction = fractionalText.padding(
            toLength: 8,
            withPad: "0",
            startingAt: 0
        )

        guard let fractionalSompi = UInt64(paddedFraction) else {
            return nil
        }

        let total = wholeSompi.partialValue.addingReportingOverflow(
            fractionalSompi
        )

        guard !total.overflow else { return nil }

        return total.partialValue
    }

    private var selectedTotalText: String {
        guard let selectedTotalSompi else {
            return "Invalid total"
        }
        return formatKas(sompi: selectedTotalSompi)
    }

    private func formatKas(sompi: UInt64) -> String {
        formatPlainKas(sompi: sompi) + " KAS"
    }

    private func formatFeeRate(_ rate: Double) -> String {
        rate.formatted(
            .number
                .precision(.fractionLength(0...3))
                .grouping(.never)
        )
    }

    private func formatPlainKas(sompi: UInt64) -> String {
        let whole = sompi / 100_000_000
        let fractional = sompi % 100_000_000

        guard fractional != 0 else {
            return String(whole)
        }

        let fractionalText = String(format: "%08llu", fractional)
            .replacingOccurrences(
                of: "0+$",
                with: "",
                options: .regularExpression
            )

        return "\(whole).\(fractionalText)"
    }
}

private struct VerifiedTransactionReview: Identifiable, Hashable {
    let id = UUID()
    let profileID: UUID
    let destination: String
    let amountSompi: UInt64
    let feeSompi: UInt64
    let changeSompi: UInt64
    let selectedInputCount: Int
    let selectedOutpoints: [String]
    let unsignedPSKB: String
    let verifiedDigest: String
    let selectedInputsVerified: Bool
    let destinationVerified: Bool
    let changeVerified: Bool
    let feeVerified: Bool
}

private struct VerifiedTransactionReviewView: View {
    let review: VerifiedTransactionReview
    let onComplete: () -> Void

    @State private var showingSigning = false

    private let accentColor = Color(
        red: 0.20,
        green: 0.62,
        blue: 0.57
    )

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VerifiedTransactionSummaryCards(
                    review: review
                )
                securityChecksCard
                continueButton
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Review Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(isPresented: $showingSigning) {
            VerifiedSigningPreparationView(
                review: review,
                onComplete: {
                    showingSigning = false
                    onComplete()
                }
            )
        }
    }







    private var securityChecksCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Security Checks")
                .font(.title3.weight(.semibold))

            securityRow(
                "Selected inputs match the decoded PSKB",
                passed: review.selectedInputsVerified
            )

            securityRow(
                "Destination and amount match",
                passed: review.destinationVerified
            )

            securityRow(
                "All change outputs belong to this wallet",
                passed: review.changeVerified
            )

            securityRow(
                "Fee matches decoded input and output totals",
                passed: review.feeVerified
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
    }

    private var continueButton: some View {
        Button {

            let currentDigest = SHA256.hash(
                data: Data(review.unsignedPSKB.utf8)
            ).map {
                String(format: "%02x", $0)
            }.joined()

            guard currentDigest == review.verifiedDigest else {
                assertionFailure("Verified PSKB integrity failure.")
                return
            }

            showingSigning = true
        } label: {
            Text("Continue to Signing")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .disabled(
            !review.selectedInputsVerified
                || !review.destinationVerified
                || !review.changeVerified
                || !review.feeVerified
        )
    }

    private func securityRow(
        _ title: String,
        passed: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(
                systemName: passed
                    ? "checkmark.circle.fill"
                    : "xmark.circle.fill"
            )
            .foregroundStyle(passed ? accentColor : .red)

            Text(title)
                .font(.subheadline)
        }
    }

    private func valueRow(
        _ title: String,
        value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.body.weight(.semibold).monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }

    private func formatKas(_ sompi: UInt64) -> String {
        let whole = sompi / 100_000_000
        let fractional = sompi % 100_000_000

        guard fractional != 0 else {
            return "\(whole) KAS"
        }

        let fractionalText = String(format: "%08llu", fractional)
            .replacingOccurrences(
                of: "0+$",
                with: "",
                options: .regularExpression
            )

        return "\(whole).\(fractionalText) KAS"
    }
}

private struct VerifiedTransactionSummaryCards: View {
    let review: VerifiedTransactionReview

    @EnvironmentObject private var copyFeedbackCenter: CopyFeedbackCenter

    private var accentColor: Color {
        Color(
            red: 0.20,
            green: 0.62,
            blue: 0.57
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            transactionCard
            destinationCard
            inputsCard
        }
    }

    private var transactionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transaction")
                .font(.title3.weight(.semibold))

            valueRow("Amount", value: formatKas(review.amountSompi))
            Divider()
            valueRow("Fee", value: formatKas(review.feeSompi))
            Divider()
            valueRow("Change", value: formatKas(review.changeSompi))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Destination")
                    .font(.title3.weight(.semibold))

                Spacer()

                Button {
                    UIPasteboard.general.string = review.destination
                    copyFeedbackCenter.showCopied(review.destination)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(SubtlePressButtonStyle())
                .accessibilityLabel("Copy destination")
            }

            Text(review.destination)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    Color(.tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
    }

    private var inputsCard: some View {
        HStack {
            Text("Selected Inputs")
                .font(.title3.weight(.semibold))

            Spacer()

            Text(
                review.selectedInputCount == 1
                    ? "1 selected UTXO"
                    : "\(review.selectedInputCount) selected UTXOs"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
    }

    private func valueRow(
        _ title: String,
        value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.body.weight(.semibold).monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }

    private func formatKas(_ sompi: UInt64) -> String {
        let whole = sompi / 100_000_000
        let fractional = sompi % 100_000_000

        guard fractional != 0 else {
            return "\(whole) KAS"
        }

        let fractionalText = String(format: "%08llu", fractional)
            .replacingOccurrences(
                of: "0+$",
                with: "",
                options: .regularExpression
            )

        return "\(whole).\(fractionalText) KAS"
    }
}


private struct VerifiedSigningPreparationView: View {
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var preferences: AppPreferences

    let review: VerifiedTransactionReview
    let onComplete: () -> Void

    @State private var qrFrames: [KasSeeQRFrame] = []
    @State private var frameIndex = 0
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var isPlaying = false
    @State private var showingSignedQRScanner = false
    @State private var decoderProgressCount = 0
    @State private var decoderProgressTotal = 0
    @State private var decoderBits: [Bool] = []
    @State private var signedPayload: String?
    @State private var signedKSPTForBroadcast: String?
    @State private var isBroadcastingSignedTransaction = false
    @State private var broadcastTransactionID: String?
    @State private var showingBroadcastSuccess = false
    @State private var showingBroadcastReview = false
    @State private var scanErrorMessage: String?
    @State private var isStartingScanner = false
    @State private var signedScanFeedback: QRScanFeedback = .idle
    @State private var lastScannedFrame: String?
    @State private var lastProgressCount = 0

    private let frameTimer = Timer.publish(
        every: 0.75,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                signingCard
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Signing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            await loadQRFrames()
        }
        .onReceive(frameTimer) { _ in
            guard isPlaying, qrFrames.count > 1 else { return }
            frameIndex = (frameIndex + 1) % qrFrames.count
        }
        .sheet(isPresented: $showingSignedQRScanner) {
            QRScannerView(
                feedback: signedScanFeedback,
                progressText: decoderProgressTotal > 0
                    ? "\(decoderProgressCount) / \(decoderProgressTotal) frames"
                    : "Scan signed transaction frames"
            ) { scannedFrame in
                Task {
                    await processSignedQRFrame(scannedFrame)
                }
            }
        }

        .fullScreenCover(isPresented: $showingBroadcastSuccess) {
            if let transactionID = broadcastTransactionID {
                BroadcastSuccessView(
                    transactionID: transactionID,
                    onDone: {
                        onComplete()
                    }
                )
            }
        }
}

    @ViewBuilder
    private var signingCard: some View {
        VStack(spacing: 14) {
            if loading {
                ProgressView()
                    .padding(.vertical, 80)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)

                    Text("Signing QR could not be generated")
                        .font(.headline)

                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Try Again") {
                        Task {
                            await loadQRFrames()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else if showingBroadcastReview {
                VStack(spacing: 20) {
                    VerifiedTransactionSummaryCards(review: review)

                    broadcastButton
                }
            } else if let currentFrame {
                Text("Scan with KasSigner M5")
                    .font(.title3.weight(.semibold))

                SharedSVGQRCodeView(svg: currentFrame.svg)
                    .frame(maxWidth: 304)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(10)
                    .background(Color.white)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 8,
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: 8,
                            style: .continuous
                        )
                        .stroke(
                            Color(
                                red: 0.33,
                                green: 0.93,
                                blue: 0.86
                            ),
                            lineWidth: 2.5
                        )
                    }

                Text(
                    "Frame \(currentFrame.frameNumber + 1) of "
                        + "\(currentFrame.totalFrames)"
                )
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)

                HStack(spacing: 20) {

                    Button {
                        frameIndex = (frameIndex - 1 + qrFrames.count) % qrFrames.count
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        isPlaying.toggle()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        frameIndex = (frameIndex + 1) % qrFrames.count
                    } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .buttonStyle(.bordered)

                }

                Text("Keep this screen visible while the M5 scans the transaction.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)


                Divider()
                    .padding(.vertical, 4)

                Button {
                    Task {
                        await beginSignedQRScan()
                    }
                } label: {
                    if isStartingScanner {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label(
                            "Scan Signed QR",
                            systemImage: "qrcode.viewfinder"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isStartingScanner)

                if decoderProgressTotal > 0 {
                    VStack(spacing: 10) {
                        Text(
                            "\(decoderProgressCount) of "
                                + "\(decoderProgressTotal) frames received"
                        )
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)

                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(minimum: 12),
                                    spacing: 7
                                )
                            ],
                            spacing: 7
                        ) {
                            ForEach(
                                Array(decoderBits.enumerated()),
                                id: \.offset
                            ) { _, received in
                                Circle()
                                    .fill(
                                        received
                                            ? Color(
                                                red: 0.20,
                                                green: 0.62,
                                                blue: 0.57
                                            )
                                            : Color.secondary.opacity(0.22)
                                    )
                                    .frame(width: 10, height: 10)
                            }
                        }
                    }
                }

                if signedPayload != nil {
                    Label(
                        "Signed transaction QR received",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(
                        Color(
                            red: 0.20,
                            green: 0.62,
                            blue: 0.57
                        )
                    )

                    broadcastButton


                }

                if let scanErrorMessage {
                    Text(scanErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
    }

    private var currentFrame: KasSeeQRFrame? {
        guard qrFrames.indices.contains(frameIndex) else { return nil }
        return qrFrames[frameIndex]
    }

    @MainActor
    private func beginSignedQRScan() async {
        guard !isStartingScanner else { return }

        isStartingScanner = true
        scanErrorMessage = nil
        signedPayload = nil
        signedKSPTForBroadcast = nil
        broadcastTransactionID = nil
        isBroadcastingSignedTransaction = false
        decoderProgressCount = 0
        decoderProgressTotal = 0
        decoderBits = []
        lastProgressCount = 0
        lastScannedFrame = nil
        signedScanFeedback = .idle

        do {
            try await engine.resetQRDecoder()
            showingSignedQRScanner = true
        } catch {
            scanErrorMessage = error.localizedDescription
        }

        isStartingScanner = false
    }



    @ViewBuilder
    private var broadcastButton: some View {
        if signedKSPTForBroadcast != nil &&
            broadcastTransactionID == nil {
            Button {
                Task {
                    await broadcastSignedTransaction()
                }
            } label: {
                HStack(spacing: 8) {
                    if isBroadcastingSignedTransaction {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }

                    Text(
                        isBroadcastingSignedTransaction
                            ? "Broadcasting…"
                            : "Broadcast Transaction"
                    )
                    .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBroadcastingSignedTransaction)
        }
    }

    @MainActor
    private func refreshWalletAfterBroadcast() async {
        guard let profile = walletStore.selectedProfile else {
            return
        }

        try? await Task.sleep(for: .milliseconds(900))

        await syncService.refresh(
            profile: profile,
            walletStore: walletStore,
            engine: engine,
            preferences: preferences,
            force: true
        )
    }

    @MainActor
    private func broadcastSignedTransaction() async {
        guard let signedKSPTForBroadcast,
              !isBroadcastingSignedTransaction
        else {
            return
        }

        guard let snapshot = syncService.snapshot else {
            scanErrorMessage =
                "No active Kaspa node is available for broadcasting."
            return
        }

        let wsURL = snapshot.nodeURL
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        guard !wsURL.isEmpty else {
            scanErrorMessage =
                "No active Kaspa node is available for broadcasting."
            return
        }

        isBroadcastingSignedTransaction = true
        scanErrorMessage = nil

        defer {
            isBroadcastingSignedTransaction = false
        }

        do {
            let transactionID = try await engine.broadcastSignedKSPT(
                signedKSPTHex: signedKSPTForBroadcast,
                wsURL: wsURL
            )
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            broadcastTransactionID = transactionID
            showingBroadcastSuccess = true

            Task {
                await refreshWalletAfterBroadcast()
            }
        } catch {
            scanErrorMessage =
                "Broadcast failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func processSignedQRFrame(_ scannedFrame: String) async {
        guard showingSignedQRScanner else { return }

        let normalizedFrame = scannedFrame
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        guard !normalizedFrame.isEmpty else { return }

        // The camera sees the same displayed M5 frame many times.
        // Ignore identical consecutive reads instead of repeatedly decoding it.
        guard normalizedFrame != lastScannedFrame else { return }
        lastScannedFrame = normalizedFrame

        do {
            let frameHex: String

            if normalizedFrame.hasPrefix("KSBIN:") {
                frameHex = String(
                    normalizedFrame.dropFirst("KSBIN:".count)
                )

            } else {
                frameHex = normalizedFrame.utf8
                    .map { String(format: "%02x", $0) }
                    .joined()

            }

            if let completedPayload = try await engine.decodeQRFrame(
                frameHex
            ) {
                let signedKSPT = completedPayload
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)


                let mergedPSKB = try await engine.mergeSignedKSPTIntoPSKB(
                    signedKSPTHex: signedKSPT,
                    originalPSKBHex: review.unsignedPSKB
                )

                signedKSPTForBroadcast = signedKSPT
                signedPayload = mergedPSKB
                signedScanFeedback = .accepted


                showingSignedQRScanner = false
                showingBroadcastReview = true
                decoderProgressCount = max(
                    decoderProgressTotal,
                    lastProgressCount
                )
                decoderBits = Array(
                    repeating: true,
                    count: max(
                        decoderProgressTotal,
                        decoderBits.count
                    )
                )
                return
            }

            let progress = try await engine.decoderProgress()


            decoderProgressCount = progress.count
            decoderProgressTotal = progress.total
            decoderBits = progress.bits

            if progress.count > lastProgressCount {
                lastProgressCount = progress.count
                signedScanFeedback = .accepted


                Task { @MainActor in
                    try? await Task.sleep(
                        nanoseconds: 450_000_000
                    )
                    if showingSignedQRScanner {
                        signedScanFeedback = .idle
                    }
                }
            } else {
                signedScanFeedback = .rejected

                Task { @MainActor in
                    try? await Task.sleep(
                        nanoseconds: 300_000_000
                    )
                    if showingSignedQRScanner {
                        signedScanFeedback = .idle
                    }
                }
            }

        } catch {
            signedScanFeedback = .rejected
            scanErrorMessage = error.localizedDescription


            // Permit the same displayed M5 frame to be retried after an error.
            lastScannedFrame = nil
        }
    }

    @MainActor
    private func loadQRFrames() async {
        loading = true
        errorMessage = nil
        frameIndex = 0
        isPlaying = false

        let currentDigest = SHA256.hash(
            data: Data(review.unsignedPSKB.utf8)
        )
        .map { String(format: "%02x", $0) }
        .joined()

        guard currentDigest == review.verifiedDigest else {
            loading = false
            errorMessage = "Verified transaction integrity check failed."
            return
        }

        do {
            let compactKSPT = try await engine.relayPSKBToKSPT(
                review.unsignedPSKB
            )

            let generatedFrames = try await engine.generateQRFrames(
                from: compactKSPT
            )

            guard !generatedFrames.isEmpty,
                  generatedFrames.allSatisfy({ !$0.svg.isEmpty })
            else {
                throw SigningQRGenerationError.emptyFrames
            }

            qrFrames = generatedFrames
            loading = false
        } catch {
            qrFrames = []
            loading = false
            errorMessage = error.localizedDescription
        }
    }
}

private struct BroadcastSuccessView: View {
    @EnvironmentObject private var preferences: AppPreferences
    let transactionID: String
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(
                        Color(
                            red: 0.20,
                            green: 0.62,
                            blue: 0.57
                        )
                    )

                VStack(spacing: 10) {
                    Text("Transaction Broadcasted Successfully")
                        .font(.title2.weight(.bold))

                    Text(
                        "Your transaction was successfully broadcasted "
                        + "to the Kaspa network."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Transaction ID")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Link(
                        destination: preferences.explorer.transactionURL(
                            transactionID
                        )
                    ) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(transactionID)
                                .font(.caption.monospaced())
                                .multilineTextAlignment(.leading)

                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                        }
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                    }
                    .accessibilityHint(
                        "Opens in \(preferences.explorer.title)"
                    )
                }
                .padding(16)
                .background(
                    RoundedRectangle(
                        cornerRadius: 16,
                        style: .continuous
                    )
                    .fill(.thinMaterial)
                )

                Spacer()

                Button("Done") {
                    onDone()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .padding(20)
            .navigationBarBackButtonHidden(true)
        }
    }
}


private struct SharedSVGQRCodeView: UIViewRepresentable {
    let svg: String

    final class Coordinator {
        var lastSVG: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(
            frame: .zero,
            configuration: configuration
        )

        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .clear
        webView.isUserInteractionEnabled = false

        return webView
    }

    func updateUIView(
        _ webView: WKWebView,
        context: Context
    ) {
        guard context.coordinator.lastSVG != svg else { return }
        context.coordinator.lastSVG = svg

        let html = """
        <!doctype html>
        <html>
        <head>
            <meta name="viewport"
                  content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
            <style>
                html, body {
                    margin: 0;
                    padding: 0;
                    width: 100%;
                    height: 100%;
                    overflow: hidden;
                    background: #ffffff;
                }

                body {
                    display: flex;
                    align-items: center;
                    justify-content: center;
                }

                svg {
                    display: block;
                    width: 100%;
                    height: 100%;
                    shape-rendering: crispEdges;
                }
            </style>
        </head>
        <body>
            \(svg)
        </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: nil)
    }
}

private enum SigningQRGenerationError: LocalizedError {
    case emptyFrames

    var errorDescription: String? {
        switch self {
        case .emptyFrames:
            return "The QR encoder returned no usable frames."
        }
    }
}

private enum SendVerificationError: LocalizedError {
    case inputCountMismatch
    case missingInputOutpoint
    case inputOutpointMismatch
    case missingOutputs
    case destinationMismatch
    case invalidOutput
    case unknownOutput
    case invalidFeeArithmetic
    case customFeeMismatch
    case changeAddressUnavailable
    case changeAddressMismatch
    case walletStateChanged

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
        case .destinationMismatch:
            return "The built transaction destination or amount does not match."
        case .invalidOutput:
            return "The built transaction contains an invalid output."
        case .unknownOutput:
            return "The built transaction contains an unknown output."
        case .invalidFeeArithmetic:
            return "The built transaction fee arithmetic is invalid."
        case .customFeeMismatch:
            return "The fee encoded in the transaction does not match the custom fee you entered."
        case .changeAddressUnavailable:
            return "No unused change address is available. Refresh the wallet and try again."
        case .changeAddressMismatch:
            return "The transaction did not use the expected unused change address."
        case .walletStateChanged:
            return "The wallet address state changed. Return to the wallet and try again."
        }
    }
}

private enum SendFeeChoice: String, CaseIterable, Identifiable {
    case low
    case normal
    case priority
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low:
            return "Low"
        case .normal:
            return "Normal"
        case .priority:
            return "Priority"
        case .custom:
            return "Custom"
        }
    }

    var detail: String {
        switch self {
        case .low:
            return "Lower network fee. Confirmation may take longer during congestion."
        case .normal:
            return "Balanced network fee for typical transactions."
        case .priority:
            return "Higher fee for faster inclusion during congestion."
        case .custom:
            return "Enter a custom fee in KAS."
        }
    }
}
