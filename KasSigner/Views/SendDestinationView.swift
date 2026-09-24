import SwiftUI
import UIKit
import WebKit
import CryptoKit
import Combine

struct SendDestinationView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: WalletProfile
    let selectedUTXOs: [WalletUTXO]
    let transactionType: SendTransactionType
    let sessionID: UUID
    @Binding var showingSendFlow: Bool

    @State private var destinationAddress = ""
    @State private var amountText = ""
    @State private var usdAmountText = ""
    @State private var amountEntryUsesUSD = false
    @State private var additionalRecipients: [SendRecipientDraft] = []
    @State private var additionalRecipientValidity: [UUID: Bool] = [:]
    @State private var sendMax = false
    @State private var selectedFee: SendFeeChoice = .normal
    @State private var customFeeText = ""
    @State private var showingScanner = false
    @State private var unsignedPSKB: String?
    @State private var showingBuildError = false
    @State private var buildErrorMessage = ""
    @State private var isBuildingPSKB = false
    @State private var verifiedReview: VerifiedTransactionReview?
    @State private var changeOutputs: [PlannedChangeOutput] = []
    @State private var usesManualChangeAllocation = false
    @State private var resolvedChangeFeeSompi: UInt64?
    @State private var showingChangeAddressPicker = false
    @State private var showingCancelConfirmation = false
    @State private var livePlanTask: Task<Void, Never>?
    @State private var isResolvingLivePlan = false
    @State private var livePlanError: String?
    @State private var isRefreshingSendMaxFee = false
    @FocusState private var customFeeFieldFocused: Bool

    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var coinControlStore: UTXOCoinControlStore
    @EnvironmentObject private var priceService: PriceService
    @State private var addressValidation: AddressValidationResult?
    @State private var isValidatingAddress = false
    @State private var addressValidationTask: Task<Void, Never>?

    private let accentColor = Color(red: 0.20, green: 0.62, blue: 0.57)

    private var enteredAmountSompi: UInt64? {
        parseKasTextToSompi(amountText)
    }

    private var sendRecipients: [SendDraftRecipient]? {
        guard let primaryAmount = enteredAmountSompi else { return nil }
        var recipients = [SendDraftRecipient(address: destinationAddress, amountSompi: primaryAmount)]
        for recipient in additionalRecipients {
            guard let amount = parseKasTextToSompi(recipient.amountText), amount > 0 else {
                return nil
            }
            recipients.append(SendDraftRecipient(address: recipient.address, amountSompi: amount))
        }
        return recipients
    }

    private var totalRecipientSompi: UInt64? {
        sendRecipients?.reduce(into: UInt64?.some(0)) { total, recipient in
            guard let current = total else { return }
            let addition = current.addingReportingOverflow(recipient.amountSompi)
            total = addition.overflow ? nil : addition.partialValue
        }
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
        guard let amount = totalRecipientSompi,
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
        case .normal:
            return fee.normalSompiPerGram

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
        case .normal:
            return "Normal • \(feeAmount) • \(formatFeeRate(fee.normalSompiPerGram)) sompi/gram"

        case .custom:
            return ""
        }
    }

    private var customFeeSompi: UInt64? {
        parseKasTextToSompi(customFeeText)
    }

    private var provisionalFeeSompi: UInt64? {
        switch selectedFee {
        case .custom:
            guard let customFeeSompi, customFeeSompi > 0 else {
                return nil
            }
            return customFeeSompi

        case .normal:
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

    private var requestedFeeSompi: UInt64? {
        resolvedChangeFeeSompi ?? provisionalFeeSompi
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

    private var availableChangeSompi: UInt64? {
        guard !sendMax,
              let selectedTotalSompi,
              let totalRecipientSompi,
              let requestedFeeSompi
        else { return sendMax ? 0 : nil }
        let required = totalRecipientSompi.addingReportingOverflow(requestedFeeSompi)
        guard !required.overflow, selectedTotalSompi >= required.partialValue else { return nil }
        return selectedTotalSompi - required.partialValue
    }

    private var feeLooksValid: Bool {
        guard selectedFee == .custom else { return true }
        guard let fee = customFeeSompi else { return false }
        return fee > 0
    }

    private var requiresLiveChangePlan: Bool {
        !sendMax
            && (transactionType != .standard
                || !additionalRecipients.isEmpty
                || usesManualChangeAllocation)
    }

    private var transactionTypeSubtitle: String {
        switch transactionType {
        case .standard: "Standard"
        case .privacyFocused: "Privacy"
        case .decoy: "Decoy"
        }
    }

    private var canContinue: Bool {
        let normalizedAddresses = ([destinationAddress] + additionalRecipients.map(\.address))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return destinationLooksValid
            && amountLooksValid
            && feeLooksValid
            && !isRefreshingSendMaxFee
            && (transactionType == .standard || !sendMax)
            && (!requiresLiveChangePlan
                || (!isResolvingLivePlan
                    && livePlanError == nil
                    && resolvedChangeFeeSompi != nil))
            && additionalRecipients.allSatisfy {
                !$0.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (parseKasTextToSompi($0.amountText) ?? 0) > 0
                    && additionalRecipientValidity[$0.id] == true
            }
            && Set(normalizedAddresses).count == normalizedAddresses.count
    }

    var body: some View {
        presentationContent
    }

    private var baseContent: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 14) {
                        destinationCards
                        amountCard
                        changeAddressCard
                        feeCard
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .background(Color(.systemGroupedBackground))
                .onChange(of: selectedFee) { _, choice in
                    guard choice == .custom else {
                        customFeeFieldFocused = false
                        return
                    }

                    Task { @MainActor in
                        await Task.yield()
                        customFeeFieldFocused = true
                        try? await Task.sleep(for: .milliseconds(250))
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo("custom-fee-field", anchor: .center)
                        }
                    }
                }
            }

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
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingCancelConfirmation = true
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }

            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("Destination & Amount")
                        .font(.headline)

                    Text(transactionTypeSubtitle)
                        .font(.caption)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private var stateContent: some View {
        baseContent
        .onAppear {
            restoreSendSession()
        }
        .onDisappear {
            addressValidationTask?.cancel()
            livePlanTask?.cancel()
        }
        .onChange(of: selectedFee) { _, _ in
            resolvedChangeFeeSompi = nil
            updateSendMaxAmount()
            persistSendSession()
            scheduleLivePlanResolution()
        }
        .onChange(of: customFeeText) { _, _ in
            resolvedChangeFeeSompi = nil
            updateSendMaxAmount()
            persistSendSession()
            scheduleLivePlanResolution()
        }
        .onChange(of: destinationAddress) { _, _ in
            resolvedChangeFeeSompi = nil
            persistSendSession()
            scheduleLivePlanResolution()
        }
        .onChange(of: amountText) { _, _ in
            resolvedChangeFeeSompi = nil
            persistSendSession()
            scheduleLivePlanResolution()
        }
        .onChange(of: sendMax) { _, enabled in
            resolvedChangeFeeSompi = nil
            persistSendSession()
            if enabled {
                amountText = ""
                usdAmountText = ""
                Task {
                    await refreshFeeEstimateForSendMax()
                }
            }
        }
        .onChange(of: changeOutputs) { _, _ in
            resolvedChangeFeeSompi = nil
            persistSendSession()
            scheduleLivePlanResolution()
        }
        .onChange(of: additionalRecipients) { _, _ in
            if additionalRecipients.isEmpty == false {
                sendMax = false
            }
            persistSendSession()
            scheduleLivePlanResolution()
        }
        .onChange(of: syncService.feeEstimate) { _, _ in
            resolvedChangeFeeSompi = nil
            updateSendMaxAmount()
            scheduleLivePlanResolution()
        }
    }

    private var presentationContent: some View {
        stateContent
        .sheet(isPresented: $showingScanner) {
            QRScannerView { scannedValue in
                let scanned = normalizedAddress(from: scannedValue)
                destinationAddress = scanned
                validateDestinationAddress(scanned)
                showingScanner = false
            }
        }
        .sheet(isPresented: $showingChangeAddressPicker) {
            ChangeAddressPickerView(
                profileID: profile.id,
                transactionType: transactionType,
                availableChangeSompi: availableChangeSompi ?? 0,
                selectedOutputs: $changeOutputs,
                resolvePlan: { outputs in
                    try await resolveChangePlan(outputs)
                },
                preparePrivacyPlan: { outputs in
                    guard destinationLooksValid,
                          enteredAmountSompi != nil,
                          provisionalFeeSompi != nil else {
                        throw SendVerificationError.allocationNeedsValidAmount
                    }
                    return try await resolveBalancedChangePlan(outputs)
                },
                completeStandardSelection: { outputs in
                    changeOutputs = outputs
                    usesManualChangeAllocation = true
                    resolvedChangeFeeSompi = nil
                    scheduleLivePlanResolution(immediately: true)
                },
                completePlan: { outputs, plan in
                    changeOutputs = outputs
                    usesManualChangeAllocation = true
                    resolvedChangeFeeSompi = plan.feeSompi
                }
            )
            .environmentObject(engine)
            .environmentObject(walletStore)
        }
        .alert("Transaction could not be built", isPresented: $showingBuildError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(buildErrorMessage)
        }
        .alert("Cancel transaction?", isPresented: $showingCancelConfirmation) {
            Button("Keep Editing", role: .cancel) {}
            Button("Cancel Transaction", role: .destructive) {
                cancelTransactionAndReturnToWallet()
            }
        } message: {
            Text(
                "This signing session and any unsigned transaction data "
                + "will be discarded. You’ll need to start over."
            )
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

    @ViewBuilder
    private var destinationCards: some View {
        destinationCard
        ForEach($additionalRecipients) { $recipient in
            AdditionalRecipientCard(
                recipient: $recipient,
                onRemove: { removeAdditionalRecipient(id: recipient.id) },
                onValidationChange: { isValid in
                    additionalRecipientValidity[recipient.id] = isValid
                }
            )
            .environmentObject(engine)
        }
    }

    private func removeAdditionalRecipient(id: UUID) {
        additionalRecipients.removeAll { $0.id == id }
        additionalRecipientValidity[id] = nil
    }

    @MainActor
    private func resolveChangePlan(
        _ outputs: [PlannedChangeOutput]
    ) async throws -> (outputs: [PlannedChangeOutput], plan: ChangeFeePlan) {
        guard let activeProfile = walletStore.profiles.first(
            where: { $0.id == profile.id }
        ) else {
            throw SendVerificationError.walletStateChanged
        }
        guard let recipients = sendRecipients,
              let feeSompi = provisionalFeeSompi
        else {
            throw SendVerificationError.invalidFeeArithmetic
        }
        let draft = try SendDraft(
            profile: activeProfile,
            transactionType: transactionType,
            selectedUTXOs: selectedUTXOs,
            recipients: recipients,
            feeSompi: feeSompi,
            feeRateSompiPerGram: selectedFeeRateSompiPerGram ?? 0,
            usesExactFee: selectedFee == .custom,
            sendMax: false,
            changeOutputs: outputs
        )
        let plan = try await engine.planChangeOutputs(from: draft)
        guard plan.amountsSompi.count == outputs.count else {
            throw SendVerificationError.changeAmountMismatch
        }
        var resolvedOutputs = outputs
        for index in resolvedOutputs.indices {
            resolvedOutputs[index].amountSompi = plan.amountsSompi[index]
        }
        return (resolvedOutputs, plan)
    }

    @MainActor
    private func resolveBalancedChangePlan(
        _ selectedOutputs: [PlannedChangeOutput]
    ) async throws -> (outputs: [PlannedChangeOutput], plan: ChangeFeePlan) {
        guard let initialAvailable = availableChangeSompi,
              initialAvailable > 0 else {
            throw SendVerificationError.invalidFeeArithmetic
        }

        let split = try ChangeOutputPlanner.autoSplit(
            availableChangeSompi: initialAvailable,
            selectedOutputs: selectedOutputs,
            minimumOutputSompi: 66_900
        )
        return try await resolveChangePlan(split)
    }

    private func scheduleLivePlanResolution(immediately: Bool = false) {
        guard requiresLiveChangePlan else { return }
        livePlanTask?.cancel()
        livePlanError = nil
        guard destinationLooksValid,
              enteredAmountSompi != nil,
              provisionalFeeSompi != nil
        else { return }

        livePlanTask = Task { @MainActor in
            if !immediately {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled else { return }
            await resolveLivePlan()
        }
    }

    @MainActor
    private func resolveLivePlan() async {
        guard !isResolvingLivePlan,
              let selectedTotalSompi,
              let recipientTotal = totalRecipientSompi,
              let feeSompi = provisionalFeeSompi
        else { return }
        let required = recipientTotal.addingReportingOverflow(feeSompi)
        guard !required.overflow, selectedTotalSompi >= required.partialValue else {
            livePlanError = "The selected UTXOs cannot cover this transaction."
            return
        }

        isResolvingLivePlan = true
        defer { isResolvingLivePlan = false }
        do {
            var outputs = changeOutputs
            if transactionType != .decoy,
               outputs.contains(where: { $0.amountSompi == 0 }) {
                outputs = try ChangeOutputPlanner.autoSplit(
                    availableChangeSompi: selectedTotalSompi - required.partialValue,
                    selectedOutputs: outputs,
                    minimumOutputSompi: 66_900
                )
            }
            let resolved = try await resolveChangePlan(outputs)
            resolvedChangeFeeSompi = resolved.plan.feeSompi
            livePlanError = nil
        } catch {
            resolvedChangeFeeSompi = nil
            livePlanError = error.localizedDescription
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

            var transactionFeeSompi = requestedFeeSompi
            var plannedChangeOutputs: [PlannedChangeOutput] = []
            var plannedAvailableChangeSompi = availableChangeSompi

            let requiresExplicitChangePlan = usesManualChangeAllocation
                || transactionType != .standard
                || !additionalRecipients.isEmpty

            if requiresExplicitChangePlan,
               !sendMax,
               let availableChangeSompi,
               availableChangeSompi > 0 {
                var outputsToResolve = changeOutputs
                if transactionType != .decoy,
                   outputsToResolve.contains(where: { $0.amountSompi == 0 }) {
                    outputsToResolve = try ChangeOutputPlanner.autoSplit(
                        availableChangeSompi: availableChangeSompi,
                        selectedOutputs: outputsToResolve,
                        minimumOutputSompi: 66_900
                    )
                }
                let resolved = try await resolveChangePlan(outputsToResolve)
                plannedChangeOutputs = resolved.outputs
                plannedAvailableChangeSompi = resolved.plan.availableChangeSompi
                transactionFeeSompi = resolved.plan.feeSompi
                changeOutputs = resolved.outputs
                resolvedChangeFeeSompi = resolved.plan.feeSompi
            }

            if requiresExplicitChangePlan,
               let plannedAvailableChangeSompi,
               plannedAvailableChangeSompi > 0 {
                guard !plannedChangeOutputs.isEmpty else {
                    throw ChangeOutputPlanningError.noOutputs
                }
                guard plannedChangeOutputs.count <= ChangeOutputPlanner.maximumOutputCount,
                      Set(plannedChangeOutputs.map(\.id)).count == plannedChangeOutputs.count
                else {
                    throw ChangeOutputPlanningError.duplicateAddress
                }
                var plannedTotal: UInt64 = 0
                for output in plannedChangeOutputs {
                    guard activeProfile.changeAddresses.indices.contains(output.addressIndex),
                          activeProfile.changeAddresses[output.addressIndex]
                            .caseInsensitiveCompare(output.address) == .orderedSame,
                          output.amountSompi > 0
                    else {
                        throw SendVerificationError.walletStateChanged
                    }
                    let addition = plannedTotal.addingReportingOverflow(output.amountSompi)
                    guard !addition.overflow else { throw SendVerificationError.invalidFeeArithmetic }
                    plannedTotal = addition.partialValue
                }
                guard plannedTotal == plannedAvailableChangeSompi else {
                    throw SendVerificationError.changeAmountMismatch
                }
            } else if requiresExplicitChangePlan && !plannedChangeOutputs.isEmpty {
                throw SendVerificationError.changeAmountMismatch
            }

            // Provisional runtime checkpoint only. Final fee selection will use
            // the exact verified transaction mass.
            guard let recipients = sendRecipients else {
                throw SendDraftError.emptyDestination
            }
            let draft = try SendDraft(
                profile: activeProfile,
                transactionType: transactionType,
                selectedUTXOs: selectedUTXOs,
                recipients: recipients,
                feeSompi: transactionFeeSompi,
                feeRateSompiPerGram: selectedFeeRateSompiPerGram ?? 0,
                usesExactFee: selectedFee == .custom,
                sendMax: sendMax,
                changeOutputs: plannedChangeOutputs
            )

            let pskb = try await engine.buildUnsignedPSKB(from: draft)

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

            let verifiedRecipients = draft.recipients
            for recipient in verifiedRecipients {
                let normalizedAddress = recipient.address.lowercased()
                let matches = outputs.filter {
                    $0.address?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        == normalizedAddress
                        && $0.amountSompi == recipient.amountSompi
                }
                guard matches.count == 1 else {
                    throw SendVerificationError.destinationMismatch
                }
            }
            let verifiedRecipientTotal = verifiedRecipients.reduce(0) {
                $0 + $1.amountSompi
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
               reportedFee != transactionFeeSompi {
                throw SendVerificationError.customFeeMismatch
            }

            let afterAmount = totalInput.subtractingReportingOverflow(
                verifiedRecipientTotal
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

            let verifiedChangeOutputs: [PlannedChangeOutput]
            if requiresExplicitChangePlan {
                verifiedChangeOutputs = plannedChangeOutputs
            } else if verifiedChangeSompi > 0 {
                guard activeProfile.changeAddresses.indices.contains(
                    activeProfile.nextChangeIndex
                ) else {
                    throw SendVerificationError.changeAddressUnavailable
                }
                verifiedChangeOutputs = [
                    PlannedChangeOutput(
                        addressIndex: activeProfile.nextChangeIndex,
                        address: activeProfile.changeAddresses[
                            activeProfile.nextChangeIndex
                        ],
                        amountSompi: verifiedChangeSompi
                    )
                ]
            } else {
                verifiedChangeOutputs = []
            }

            for output in outputs {
                guard let address = output.address?
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    .lowercased(),
                      let outputAmount = output.amountSompi
                else {
                    throw SendVerificationError.invalidOutput
                }

                let isDestination = verifiedRecipients.contains {
                    $0.address.lowercased() == address
                        && $0.amountSompi == outputAmount
                }

                let isWalletChange = verifiedChangeOutputs.contains {
                    $0.id == address && $0.amountSompi == outputAmount
                }

                guard isDestination || isWalletChange else {
                    throw SendVerificationError.unknownOutput
                }
            }

            guard verifiedChangeSompi == verifiedChangeOutputs.reduce(0, { $0 + $1.amountSompi }),
                  outputs.count == verifiedRecipients.count + verifiedChangeOutputs.count,
                  countedOutputsMatch(outputs, recipients: verifiedRecipients, changeOutputs: verifiedChangeOutputs)
            else { throw SendVerificationError.changeAddressMismatch }

            let normalizedDestination = verifiedRecipients[0].address.lowercased()

            unsignedPSKB = pskb
            if var session = walletStore.sendSession(
                id: sessionID,
                profileID: activeProfile.id
            ) {
                session.destination = normalizedDestination
                session.amountText = amountText
                session.sendMax = sendMax
                session.feeChoice = selectedFee.rawValue
                session.customFeeText = customFeeText
                session.changeOutputs = requiresExplicitChangePlan
                    ? verifiedChangeOutputs
                    : changeOutputs
                session.recipients = verifiedRecipients.map {
                    SendRecipientDraft(
                        address: $0.address,
                        amountText: formatPlainKas(sompi: $0.amountSompi)
                    )
                }
                session.usesManualChangeAllocation = usesManualChangeAllocation
                session.unsignedPSKB = pskb
                session.verifiedDigest = SHA256.hash(
                    data: Data(pskb.utf8)
                ).map { String(format: "%02x", $0) }.joined()
                session.stage = .verified
                walletStore.updateSendSession(session)
            }
            verifiedReview = VerifiedTransactionReview(
                profileID: activeProfile.id,
                destination: normalizedDestination,
                amountSompi: verifiedRecipients[0].amountSompi,
                recipients: verifiedRecipients,
                feeSompi: reportedFee,
                changeSompi: verifiedChangeSompi,
                changeOutputs: verifiedChangeOutputs,
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

    private func restoreSendSession() {
        guard let session = walletStore.sendSession(
            id: sessionID,
            profileID: profile.id
        ) else { return }
        destinationAddress = session.destination
        amountText = session.amountText
        if let primaryRecipient = session.recipients.first {
            destinationAddress = primaryRecipient.address
            amountText = primaryRecipient.amountText
        }
        additionalRecipients = Array(session.recipients.dropFirst())
        sendMax = session.sendMax
        selectedFee = SendFeeChoice(rawValue: session.feeChoice) ?? .normal
        customFeeText = session.customFeeText
        changeOutputs = session.changeOutputs
        usesManualChangeAllocation = transactionType == .standard
            ? session.usesManualChangeAllocation
            : true
        if !destinationAddress.isEmpty {
            validateDestinationAddress(destinationAddress)
        }
    }

    private func persistSendSession() {
        guard var session = walletStore.sendSession(
            id: sessionID,
            profileID: profile.id
        ) else { return }
        session.destination = destinationAddress
        session.amountText = amountText
        if session.recipients.isEmpty {
            session.recipients = [SendRecipientDraft(
                address: destinationAddress,
                amountText: amountText
            )]
        } else {
            session.recipients[0].address = destinationAddress
            session.recipients[0].amountText = amountText
        }
        session.recipients = [session.recipients[0]] + additionalRecipients
        session.sendMax = sendMax
        session.feeChoice = selectedFee.rawValue
        session.customFeeText = customFeeText
        session.changeOutputs = changeOutputs
        session.usesManualChangeAllocation = usesManualChangeAllocation
        walletStore.updateSendSession(session)
    }

    private func cancelTransactionAndReturnToWallet() {
        addressValidationTask?.cancel()
        walletStore.cancelSendSession(id: sessionID, profileID: profile.id)
        coinControlStore.clearSelection()
        unsignedPSKB = nil
        verifiedReview = nil
        destinationAddress = ""
        amountText = ""
        customFeeText = ""
        showingSendFlow = false
    }

    private var changeAddressCard: some View {
        Button {
            showingChangeAddressPicker = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(changeOutputs.count == 1 ? "Change Address" : "Change Addresses")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(changeOutputs.isEmpty
                         ? "Select a fresh change address"
                         : changeOutputs.count == 1
                            ? changeOutputs[0].address
                            : "\(changeOutputs.count) selected")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(sendMax)
    }

    private func countedOutputsMatch(
        _ outputs: [PSKTSummaryOutput],
        recipients: [SendDraftRecipient],
        changeOutputs: [PlannedChangeOutput]
    ) -> Bool {
        var expected: [String: Int] = [:]
        for recipient in recipients {
            expected["\(recipient.address.lowercased())|\(recipient.amountSompi)", default: 0] += 1
        }
        for output in changeOutputs {
            expected["\(output.id)|\(output.amountSompi)", default: 0] += 1
        }
        var actual: [String: Int] = [:]
        for output in outputs {
            guard let address = output.address?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                  let amount = output.amountSompi
            else { return false }
            actual["\(address)|\(amount)", default: 0] += 1
        }
        return actual == expected
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Destination")
                    .font(.headline)

                Spacer()

                if transactionType != .decoy,
                   additionalRecipients.count < 3 {
                    Button {
                        additionalRecipients.append(SendRecipientDraft())
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                    }
                    .tint(accentColor)
                    .accessibilityLabel("Add destination")
                }

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
            VStack(alignment: .leading, spacing: 4) {
                Text("Amount")
                    .font(.headline)

                Text(selectedTotalSummaryText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            HStack(spacing: 10) {
                TextField("0", text: amountEntryText)
                    .keyboardType(.decimalPad)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .disabled(sendMax)

                Button {
                    toggleAmountEntryCurrency()
                } label: {
                    HStack(spacing: 7) {
                        Text(amountEntryUsesUSD ? "USD" : "KAS")
                            .font(.subheadline.weight(.semibold))

                        VStack(spacing: -3) {
                            Image(systemName: "arrow.left")
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 15, height: 20)
                        .symbolRenderingMode(.monochrome)
                    }
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(usdSpotPrice == nil)
                .accessibilityLabel(
                    amountEntryUsesUSD
                        ? "Amount entered in US dollars"
                        : "Amount entered in KAS"
                )
                .accessibilityHint("Double tap to switch between KAS and US dollars.")
            }
            .padding(12)
            .background(
                Color(.tertiarySystemGroupedBackground),
                in: RoundedRectangle(
                    cornerRadius: 12,
                    style: .continuous
                )
            )
            .sensoryFeedback(.selection, trigger: amountEntryUsesUSD)

            Toggle("Send Max", isOn: $sendMax)
                .font(.subheadline.weight(.semibold))
                .tint(accentColor)
                .disabled(
                    selectedTotalSompi == nil
                        || transactionType != .standard
                        || isRefreshingSendMaxFee
                )

            if !amountText.isEmpty && !amountLooksValid {
                Text(
                    "Amount plus fee must fit within the selected input total."
                )
                .font(.caption)
                .foregroundStyle(.red)
            }

            if transactionType != .standard {
                if isResolvingLivePlan {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Calculating exact transaction fee…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let livePlanError {
                    Text(livePlanError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
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

    private var amountEntryText: Binding<String> {
        Binding(
            get: {
                amountEntryUsesUSD ? usdAmountText : amountText
            },
            set: { newValue in
                if amountEntryUsesUSD {
                    usdAmountText = newValue
                    updateKASAmountFromUSD(newValue)
                } else {
                    amountText = newValue
                }
            }
        )
    }

    private var usdSpotPrice: Double? {
        guard let price = priceService.price(for: .usd),
              price.isFinite,
              price > 0 else { return nil }
        return price
    }

    private func toggleAmountEntryCurrency() {
        if amountEntryUsesUSD {
            amountEntryUsesUSD = false
            return
        }

        guard usdSpotPrice != nil else { return }
        syncUSDAmountFromKASIfNeeded()
        amountEntryUsesUSD = true
    }

    private func syncUSDAmountFromKASIfNeeded() {
        guard let price = usdSpotPrice else { return }
        guard let sompi = parseKasTextToSompi(amountText) else {
            usdAmountText = ""
            return
        }

        let kas = Double(sompi) / 100_000_000
        usdAmountText = formatUSDInput(kas * price)
    }

    private func updateKASAmountFromUSD(_ text: String) {
        guard let price = usdSpotPrice else { return }
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")

        guard !normalized.isEmpty else {
            amountText = ""
            return
        }

        guard let usd = Double(normalized),
              usd.isFinite,
              usd >= 0 else {
            amountText = ""
            return
        }

        let sompi = (usd / price * 100_000_000).rounded()
        guard sompi.isFinite,
              sompi >= 0,
              sompi < Double(UInt64.max) else {
            amountText = ""
            return
        }

        amountText = formatPlainKas(sompi: UInt64(sompi))
    }

    private func formatUSDInput(_ value: Double) -> String {
        value.formatted(
            .number
                .grouping(.never)
                .precision(.fractionLength(0...5))
        )
    }

    private func updateSendMaxAmount() {
        guard sendMax, let maximumSendSompi else { return }
        amountText = formatPlainKas(sompi: maximumSendSompi)
        syncUSDAmountFromKASIfNeeded()
    }

    @MainActor
    private func refreshFeeEstimateForSendMax() async {
        guard !isRefreshingSendMaxFee else { return }
        guard let activeProfile = walletStore.profiles.first(
            where: { $0.id == profile.id }
        ) else {
            return
        }

        isRefreshingSendMaxFee = true
        defer { isRefreshingSendMaxFee = false }

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
                        .focused($customFeeFieldFocused)
                        .font(
                            .subheadline
                                .weight(.semibold)
                                .monospacedDigit()
                        )

                    Text("KAS")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .id("custom-fee-field")
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
                    if result.valid {
                        scheduleLivePlanResolution()
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

    private var selectedTotalSummaryText: String {
        guard let selectedTotalSompi else {
            return "Available balance: Invalid"
        }
        if amountEntryUsesUSD,
           let price = usdSpotPrice {
            let kas = Double(selectedTotalSompi) / 100_000_000
            let usdText = (kas * price).formatted(
                .currency(code: "USD")
                    .precision(.fractionLength(2))
            )
            return "Available balance: \(usdText)"
        }
        return "Available balance: \(formatKas(sompi: selectedTotalSompi))"
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

private struct AdditionalRecipientCard: View {
    @Binding var recipient: SendRecipientDraft
    let onRemove: () -> Void
    let onValidationChange: (Bool) -> Void

    @EnvironmentObject private var engine: KasSignerEngine
    @State private var validation: AddressValidationResult?
    @State private var isValidating = false
    @State private var validationTask: Task<Void, Never>?

    private let accentColor = Color(red: 0.20, green: 0.62, blue: 0.57)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Additional Destination")
                    .font(.headline)
                Spacer()
                if isValidating {
                    ProgressView().controlSize(.small)
                } else if !recipient.address.isEmpty {
                    Image(systemName: validation?.valid == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(validation?.valid == true ? accentColor : .red)
                }
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                }
                .accessibilityLabel("Remove destination")
            }

            TextField("kaspa:...", text: $recipient.address, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.subheadline, design: .monospaced))
                .lineLimit(2...4)
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 10) {
                TextField("0", text: $recipient.amountText)
                    .keyboardType(.decimalPad)
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text("KAS")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

            if let validation, !recipient.address.isEmpty {
                Text(validation.valid ? "Valid Kaspa address." : (validation.reason ?? "Invalid Kaspa address."))
                    .font(.caption)
                    .foregroundStyle(validation.valid ? accentColor : .red)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
        .onChange(of: recipient.address) { _, address in validate(address) }
        .task { validate(recipient.address) }
        .onDisappear { validationTask?.cancel() }
    }

    private func validate(_ address: String) {
        validationTask?.cancel()
        validation = nil
        onValidationChange(false)
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isValidating = false
            return
        }
        isValidating = true
        validationTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                let result = try await engine.validateAddress(trimmed)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    validation = result
                    isValidating = false
                    onValidationChange(result.valid)
                    if result.valid, let normalized = result.normalized {
                        recipient.address = normalized
                    }
                }
            } catch {
                await MainActor.run {
                    validation = AddressValidationResult(valid: false, network: nil, normalized: nil, reason: error.localizedDescription)
                    isValidating = false
                    onValidationChange(false)
                }
            }
        }
    }
}

private struct VerifiedTransactionReview: Identifiable, Hashable {
    let id = UUID()
    let profileID: UUID
    let destination: String
    let amountSompi: UInt64
    let recipients: [SendDraftRecipient]
    let feeSompi: UInt64
    let changeSompi: UInt64
    let changeOutputs: [PlannedChangeOutput]
    let selectedInputCount: Int
    let selectedOutpoints: [String]
    let unsignedPSKB: String
    let verifiedDigest: String
    let selectedInputsVerified: Bool
    let destinationVerified: Bool
    let changeVerified: Bool
    let feeVerified: Bool

    var recipientTotalSompi: UInt64 {
        recipients.reduce(0) { $0 &+ $1.amountSompi }
    }

    static func == (
        lhs: VerifiedTransactionReview,
        rhs: VerifiedTransactionReview
    ) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
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
                "All destinations and amounts match",
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
    @EnvironmentObject private var priceService: PriceService

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
            ForEach(Array(review.recipients.enumerated()), id: \.offset) { index, recipient in
                addressCard(
                    title: review.recipients.count == 1
                        ? "Destination"
                        : "Destination \(index + 1)",
                    amountSompi: recipient.amountSompi,
                    address: recipient.address,
                    accessibilityLabel: "Copy destination \(index + 1)"
                )
            }
            ForEach(Array(review.changeOutputs.enumerated()), id: \.element.id) { index, output in
                addressCard(
                    title: review.changeOutputs.count == 1
                        ? "Change"
                        : "Change \(index + 1)",
                    amountSompi: output.amountSompi,
                    address: output.address,
                    accessibilityLabel: "Copy change address"
                )
            }
            inputsCard
        }
    }

    private var transactionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transaction")
                .font(.title3.weight(.semibold))

            valueRow("Amount", value: formatKas(review.recipientTotalSompi))
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

    private func addressCard(
        title: String,
        amountSompi: UInt64,
        address: String,
        accessibilityLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(title)
                    .font(.title3.weight(.semibold))

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(formatKas(amountSompi))
                        .font(.subheadline.weight(.semibold).monospacedDigit())

                    if let usdValue = formatUSD(amountSompi) {
                        Text(usdValue)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.trailing)
            }

            Button {
                PrivatePasteboard.copy(address)
                copyFeedbackCenter.showCopied(address)
            } label: {
                Text(address)
                    .font(.body.monospaced())
                    .multilineTextAlignment(.leading)
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
            .buttonStyle(SubtlePressButtonStyle())
            .accessibilityLabel(accessibilityLabel)
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

    private func formatUSD(_ sompi: UInt64) -> String? {
        guard let price = priceService.price(for: .usd),
              price.isFinite,
              price > 0 else { return nil }

        let kas = Double(sompi) / 100_000_000
        return (kas * price).formatted(
            .currency(code: "USD")
                .precision(.fractionLength(0...2))
        )
    }
}


struct VerifiedSignedPSKBGate {
    private(set) var payload: String?

    var isArmed: Bool {
        payload != nil
    }

    mutating func accept(_ verifiedPSKB: String) {
        payload = verifiedPSKB
    }

    mutating func clear() {
        payload = nil
    }
}

private struct VerifiedSigningPreparationView: View {
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var appLockService: AppLockService

    let review: VerifiedTransactionReview
    let onComplete: () -> Void

    @State private var qrFrames: [KasSeeQRFrame] = []
    @State private var frameIndex = 0
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var isPlaying = true
    @State private var showingSignedQRScanner = false
    @State private var decoderProgressCount = 0
    @State private var decoderProgressTotal = 0
    @State private var decoderBits: [Bool] = []
    @State private var signedPayload: String?
    @State private var originalRelayKSPT: String?
    @State private var signedBroadcastGate = VerifiedSignedPSKBGate()
    @State private var isAuthorizingBroadcast = false
    @State private var isBroadcastingSignedTransaction = false
    @State private var broadcastTransactionID: String?
    @State private var showingBroadcastSuccess = false
    @State private var showingBroadcastReview = false
    @State private var scanErrorMessage: String?
    @State private var isStartingScanner = false
    @State private var signedScanFeedback: QRScanFeedback = .idle
    @State private var lastScannedFrame: String?
    @State private var lastProgressCount = 0

    private var framePlaybackTaskID: String {
        "\(isPlaying)-\(frameIndex)-\(qrFrames.count)"
    }

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
        .task(id: framePlaybackTaskID) {
            guard isPlaying,
                  qrFrames.count > 1,
                  qrFrames.indices.contains(frameIndex)
            else { return }

            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }

            guard isPlaying,
                  qrFrames.count > 1,
                  qrFrames.indices.contains(frameIndex)
            else { return }
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
                            .padding(.vertical, 12)
                    } else {
                        Label(
                            "Scan Signed QR",
                            systemImage: "qrcode.viewfinder"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
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
        .padding(showingBroadcastReview ? 0 : 16)
        .background(
            showingBroadcastReview
                ? Color.clear
                : Color(.secondarySystemGroupedBackground),
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
        signedBroadcastGate.clear()
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
        if signedBroadcastGate.isArmed &&
            broadcastTransactionID == nil {
            Button {
                Task {
                    await broadcastSignedTransaction()
                }
            } label: {
                HStack(spacing: 8) {
                    if isAuthorizingBroadcast || isBroadcastingSignedTransaction {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }

                    Text(broadcastButtonTitle)
                    .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAuthorizingBroadcast || isBroadcastingSignedTransaction)
        }
    }

    private var broadcastButtonTitle: String {
        if isAuthorizingBroadcast {
            return "Authenticating…"
        }
        if isBroadcastingSignedTransaction {
            return "Broadcasting…"
        }
        return "Broadcast Transaction"
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
            force: true,
            includeTransactionHistory: false
        )
        await syncService.reconcilePendingTransactions(
            profile: walletStore.profiles.first(where: { $0.id == profile.id }) ?? profile,
            walletStore: walletStore
        )
    }

    @MainActor
    private func broadcastSignedTransaction() async {
        guard let verifiedSignedPSKBForBroadcast = signedBroadcastGate.payload,
              !isAuthorizingBroadcast,
              !isBroadcastingSignedTransaction
        else {
            return
        }

        isAuthorizingBroadcast = true
        scanErrorMessage = nil
        let isAuthorized = await appLockService.authorizeTransactionBroadcast()
        isAuthorizingBroadcast = false

        guard isAuthorized else {
            if let authenticationError = appLockService.authenticationError {
                scanErrorMessage = "Authentication failed: \(authenticationError)"
            }
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
            let transactionID = try await engine.finalizeAndBroadcastPSKB(
                verifiedSignedPSKBForBroadcast,
                wsURL: wsURL
            )
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            let recorded = walletStore.recordBroadcastedTransaction(
                profileID: review.profileID,
                transactionID: transactionID,
                destination: review.recipients.count == 1
                    ? review.destination
                    : "\(review.recipients.count) Destinations",
                amountSompi: review.recipientTotalSompi,
                feeSompi: review.feeSompi,
                committedChangeIndices: review.changeOutputs.map(\.addressIndex)
            )
            guard recorded else {
                scanErrorMessage =
                    "The transaction was broadcast, but its local change-address state could not be updated. Refresh the wallet before sending again."
                return
            }
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
                signedBroadcastGate.clear()
                let signedKSPT = completedPayload
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

                let currentDigest = SHA256.hash(
                    data: Data(review.unsignedPSKB.utf8)
                )
                .map { String(format: "%02x", $0) }
                .joined()
                guard currentDigest == review.verifiedDigest else {
                    throw SendVerificationError.integrityCheckFailed
                }
                guard let originalRelayKSPT else {
                    throw SendVerificationError.missingOriginalRelay
                }

                let mergedPSKB = try await engine.verifyAndMergeSignedKSPTIntoPSKB(
                    signedKSPTHex: signedKSPT,
                    originalRelayKSPTHex: originalRelayKSPT,
                    originalPSKBHex: review.unsignedPSKB
                )

                try await verifyFinalAddresses(in: mergedPSKB)

                signedBroadcastGate.accept(mergedPSKB)
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
            signedBroadcastGate.clear()
            signedPayload = nil
            signedScanFeedback = .rejected
            scanErrorMessage = error.localizedDescription


            // Permit the same displayed M5 frame to be retried after an error.
            lastScannedFrame = nil
        }
    }

    @MainActor
    private func verifyFinalAddresses(in mergedPSKB: String) async throws {
        let summary = try await engine.summarizePSKB(mergedPSKB)
        guard let outputs = summary.outputs else {
            throw SendVerificationError.missingOutputs
        }

        var expected: [String: Int] = [:]
        for recipient in review.recipients {
            let address = recipient.address
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            expected["\(address)|\(recipient.amountSompi)", default: 0] += 1
        }
        for output in review.changeOutputs {
            expected["\(output.id)|\(output.amountSompi)", default: 0] += 1
        }
        var actual: [String: Int] = [:]
        for output in outputs {
            guard let address = output.address?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                  let amount = output.amountSompi
            else { throw SendVerificationError.invalidOutput }
            actual["\(address)|\(amount)", default: 0] += 1
        }
        let amountAndChange = review.recipientTotalSompi.addingReportingOverflow(review.changeSompi)
        let expectedInput = amountAndChange.partialValue.addingReportingOverflow(review.feeSompi)
        guard !amountAndChange.overflow,
              !expectedInput.overflow,
              actual == expected,
              outputs.count == review.recipients.count + review.changeOutputs.count,
              summary.totalInputSompi == expectedInput.partialValue,
              summary.totalOutputSompi == amountAndChange.partialValue,
              summary.feeSompi == review.feeSompi
        else {
            throw SendVerificationError.changeAddressMismatch
        }
    }

    @MainActor
    private func loadQRFrames() async {
        loading = true
        errorMessage = nil
        frameIndex = 0
        isPlaying = true

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
            originalRelayKSPT = compactKSPT

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
            originalRelayKSPT = nil
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
                    Text("Transaction Broadcasted")
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
    case allocationNeedsValidAmount
    case customFeeMismatch
    case changeAddressUnavailable
    case changeAddressMismatch
    case changeAmountMismatch
    case walletStateChanged
    case integrityCheckFailed
    case missingOriginalRelay

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
        case .allocationNeedsValidAmount:
            return "Enter a valid destination and amount before allocating change."
        case .customFeeMismatch:
            return "The fee encoded in the transaction does not match the custom fee you entered."
        case .changeAddressUnavailable:
            return "No unused change address is available. Refresh the wallet and try again."
        case .changeAddressMismatch:
            return "The transaction does not match the approved change outputs."
        case .changeAmountMismatch:
            return "Change amounts do not equal available change."
        case .walletStateChanged:
            return "The wallet address state changed. Return to the wallet and try again."
        case .integrityCheckFailed:
            return "The verified transaction changed before the signed response was accepted."
        case .missingOriginalRelay:
            return "The approved signing request is no longer available. Generate it again."
        }
    }
}

private struct ChangeAddressPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var walletStore: WalletStore
    let profileID: UUID
    let transactionType: SendTransactionType
    let availableChangeSompi: UInt64
    @Binding var selectedOutputs: [PlannedChangeOutput]
    let resolvePlan: ([PlannedChangeOutput]) async throws -> (
        outputs: [PlannedChangeOutput],
        plan: ChangeFeePlan
    )
    let preparePrivacyPlan: ([PlannedChangeOutput]) async throws -> (
        outputs: [PlannedChangeOutput],
        plan: ChangeFeePlan
    )
    let completeStandardSelection: ([PlannedChangeOutput]) -> Void
    let completePlan: ([PlannedChangeOutput], ChangeFeePlan) -> Void
    @State private var draftOutputs: [PlannedChangeOutput] = []
    @State private var isGenerating = false
    @State private var generationError: String?
    @State private var selectionError: String?
    @State private var showingAllocation = false
    @State private var isResolvingSelection = false
    @State private var preparedPrivacyPlan: ChangeFeePlan?

    init(
        profileID: UUID,
        transactionType: SendTransactionType,
        availableChangeSompi: UInt64,
        selectedOutputs: Binding<[PlannedChangeOutput]>,
        resolvePlan: @escaping ([PlannedChangeOutput]) async throws -> (
            outputs: [PlannedChangeOutput],
            plan: ChangeFeePlan
        ),
        preparePrivacyPlan: @escaping ([PlannedChangeOutput]) async throws -> (
            outputs: [PlannedChangeOutput],
            plan: ChangeFeePlan
        ),
        completeStandardSelection: @escaping ([PlannedChangeOutput]) -> Void,
        completePlan: @escaping ([PlannedChangeOutput], ChangeFeePlan) -> Void
    ) {
        self.profileID = profileID
        self.transactionType = transactionType
        self.availableChangeSompi = availableChangeSompi
        _selectedOutputs = selectedOutputs
        self.resolvePlan = resolvePlan
        self.preparePrivacyPlan = preparePrivacyPlan
        self.completeStandardSelection = completeStandardSelection
        self.completePlan = completePlan
        _draftOutputs = State(initialValue: selectedOutputs.wrappedValue)
    }

    private var profile: WalletProfile? {
        walletStore.profiles.first { $0.id == profileID }
    }

    private var minimumSelectionCount: Int {
        switch transactionType {
        case .standard: 1
        case .privacyFocused: 2
        case .decoy: 4
        }
    }

    private var maximumSelectionCount: Int {
        switch transactionType {
        case .standard: 1
        case .privacyFocused: 4
        case .decoy: 4
        }
    }

    private var selectionCountIsValid: Bool {
        (minimumSelectionCount...maximumSelectionCount).contains(draftOutputs.count)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let profile {
                        addressRows(profile)
                        generateButton(profile)
                    }
                }
                .navigationTitle("Change Addresses")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    let target = draftOutputs.first?.addressIndex
                        ?? profile?.nextChangeIndex
                    guard let target else { return }
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            if transactionType == .standard {
                                selectedOutputs = draftOutputs
                                completeStandardSelection(draftOutputs)
                                dismiss()
                            } else if transactionType == .decoy {
                                Task { await completeDecoySelection() }
                            } else {
                                Task { await completePrivacySelection() }
                            }
                        }
                        .disabled(!selectionCountIsValid || isResolvingSelection)
                    }
                }
            }
            .navigationDestination(isPresented: $showingAllocation) {
                if let preparedPrivacyPlan {
                    ChangeAllocationView(
                        availableChangeSompi: preparedPrivacyPlan.availableChangeSompi,
                        outputs: $draftOutputs,
                        resolvePlan: resolvePlan
                    ) { resolvedOutputs, plan in
                        draftOutputs = resolvedOutputs
                        selectedOutputs = resolvedOutputs
                        completePlan(resolvedOutputs, plan)
                        dismiss()
                    }
                }
            }
            .alert("Change addresses", isPresented: Binding(
                get: { generationError != nil || selectionError != nil },
                set: {
                    if !$0 {
                        generationError = nil
                        selectionError = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(generationError ?? selectionError ?? "Unknown error")
            }
        }
    }

    @ViewBuilder
    private func addressRows(_ profile: WalletProfile) -> some View {
        ForEach(profile.changeAddresses.indices, id: \.self) { index in
            let address = profile.changeAddresses[index]
            ChangeAddressSelectionRow(
                index: index,
                address: address,
                isSelected: draftOutputs.contains { $0.addressIndex == index },
                isLocallyUsed: walletStore.isChangeAddressLocallyUsed(address, profileID: profileID)
            ) {
                toggle(index: index, address: address)
            }
            .id(index)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    private func generateButton(_ profile: WalletProfile) -> some View {
        Button {
            Task { await generateAddress(from: profile) }
        } label: {
            if isGenerating { ProgressView() }
            else { Label("Generate New Change Address", systemImage: "plus") }
        }
        .disabled(isGenerating)
    }

    private func toggle(index: Int, address: String) {
        if transactionType == .standard {
            guard !draftOutputs.contains(where: { $0.addressIndex == index }) else {
                return
            }
            draftOutputs = [
                PlannedChangeOutput(
                    addressIndex: index,
                    address: address,
                    amountSompi: 0
                )
            ]
            return
        }

        if let selectedIndex = draftOutputs.firstIndex(where: { $0.addressIndex == index }) {
            draftOutputs.remove(at: selectedIndex)
            return
        }
        guard draftOutputs.count < maximumSelectionCount else {
            selectionError = maximumSelectionCount == 1
                ? "Standard Send uses one change address. Deselect it before choosing another."
                : "This transaction type uses no more than \(maximumSelectionCount) change addresses."
            return
        }
        draftOutputs.append(
            PlannedChangeOutput(addressIndex: index, address: address, amountSompi: 0)
        )
    }

    @MainActor
    private func completeDecoySelection() async {
        guard !isResolvingSelection else { return }
        isResolvingSelection = true
        defer { isResolvingSelection = false }
        do {
            let resolved = try await resolvePlan(draftOutputs)
            draftOutputs = resolved.outputs
            selectedOutputs = resolved.outputs
            completePlan(resolved.outputs, resolved.plan)
            dismiss()
        } catch {
            selectionError = error.localizedDescription
        }
    }

    @MainActor
    private func completePrivacySelection() async {
        guard !isResolvingSelection else { return }
        isResolvingSelection = true
        defer { isResolvingSelection = false }
        do {
            let prepared = try await preparePrivacyPlan(draftOutputs)
            draftOutputs = prepared.outputs
            preparedPrivacyPlan = prepared.plan
            showingAllocation = true
        } catch {
            selectionError = error.localizedDescription
        }
    }

    private func generateAddress(from profile: WalletProfile) async {
        isGenerating = true
        defer { isGenerating = false }
        do {
            var updated = profile
            let derived = try await engine.extendAddresses(
                for: updated,
                receiveCount: 0,
                changeCount: 1
            )
            updated.receiveAddresses = derived.receiveAddresses
            updated.changeAddresses = derived.changeAddresses
            walletStore.update(updated)
        } catch {
            generationError = error.localizedDescription
        }
    }
}

private struct ChangeAllocationView: View {
    @Binding var outputs: [PlannedChangeOutput]
    let resolvePlan: ([PlannedChangeOutput]) async throws -> (
        outputs: [PlannedChangeOutput],
        plan: ChangeFeePlan
    )
    let complete: ([PlannedChangeOutput], ChangeFeePlan) -> Void

    @EnvironmentObject private var priceService: PriceService

    @State private var availableChangeSompi: UInt64
    @State private var resolvedFeeSompi: UInt64?
    @State private var allocationError: String?
    @State private var isResolvingFee = false
    @State private var amountTexts: [String]
    private let minimumOutputSompi: UInt64 = 66_900

    init(
        availableChangeSompi: UInt64,
        outputs: Binding<[PlannedChangeOutput]>,
        resolvePlan: @escaping ([PlannedChangeOutput]) async throws -> (
            outputs: [PlannedChangeOutput],
            plan: ChangeFeePlan
        ),
        complete: @escaping ([PlannedChangeOutput], ChangeFeePlan) -> Void
    ) {
        _availableChangeSompi = State(initialValue: availableChangeSompi)
        _outputs = outputs
        self.resolvePlan = resolvePlan
        self.complete = complete
        _amountTexts = State(
            initialValue: outputs.wrappedValue.map {
                Self.formatAmountForField($0.amountSompi)
            }
        )
    }

    var body: some View {
        List {
            Section {
                ForEach(outputs.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        outputTitle(outputs[index])
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            TextField("0", text: amountBinding(at: index))
                                .keyboardType(.decimalPad)
                                .font(.body.monospacedDigit())
                                .frame(
                                    width: amountFieldWidth(at: index),
                                    alignment: .leading
                                )

                            Text("KAS")
                                .font(.body)

                            Spacer(minLength: 0)
                        }

                        if let usdValue = formatUSD(outputs[index].amountSompi) {
                            Text(usdValue)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }

            Section {
                valueRow("Available", value: formatKas(availableChangeSompi))
                if let resolvedFeeSompi {
                    valueRow("Fee", value: formatKas(resolvedFeeSompi))
                }
                valueRow("Allocated", value: allocatedSompi.map(formatKas) ?? "Invalid")
                valueRow(
                    "Remaining",
                    value: remainingText,
                    valueColor: isValidAllocation ? .secondary : .red
                )
            }

            Section {
                Button("Balanced Split") {
                    Task { await balanceOutputs() }
                }
                .disabled(availableChangeSompi == 0 || isResolvingFee)
                Button("Reset", role: .destructive) { resetAmounts() }
                    .disabled(isResolvingFee)
            }
        }
        .navigationTitle("Allocation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    Task { await finish() }
                }
                .disabled(!canFinish || isResolvingFee)
            }
        }
        .alert("Allocation", isPresented: Binding(
            get: { allocationError != nil },
            set: { if !$0 { allocationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(allocationError ?? "Unknown error")
        }
    }

    private func outputTitle(_ output: PlannedChangeOutput) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Change Address #\(output.addressIndex + 1)")
                .foregroundStyle(.primary)
            Text(output.address)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueRow(
        _ title: String,
        value: String,
        valueColor: Color = .secondary
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(valueColor)
        }
    }

    private var allocatedSompi: UInt64? {
        outputs.reduce(into: UInt64?.some(0)) { total, output in
            guard let current = total else { return }
            let addition = current.addingReportingOverflow(output.amountSompi)
            total = addition.overflow ? nil : addition.partialValue
        }
    }

    private var isValidAllocation: Bool {
        guard availableChangeSompi > 0,
              (2...ChangeOutputPlanner.maximumOutputCount).contains(outputs.count),
              outputs.count <= ChangeOutputPlanner.maximumOutputCount,
              let allocatedSompi,
              allocatedSompi == availableChangeSompi
        else { return false }
        return outputs.allSatisfy { $0.amountSompi >= minimumOutputSompi }
    }

    private var canFinish: Bool {
        return isValidAllocation
    }

    private var remainingText: String {
        guard let allocatedSompi else { return "Invalid" }
        if allocatedSompi > availableChangeSompi {
            return "−\(formatKas(allocatedSompi - availableChangeSompi))"
        }
        return formatKas(availableChangeSompi - allocatedSompi)
    }

    private func amountBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                amountTexts.indices.contains(index) ? amountTexts[index] : ""
            },
            set: { text in
                guard amountTexts.indices.contains(index),
                      outputs.indices.contains(index) else { return }
                amountTexts[index] = text
                outputs[index].amountSompi = parseAmount(text) ?? 0
            }
        )
    }

    private func amountFieldWidth(at index: Int) -> CGFloat {
        let text = amountTexts.indices.contains(index) ? amountTexts[index] : ""
        let characterCount = max(text.count, 1)
        return min(max(CGFloat(characterCount) * 10.5 + 6, 24), 230)
    }

    private func resetAmounts() {
        resolvedFeeSompi = nil
        for index in outputs.indices {
            outputs[index].amountSompi = 0
            if amountTexts.indices.contains(index) {
                amountTexts[index] = ""
            }
        }
    }

    @MainActor
    private func balanceOutputs() async {
        guard !isResolvingFee else { return }
        isResolvingFee = true
        defer { isResolvingFee = false }
        do {
            let split = try ChangeOutputPlanner.autoSplit(
                availableChangeSompi: availableChangeSompi,
                selectedOutputs: outputs,
                minimumOutputSompi: minimumOutputSompi
            )
            let resolved = try await resolvePlan(split)
            updateAllocation(from: resolved)
        } catch {
            allocationError = error.localizedDescription
        }
    }

    @MainActor
    private func finish() async {
        guard !isResolvingFee else { return }
        isResolvingFee = true
        defer { isResolvingFee = false }
        do {
            let resolved = try await resolvePlan(outputs)
            guard resolved.outputs == outputs,
                  resolved.plan.availableChangeSompi == availableChangeSompi else {
                updateAllocation(from: resolved)
                allocationError = "The fee was refreshed and the available change changed. Review the updated amounts, then tap Done again."
                return
            }
            complete(resolved.outputs, resolved.plan)
        } catch {
            allocationError = error.localizedDescription
        }
    }

    private func updateAllocation(
        from resolved: (outputs: [PlannedChangeOutput], plan: ChangeFeePlan)
    ) {
        outputs = resolved.outputs
        amountTexts = resolved.outputs.map {
            Self.formatAmountForField($0.amountSompi)
        }
        availableChangeSompi = resolved.plan.availableChangeSompi
        resolvedFeeSompi = resolved.plan.feeSompi
    }

    private static func formatAmountForField(_ sompi: UInt64) -> String {
        let whole = sompi / 100_000_000
        let fractional = sompi % 100_000_000
        guard fractional != 0 else { return String(whole) }
        let fractionText = String(format: "%08llu", fractional)
            .replacingOccurrences(
                of: "0+$",
                with: "",
                options: .regularExpression
            )
        return "\(whole).\(fractionText)"
    }

    private func parseAmount(_ text: String) -> UInt64? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(
            separator: ".", omittingEmptySubsequences: false
        )
        guard parts.count <= 2,
              let whole = UInt64(parts.first.map(String.init) ?? "0")
        else { return nil }
        let fractionText = parts.count == 2 ? String(parts[1]) : ""
        guard fractionText.count <= 8,
              fractionText.allSatisfy(\.isNumber),
              let fraction = UInt64(fractionText.padding(toLength: 8, withPad: "0", startingAt: 0))
        else { return nil }
        let scaled = whole.multipliedReportingOverflow(by: 100_000_000)
        guard !scaled.overflow else { return nil }
        let total = scaled.partialValue.addingReportingOverflow(fraction)
        return total.overflow ? nil : total.partialValue
    }

    private func formatKas(_ sompi: UInt64) -> String {
        "\(formatPlainKas(sompi)) KAS"
    }

    private func formatUSD(_ sompi: UInt64) -> String? {
        guard let price = priceService.price(for: .usd),
              price.isFinite,
              price > 0 else { return nil }

        let kas = Double(sompi) / 100_000_000
        return (kas * price).formatted(
            .currency(code: "USD")
                .precision(.fractionLength(0...2))
        )
    }

    private func formatPlainKas(_ sompi: UInt64) -> String {
        let whole = sompi / 100_000_000
        let fractional = sompi % 100_000_000
        guard fractional != 0 else { return String(whole) }
        return "\(whole).\(String(format: "%08llu", fractional).replacingOccurrences(of: "0+$", with: "", options: .regularExpression))"
    }
}

private struct ChangeAddressSelectionRow: View {
    let index: Int
    let address: String
    let isSelected: Bool
    let isLocallyUsed: Bool
    let select: () -> Void
    @State private var status: AddressUsageStatus = .checking
    private let accentColor = Color(red: 0.20, green: 0.62, blue: 0.57)

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Change Address #\(index + 1)")
                        .foregroundStyle(.primary)
                    Text(address)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                statusView
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(
                        isSelected
                            ? accentColor.opacity(0.78)
                            : Color.primary.opacity(0.03),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(status == .checking || status == .unavailable)
        .task(id: address) {
            guard !isLocallyUsed else {
                status = .used
                return
            }
            do {
                status = try await AddressUsageChecker.shared.status(for: address)
            } catch {
                status = .unavailable
            }
        }
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .checking: ProgressView().controlSize(.mini)
        case .fresh: Text("Fresh").foregroundStyle(.green)
        case .used: Text("Used").foregroundStyle(.orange)
        case .unavailable: Text("Unavailable").foregroundStyle(.secondary)
        }
    }
}

private enum SendFeeChoice: String, CaseIterable, Identifiable {
    case normal
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal:
            return "Normal"
        case .custom:
            return "Custom"
        }
    }

    var detail: String {
        switch self {
        case .normal:
            return "Balanced network fee for typical transactions."
        case .custom:
            return "Enter a custom fee in KAS."
        }
    }
}
