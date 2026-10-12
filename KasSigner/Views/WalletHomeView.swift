import SwiftUI
import UIKit
import CryptoKit

private extension Notification.Name {
    static let protectedVaultFundingCompleted = Notification.Name(
        "org.kassigner.protectedVaultFundingCompleted"
    )
}

private struct ProtectedVaultAddressDraft: Identifiable {
    let id = UUID()
    var address = ""
    var validation: AddressValidationResult?
    var isValidating = false

    init(address: String = "") {
        self.address = address
    }
}

private struct ProtectedVaultAddressDisplayCard: View {
    let title: String
    let address: String
    var embedded = false
    var compact = false

    @EnvironmentObject private var copyFeedbackCenter: CopyFeedbackCenter

    var body: some View {
        if compact {
            Button {
                PrivatePasteboard.copy(address)
                copyFeedbackCenter.showCopied(address)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)

                    Text(address)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            .buttonStyle(SubtlePressButtonStyle())
            .accessibilityLabel("Copy \(title)")
        } else {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline.weight(.semibold))

            Button {
                PrivatePasteboard.copy(address)
                copyFeedbackCenter.showCopied(address)
            } label: {
                Text(address)
                    .font(.body.monospaced().weight(.regular))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        Color(.tertiarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                    }
            }
            .buttonStyle(SubtlePressButtonStyle())
            .accessibilityLabel("Copy \(title)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(embedded ? 0 : 16)
        .background(embedded ? Color.clear : Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }
}

private struct ProtectedVaultInfoCard: View {
    let message: String
    let symbol: String

    private let accent = Color(red: 0.20, green: 0.62, blue: 0.57)

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 24)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProtectedVaultActionButtonModifier: ViewModifier {
    let isProtectedVault: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isProtectedVault {
            content
                .buttonStyle(ProtectedVaultButtonStyle())
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct ProtectedVaultButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private let accent = Color(red: 0.20, green: 0.62, blue: 0.57)
    private let darkBackground = Color(red: 0.04, green: 0.18, blue: 0.16)
    private let lightBackground = Color(red: 0.08, green: 0.42, blue: 0.38)
    private let lightPressedBackground = Color(red: 0.06, green: 0.34, blue: 0.31)

    func makeBody(configuration: Configuration) -> some View {
        let isLight = colorScheme == .light
        let background = isLight
            ? (isEnabled
                ? (configuration.isPressed ? lightPressedBackground : lightBackground)
                : Color.secondary.opacity(0.18))
            : darkBackground.opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
        let labelColor = isLight
            ? (isEnabled ? Color.white : Color.secondary)
            : accent.opacity(isEnabled ? 1 : 0.45)

        configuration.label
            .font(.headline)
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 60)
            .background(
                background,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct ProtectedVaultSecurityCheck: Identifiable {
    let title: String
    let passed: Bool?

    var id: String { title }
}

private struct ProtectedVaultSecurityChecksCard: View {
    let checks: [ProtectedVaultSecurityCheck]
    var showsTitle = true

    private let accentColor = Color(red: 0.20, green: 0.62, blue: 0.57)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTitle {
                Text("Security Checks")
                    .font(.title3.weight(.semibold))
            }

            ForEach(Array(checks.enumerated()), id: \.offset) { index, check in
                if index > 0 {
                    Divider()
                }
                HStack(alignment: .top, spacing: 12) {
                    statusIcon(for: check.passed)
                        .frame(width: 20, height: 20)
                    Text(check.title)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
    }

    @ViewBuilder
    private func statusIcon(for passed: Bool?) -> some View {
        if let passed {
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(passed ? accentColor : .red)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}

private struct ProtectedVaultRuleSelection {
    typealias RecoveryPath = ProtectedVault.RecoveryPath

    var approvedAddressCount = 1
    var approvedAddresses = (0..<1).map { _ in ProtectedVaultAddressDraft() }
    var fundingUTXOs: [WalletUTXO] = []
    var recoveryAddress = ProtectedVaultAddressDraft()
    var delayDays = 30
    var delayHours = 0
    var delayMinutes = 0
    var recoveryPath: RecoveryPath = .emergencyAnytime
}

private func protectedVaultRuleSelection(from draft: ProtectedVaultSetupDraft) -> ProtectedVaultRuleSelection {
    let count = min(max(draft.approvedAddressCount, 1), 5)
    var approvedAddresses = draft.approvedAddresses.prefix(count).map(ProtectedVaultAddressDraft.init(address:))
    while approvedAddresses.count < count {
        approvedAddresses.append(ProtectedVaultAddressDraft())
    }
    return ProtectedVaultRuleSelection(
        approvedAddressCount: count,
        approvedAddresses: approvedAddresses,
        fundingUTXOs: [],
        recoveryAddress: ProtectedVaultAddressDraft(address: draft.recoveryAddress),
        delayDays: draft.delayDays,
        delayHours: draft.delayHours,
        delayMinutes: draft.delayMinutes,
        recoveryPath: draft.recoveryPath
    )
}

private struct ProtectedVaultFundingFeeSelection: Equatable {
    var choice: VaultFundingFeeChoice = .normal
    var customFeeText = ""
}

enum SendTransactionType: String, CaseIterable, Identifiable, Codable, Hashable {
    case standard
    case privacyFocused
    case decoy

    var id: Self { self }
}

private struct ProtectedVaultDraftExitPrompt: ViewModifier {
    @Binding var isPresented: Bool
    let draftID: UUID?
    let makeDraft: () -> ProtectedVaultSetupDraft

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var protectedVaultStore: ProtectedVaultStore

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if draftID == nil {
                            dismiss()
                        } else {
                            isPresented = true
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
            }
            .alert("Leave Vault Setup?", isPresented: $isPresented) {
                Button("Save as Draft") {
                    protectedVaultStore.saveSetupDraft(makeDraft())
                    dismiss()
                }
                Button("Cancel Draft", role: .destructive) {
                    if let draftID {
                        protectedVaultStore.removeSetupDraft(id: draftID)
                    }
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) { }
            } message: {
                Text("Save your vault setup to continue later, or cancel and remove this draft.")
            }
    }
}

struct WalletHomeView: View {
    private struct VaultBroadcastReceipt: Identifiable {
        let id = UUID()
        let vaultID: UUID
        let transactionID: String
        let localRecordWarning: String?
    }

    private enum WalletHomeAlert {
        case timeLockedPlaceholder
        case mainnetProgrammableUTXO
        case vaultRecordWarning(String)

        var title: String {
            switch self {
            case .timeLockedPlaceholder:
                return "Not Built Yet"
            case .mainnetProgrammableUTXO:
                return "Not Built on Mainnet"
            case .vaultRecordWarning:
                return "Local Record Needs Attention"
            }
        }

        var message: String {
            switch self {
            case .timeLockedPlaceholder:
                return "Time-Locked UTXOs are not built yet."
            case .mainnetProgrammableUTXO:
                return "Programmable UTXOs and Protected Vaults are not yet available on Mainnet."
            case .vaultRecordWarning(let warning):
                return warning
            }
        }
    }

    private enum VaultListItem: Identifiable {
        case vault(ProtectedVault)
        case setupDraft(ProtectedVaultSetupDraft)

        var id: UUID {
            switch self {
            case .vault(let vault): vault.id
            case .setupDraft(let draft): draft.id
            }
        }

        var createdAt: Date {
            switch self {
            case .vault(let vault): vault.createdAt
            case .setupDraft(let draft): draft.createdAt
            }
        }
    }

    private enum WalletRoute: Hashable {
        case receive(UUID)
        case programmableUTXOTypes(UUID)
        case protectedVaultRules(UUID)
        case protectedVaultSetupDraft(UUID)
        case protectedVaultDetail(UUID)
        case spendProtectedVault(UUID)
        case fundProtectedVault(UUID)
        case reviewVaultFunding(UUID)
    }

    @State private var navigationPath = NavigationPath()
    @State private var vaultBroadcastReceipt: VaultBroadcastReceipt?
    @State private var showingSendFlow = false
    @State private var protectedVaultFundingSelections: [UUID: [WalletUTXO]] = [:]
    @State private var protectedVaultFundingFeeSelections: [UUID: ProtectedVaultFundingFeeSelection] = [:]
    @State private var protectedVaultDraftsAwaitingFunding: [UUID: ProtectedVault] = [:]
    @Environment(\.legibilityWeight) private var legibilityWeight
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var priceService: PriceService
    @EnvironmentObject private var coinControlStore: UTXOCoinControlStore
    @EnvironmentObject private var copyFeedbackCenter: CopyFeedbackCenter
    @EnvironmentObject private var protectedVaultStore: ProtectedVaultStore
    @State private var showingAddWallet = false
    @State private var walletHomeAlert: WalletHomeAlert?
    @State private var showingSecondaryCurrency = false
    @State private var showingCurrencyConverter = false
    @State private var currencyConverterDetent: PresentationDetent = .fraction(0.54)
    @State private var contextVault: ProtectedVault?
    @State private var contextVaultRenameText = ""
    @State private var showingContextVaultRename = false
    @State private var showingContextVaultRemoval = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if let profile = walletStore.selectedProfile {
                    walletContent(profile)
                } else {
                    ContentUnavailableView {
                        Label("No Account", systemImage: "wallet.pass")
                    } description: {
                        Text(preferences.network == .testnet10
                             ? "Add a Testnet 10 account to receive TKAS."
                             : "Import the public wallet data exported by KasSigner. Private keys remain on the signing device.")
                    } actions: {
                        Button("Add Account") { showingAddWallet = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle(walletStore.selectedProfile == nil ? "KasSigner-iOS" : "")
            .navigationBarTitleDisplayMode(walletStore.selectedProfile == nil ? .large : .inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAddWallet = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddWallet) {
                AddWalletView()
            }
            .sheet(isPresented: $showingCurrencyConverter) {
                NavigationStack {
                    KaspaPriceDetail(
                        priceService: priceService,
                        preferences: preferences,
                        accentColor: Color(red: 0.20, green: 0.62, blue: 0.57),
                        showsOnlyConverter: true,
                        onConverterModeChange: { isManual in
                            withAnimation(.easeInOut(duration: 0.25)) {
                                currencyConverterDetent = isManual
                                    ? .fraction(0.62)
                                    : .fraction(0.54)
                            }
                        }
                    )
                }
                .presentationDetents(
                    [.fraction(0.54), .fraction(0.62)],
                    selection: $currencyConverterDetent
                )
                .presentationDragIndicator(.visible)
            }
            .alert(
                walletHomeAlert?.title ?? "",
                isPresented: Binding(
                    get: { walletHomeAlert != nil },
                    set: { if !$0 { walletHomeAlert = nil } }
                )
            ) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(walletHomeAlert?.message ?? "")
            }
            .task {
                async let walletRefresh: Void = refreshSelectedWallet(force: false)
                async let priceRefresh: Void = priceService.refresh(preferences: preferences)
                _ = await (walletRefresh, priceRefresh)
            }
            .navigationDestination(for: WalletRoute.self) { route in
                switch route {
                case .receive(let profileID):
                    if let profile = walletStore.profiles.first(where: { $0.id == profileID }) {
                        ReceiveView(profile: profile)
                    } else {
                        ContentUnavailableView(
                            "Account Unavailable",
                            systemImage: "wallet.pass",
                            description: Text("Return to the Wallet screen and select an account.")
                        )
                    }
                case .programmableUTXOTypes(let profileID):
                    if let profile = walletStore.profiles.first(where: { $0.id == profileID }) {
                        if profile.network == KaspaNetwork.testnet10.rawValue {
                            programmableUTXOTypeSelection(profile)
                        } else {
                            mainnetVaultUnavailableView
                        }
                    } else {
                        unavailableAccountView
                    }
                case .protectedVaultRules(let profileID):
                    if let profile = walletStore.profiles.first(where: { $0.id == profileID }) {
                        if profile.network == KaspaNetwork.testnet10.rawValue {
                            ProtectedVaultRulesView(profile: profile) { vault, selectedUTXOs, feeSelection in
                                protectedVaultFundingSelections[vault.id] = selectedUTXOs
                                protectedVaultFundingFeeSelections[vault.id] = feeSelection
                                protectedVaultDraftsAwaitingFunding[vault.id] = vault
                                navigationPath.append(WalletRoute.reviewVaultFunding(vault.id))
                            }
                        } else {
                            mainnetVaultUnavailableView
                        }
                    } else {
                        unavailableAccountView
                    }
                case .protectedVaultSetupDraft(let draftID):
                    if let draft = protectedVaultStore.setupDraft(id: draftID),
                       let profile = walletStore.profiles.first(where: { $0.id == draft.profileID }) {
                        if profile.network == KaspaNetwork.testnet10.rawValue {
                            ProtectedVaultSetupDraftResumeView(draft: draft, profile: profile) { vault, selectedUTXOs, feeSelection in
                                protectedVaultFundingSelections[vault.id] = selectedUTXOs
                                protectedVaultFundingFeeSelections[vault.id] = feeSelection
                                protectedVaultDraftsAwaitingFunding[vault.id] = vault
                                navigationPath.append(WalletRoute.reviewVaultFunding(vault.id))
                            }
                            .onAppear {
                                protectedVaultStore.recordOpened(id: draft.id, profileID: profile.id)
                            }
                        } else {
                            mainnetVaultUnavailableView
                        }
                    } else {
                        ContentUnavailableView("Draft Unavailable", systemImage: "doc.text.magnifyingglass")
                    }
                case .protectedVaultDetail(let vaultID):
                    if let vault = protectedVaultStore.vaults.first(where: { $0.id == vaultID }),
                       let profile = walletStore.profiles.first(where: { $0.id == vault.profileID }) {
                        if profile.network == KaspaNetwork.testnet10.rawValue {
                            Group {
                                if vault.status == .pendingWithdrawal {
                                    TestnetProtectedVaultSpendView(vaultID: vaultID) { transactionID, warning, startedDelay in
                                        if startedDelay {
                                            showDelayProgress(vaultID: vaultID, warning: warning)
                                        } else {
                                            presentVaultBroadcast(vaultID: vaultID, transactionID: transactionID, warning: warning)
                                        }
                                    }
                                } else {
                                    ProtectedVaultDetailView(vault: vault) {
                                        navigationPath.append(WalletRoute.fundProtectedVault(vaultID))
                                    } onSpend: {
                                        navigationPath.append(WalletRoute.spendProtectedVault(vaultID))
                                    }
                                }
                            }
                            .onAppear {
                                protectedVaultStore.recordOpened(id: vault.id, profileID: vault.profileID)
                            }
                        } else {
                            mainnetVaultUnavailableView
                        }
                    } else {
                        ContentUnavailableView("Vault Unavailable", systemImage: "lock.slash")
                    }
                case .spendProtectedVault(let vaultID):
                    if let vault = protectedVaultStore.vaults.first(where: { $0.id == vaultID }),
                       let profile = walletStore.profiles.first(where: { $0.id == vault.profileID }),
                       profile.network == KaspaNetwork.testnet10.rawValue {
                        TestnetProtectedVaultSpendView(vaultID: vaultID) { transactionID, warning, startedDelay in
                            if startedDelay {
                                showDelayProgress(vaultID: vaultID, warning: warning)
                            } else {
                                presentVaultBroadcast(vaultID: vaultID, transactionID: transactionID, warning: warning)
                            }
                        }
                    } else {
                        ContentUnavailableView("Vault Unavailable", systemImage: "lock.slash")
                    }
                case .fundProtectedVault(let vaultID):
                    if let vault = protectedVaultStore.vaults.first(where: { $0.id == vaultID }),
                       let profile = walletStore.profiles.first(where: { $0.id == vault.profileID }) {
                        if profile.network == KaspaNetwork.testnet10.rawValue {
                            if vault.status == .localDraft {
                                VaultFundingUTXOSelectionView(
                                    vault: vault,
                                    profile: profile,
                                    initialFeeSelection: protectedVaultFundingFeeSelections[vaultID]
                                        ?? ProtectedVaultFundingFeeSelection(),
                                    onBroadcast: { transactionID, warning in
                                        presentVaultBroadcast(vaultID: vaultID, transactionID: transactionID, warning: warning)
                                    }
                                )
                            } else {
                                FundProtectedVaultView(
                                    vault: vault,
                                    profile: profile,
                                    selectedUTXOs: protectedVaultFundingSelections[vaultID],
                                    initialFeeSelection: protectedVaultFundingFeeSelections[vaultID]
                                        ?? ProtectedVaultFundingFeeSelection(),
                                    onBroadcast: { transactionID, warning in
                                        presentVaultBroadcast(vaultID: vaultID, transactionID: transactionID, warning: warning)
                                    }
                                )
                            }
                        } else {
                            mainnetVaultUnavailableView
                        }
                    } else {
                        ContentUnavailableView("Vault Unavailable", systemImage: "lock.slash")
                    }
                case .reviewVaultFunding(let vaultID):
                    if let vault = protectedVaultStore.vaults.first(where: { $0.id == vaultID })
                        ?? protectedVaultDraftsAwaitingFunding[vaultID],
                       let profile = walletStore.profiles.first(where: { $0.id == vault.profileID }),
                       let selectedUTXOs = protectedVaultFundingSelections[vaultID] {
                        if profile.network == KaspaNetwork.testnet10.rawValue {
                            ReviewVaultFundingView(
                                vault: vault,
                                profile: profile,
                                selectedUTXOs: selectedUTXOs,
                                initialFeeSelection: protectedVaultFundingFeeSelections[vaultID]
                                    ?? ProtectedVaultFundingFeeSelection(),
                                onDraftBuilt: { builtVault in
                                    if !protectedVaultStore.vaults.contains(where: { $0.id == builtVault.id }) {
                                        guard let index = builtVault.ownerDerivationIndex,
                                              walletStore.reserveReceiveAddress(
                                                profileID: builtVault.profileID,
                                                index: index
                                              ) else { return false }
                                        guard protectedVaultStore.add(builtVault) else {
                                            return false
                                        }
                                    }
                                    protectedVaultStore.removeSetupDraft(id: builtVault.id)
                                    protectedVaultDraftsAwaitingFunding.removeValue(forKey: builtVault.id)
                                    return true
                                },
                                onBroadcast: { transactionID, warning in
                                    presentVaultBroadcast(vaultID: vaultID, transactionID: transactionID, warning: warning)
                                }
                            )
                        } else {
                            mainnetVaultUnavailableView
                        }
                    } else {
                        ContentUnavailableView(
                            "Funding Selection Unavailable",
                            systemImage: "square.stack.3d.up.slash",
                            description: Text("Return to the vault setup and select the funding UTXOs again.")
                        )
                    }
                }
            }
        }
        .fullScreenCover(item: $vaultBroadcastReceipt) { receipt in
            BroadcastSuccessView(
                transactionID: receipt.transactionID,
                localRecordWarning: receipt.localRecordWarning
            ) {
                vaultBroadcastReceipt = nil
                if hasSavedVaultTransaction(receipt.transactionID, vaultID: receipt.vaultID) {
                    navigateToVaultStatus(receipt.vaultID)
                }
            }
        }
        .onChange(of: walletStore.selectedProfileID) { oldValue, newValue in
            guard oldValue != newValue else { return }
            showingSendFlow = false
            navigationPath = NavigationPath()
        }
        .onReceive(NotificationCenter.default.publisher(for: .protectedVaultFundingCompleted)) { note in
            guard let vaultID = note.object as? UUID,
                  protectedVaultStore.vaults.contains(where: { $0.id == vaultID })
            else { return }
            navigateToVaultStatus(vaultID)
        }
    }

    private func presentVaultBroadcast(vaultID: UUID, transactionID: String, warning: String?) {
        vaultBroadcastReceipt = VaultBroadcastReceipt(
            vaultID: vaultID,
            transactionID: transactionID,
            localRecordWarning: warning
        )
    }

    private func hasSavedVaultTransaction(_ transactionID: String, vaultID: UUID) -> Bool {
        guard let vault = protectedVaultStore.vaults.first(where: { $0.id == vaultID }) else {
            return false
        }
        return vault.fundingTransactionID == transactionID
            || vault.approvedWithdrawalTransactionID == transactionID
            || vault.pendingWithdrawals.contains { $0.completionTransactionID == transactionID }
    }

    private func navigateToVaultStatus(_ vaultID: UUID) {
        guard let profileID = protectedVaultStore.vaults.first(where: { $0.id == vaultID })?.profileID
        else { return }
        navigationPath = NavigationPath()
        navigationPath.append(WalletRoute.programmableUTXOTypes(profileID))
        navigationPath.append(WalletRoute.protectedVaultDetail(vaultID))
    }

    private func showDelayProgress(vaultID: UUID, warning: String?) {
        navigateToVaultStatus(vaultID)
        if let warning {
            walletHomeAlert = .vaultRecordWarning(warning)
        }
    }

    private func walletContent(_ profile: WalletProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("KasSigner-iOS")
                    .foregroundStyle(.primary)
                    .font(.largeTitle.weight(.bold))
                    .offset(y: -12)
                    .padding(.bottom, -10)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Text(profile.name)
                            .font(.headline)

                        Spacer()
                    }

                    Button {
                        guard preferences.network == .mainnet else { return }
                        showingSecondaryCurrency.toggle()
                        if showingSecondaryCurrency {
                            Task {
                                await priceService.refresh(preferences: preferences)
                            }
                        }
                    } label: {
                        HStack(alignment: .center, spacing: 9) {
                            Text(balanceDisplayText)
                                .font(
                                    .system(
                                        size: 42,
                                        weight: legibilityWeight == .bold ? .medium : .semibold,
                                        design: .rounded
                                    )
                                )
                                .lineLimit(1)
                                .minimumScaleFactor(0.48)
                                .allowsTightening(true)
                                .layoutPriority(1)

                            if preferences.network == .mainnet && !balanceUnitText.isEmpty {
                                VStack(spacing: -3) {
                                    Image(systemName: "arrow.left")
                                    Image(systemName: "arrow.right")
                                }
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 22, height: 28)
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SubtlePressButtonStyle())
                    .contentTransition(.numericText())
                    .sensoryFeedback(.selection, trigger: showingSecondaryCurrency)
                    .accessibilityLabel(balanceAccessibilityLabel)
                    .accessibilityHint(preferences.network == .mainnet
                        ? "Double tap to switch between KAS and \(preferences.secondaryCurrency.displayName)."
                        : "Testnet 10 balance")
                    Button {
                        copyWalletHomeReceiveAddress(for: profile)
                    } label: {
                        Text(walletHomeReceiveAddress(for: profile))
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SubtlePressButtonStyle())
                    .disabled(profile.receiveAddresses.isEmpty)
                    .accessibilityHint("Copies the full receive address")
                }

                HStack(spacing: 10) {
                    NavigationLink(value: WalletRoute.receive(profile.id)) {
                        compactActionLabel("Receive", systemImage: "arrow.down")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showingSendFlow = true
                    } label: {
                        compactActionLabel("Send", systemImage: "arrow.up")
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    if profile.network == KaspaNetwork.testnet10.rawValue {
                        navigationPath.append(WalletRoute.programmableUTXOTypes(profile.id))
                    } else {
                        walletHomeAlert = .mainnetProgrammableUTXO
                    }
                } label: {
                    Text("Create Programmable UTXO")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.bordered)
                if preferences.network == .testnet10 && syncService.snapshot == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        if case .failed(let message) = syncService.state {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        } else if syncService.state == .syncing {
                            ProgressView("Connecting to Testnet 10…")
                        } else {
                            Text("Testnet 10 balance has not loaded yet.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button("Retry Testnet Sync") {
                            Task { await refreshSelectedWallet(force: true) }
                        }
                        .font(.footnote.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                if syncService.isCheckingHistoricalAddresses {
                    Label("Checking historical address coverage…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let coverageMessage = historicalCoverageMessage(for: profile) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Address coverage", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                        Text(coverageMessage)
                            .font(.footnote)
                        if syncService.historicalDiscoveryError != nil {
                            Button("Retry check") {
                                Task {
                                    await syncService.checkHistoricalAddressesIfNeeded(
                                        profile: profile,
                                        walletStore: walletStore,
                                        engine: engine,
                                        preferences: preferences,
                                        force: true
                                    )
                                }
                            }
                            .font(.footnote.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                }

                if let snapshot = syncService.snapshot {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("UTXOs", value: "\(snapshot.balance.utxoCount)")
                        TimelineView(.periodic(from: .now, by: 9)) { context in
                            LabeledContent("Last refreshed", value: relativeAge(from: snapshot.syncedAt, now: context.date))
                        }
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if preferences.showsCurrencyConverterInWallet {
                        Button {
                            currencyConverterDetent = .fraction(0.54)
                            showingCurrencyConverter = true
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Currency Converter")
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("Spot Price")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 8)

                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.headline)
                                    .foregroundStyle(Color(red: 0.20, green: 0.62, blue: 0.57))
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                .thinMaterial,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(SubtlePressButtonStyle())
                        .accessibilityHint("Opens the KAS and USD currency converter")
                    }
                } else if syncService.state == .syncing {
                    HStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)

                        Text("Connecting...")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding()
        }
        .refreshable {
            async let walletRefresh: Void = refreshSelectedWallet(force: true)
            async let priceRefresh: Void = priceService.refresh(
                preferences: preferences,
                force: true
            )
            _ = await (walletRefresh, priceRefresh)
        }
        .navigationDestination(isPresented: $showingSendFlow) {
            SendTransactionTypeSelectionView(
                profile: profile,
                showingSendFlow: $showingSendFlow
            )
        }
        .onChange(of: showingSendFlow) { _, isShowing in
            if !isShowing {
                walletStore.cancelSendSession(profileID: profile.id)
                coinControlStore.clearSelection()
            }
        }
    }

    private var mainnetVaultUnavailableView: some View {
        ContentUnavailableView(
            "Not Built on Mainnet",
            systemImage: "lock.shield",
            description: Text("Programmable UTXOs and Protected Vaults are not yet available on Mainnet.")
        )
    }

    private func programmableUTXOTypeSelection(_ profile: WalletProfile) -> some View {
        List {
            if let storageError = protectedVaultStore.storageError {
                Section {
                    Label(storageError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            Section("Types") {
                Button {
                    walletHomeAlert = .timeLockedPlaceholder
                } label: {
                    Label {
                        Text("New Time-Locked UTXO")
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "clock.badge.checkmark")
                            .foregroundStyle(Color(red: 0.20, green: 0.62, blue: 0.57))
                    }
                }
                .buttonStyle(.plain)

                NavigationLink(value: WalletRoute.protectedVaultRules(profile.id)) {
                    Label("New Protected Vault", systemImage: "lock.shield")
                        .imageScale(.large)
                }
                .disabled(protectedVaultStore.storageError != nil)
            }

            Section("Vaults") {
                let vaults = protectedVaultStore.vaults(for: profile.id)
                let setupDrafts = protectedVaultStore.setupDrafts(for: profile.id)
                if vaults.isEmpty && setupDrafts.isEmpty {
                    Label("No Active Vaults", systemImage: "lock.open")
                    .foregroundStyle(.secondary)
                }
                let items = (vaults.map(VaultListItem.vault) + setupDrafts.map(VaultListItem.setupDraft))
                    .sorted { lhs, rhs in
                        let lhsOpened = protectedVaultStore.lastOpenedAt(id: lhs.id, profileID: profile.id)
                        let rhsOpened = protectedVaultStore.lastOpenedAt(id: rhs.id, profileID: profile.id)
                        switch (lhsOpened, rhsOpened) {
                        case let (lhsDate?, rhsDate?):
                            if lhsDate != rhsDate { return lhsDate > rhsDate }
                        case (_?, nil):
                            return true
                        case (nil, _?):
                            return false
                        case (nil, nil):
                            break
                        }
                        return lhs.createdAt > rhs.createdAt
                    }

                ForEach(items) { item in
                    switch item {
                    case .vault(let vault):
                        NavigationLink(value: WalletRoute.protectedVaultDetail(vault.id)) {
                            activeVaultCard(vault)
                        }
                        .contextMenu {
                            Button {
                                contextVault = vault
                                contextVaultRenameText = vault.displayName
                                showingContextVaultRename = true
                            } label: {
                                Label("Rename Vault", systemImage: "pin")
                            }

                            Button(role: .destructive) {
                                contextVault = vault
                                showingContextVaultRemoval = true
                            } label: {
                                Label("Remove Vault Record", systemImage: "trash")
                                    .foregroundStyle(.red)
                            }
                        }
                    case .setupDraft(let draft):
                        NavigationLink(value: WalletRoute.protectedVaultSetupDraft(draft.id)) {
                            setupDraftCard(draft)
                        }
                    }
                }
            }

        }
        .navigationTitle("Programmable UTXOs")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(
            contextVaultRemovalTitle,
            isPresented: $showingContextVaultRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Local Record", role: .destructive) {
                if let contextVault {
                    protectedVaultStore.remove(id: contextVault.id)
                }
                contextVault = nil
            }
        } message: {
            Text(contextVaultRemovalMessage)
        }
        .alert("Rename Vault", isPresented: $showingContextVaultRename) {
            TextField("Vault name", text: $contextVaultRenameText)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) { contextVault = nil }
            Button("Save") {
                if let contextVault {
                    protectedVaultStore.rename(id: contextVault.id, to: contextVaultRenameText)
                }
                contextVault = nil
            }
            .disabled(contextVaultRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Choose a name for this vault.")
        }
    }

    private var contextVaultRemovalTitle: String {
        guard let contextVault else { return "Remove this vault from the app?" }
        return contextVault.status == .localDraft
            ? "Delete this vault draft?"
            : "Remove this vault from the app?"
    }

    private var contextVaultRemovalMessage: String {
        guard let contextVault else { return "This removes the saved vault record from this app." }
        if contextVault.status == .localDraft {
            return "This removes the unfunded vault draft from this app."
        }
        return "This vault has on-chain funds or funding history. Removing its local record will not move or recover funds, and removes the saved vault details needed to manage it in this app."
    }

    private func activeVaultCard(_ vault: ProtectedVault) -> some View {
        let statusColor: Color = switch vault.status {
        case .active: .green
        case .pendingWithdrawal, .incompatibleFunding: .red
        case .fundingBroadcast, .localDraft: .orange
        case .spent: .green
        }
        return HStack(spacing: 12) {
            Label("Protected Vault", systemImage: "lock.shield")
                .labelStyle(.iconOnly)
                .font(.body)
                .imageScale(.large)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(vault.displayName)
                        .font(.headline)

                    Spacer()

                    HStack(spacing: 4) {
                        if vault.status == .spent {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                        }
                        Text(vault.status == .active ? "Active" : vault.status.title)
                            .font(.system(size: UIFont.preferredFont(forTextStyle: .caption1).pointSize * 1.05, weight: .semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    .foregroundStyle(statusColor)
                    .frame(width: 132, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Text("\((vault.lockedAmount ?? vault.amount).formatted()) \(preferences.network.currencySymbol)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
                    "\(vault.displayName), \(vault.status.title), \((vault.lockedAmount ?? vault.amount).formatted()) \(preferences.network.currencySymbol)"
        )
    }

    private func setupDraftCard(_ draft: ProtectedVaultSetupDraft) -> some View {
        HStack(spacing: 12) {
            Label("Protected Vault", systemImage: "lock.shield")
                .labelStyle(.iconOnly)
                .font(.body)
                .imageScale(.large)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Protected Vault")
                        .font(.headline)
                    Spacer()
                    Text("Setup Draft")
                        .font(.system(size: UIFont.preferredFont(forTextStyle: .caption1).pointSize * 1.05, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                Text("Tap to resume setup")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Protected Vault, Setup Draft, tap to resume setup")
    }

    private var unavailableAccountView: some View {
        ContentUnavailableView(
            "Account Unavailable",
            systemImage: "wallet.pass",
            description: Text("Return to the Wallet screen and select an account.")
        )
    }

    private func walletHomeReceiveAddress(for profile: WalletProfile) -> String {
        guard !profile.receiveAddresses.isEmpty else {
            return "No receive address"
        }

        let index = walletStore.lastViewedReceiveIndex(
            for: profile.id,
            addressCount: profile.receiveAddresses.count
        )

        return profile.receiveAddresses[index]
    }

    private func copyWalletHomeReceiveAddress(for profile: WalletProfile) {
        guard !profile.receiveAddresses.isEmpty else { return }
        let address = walletHomeReceiveAddress(for: profile)
        PrivatePasteboard.copy(address)
        copyFeedbackCenter.showCopied(address)
    }

    private var balanceAmountText: String {
        guard let balance = syncService.snapshot?.balance.totalKas else { return "" }
        guard showingSecondaryCurrency && preferences.network == .mainnet else {
            return KasBalanceFormatter.string(
                from: balance,
                decimalPlaces: preferences.kasBalanceDecimalPlaces
            )
        }
        guard let converted = priceService.convertedBalance(
            kas: balance,
            currency: preferences.secondaryCurrency
        ) else {
            return "—"
        }

        switch preferences.secondaryCurrency {
        case .btc:
            return converted.formatted(.number.precision(.fractionLength(0...8)))
        case .usd:
            return converted.formatted(.number.precision(.fractionLength(2)))
        }
    }

    private var balanceUnitText: String {
        guard syncService.snapshot?.balance.totalKas != nil else { return "" }
        if preferences.network == .testnet10 { return "TKAS" }
        return showingSecondaryCurrency ? preferences.secondaryCurrency.rawValue.uppercased() : "KAS"
    }

    private var balanceDisplayText: String {
        guard !balanceAmountText.isEmpty else { return "" }
        return "\(balanceAmountText) \(balanceUnitText)"
    }

    private var balanceAccessibilityLabel: String {
        guard !balanceAmountText.isEmpty else { return "Balance unavailable" }
        return "\(balanceAmountText) \(balanceUnitText)"
    }

    private func refreshSelectedWallet(force: Bool) async {
        guard let profile = walletStore.selectedProfile else { return }
        if !force, syncService.snapshot != nil { return }
        await syncService.refresh(
            profile: profile,
            walletStore: walletStore,
            engine: engine,
            preferences: preferences,
            force: true
        )
        if force && profile.network == KaspaNetwork.mainnet.rawValue {
            await syncService.checkHistoricalAddressesIfNeeded(
                profile: profile,
                walletStore: walletStore,
                engine: engine,
                preferences: preferences,
                force: true
            )
        }
    }

    private func historicalCoverageMessage(for profile: WalletProfile) -> String? {
        guard profile.network == KaspaNetwork.mainnet.rawValue else { return nil }
        if let error = syncService.historicalDiscoveryError { return error }
        if max(profile.nextReceiveIndex, profile.nextChangeIndex) >= 462 {
            return "This account is near the supported 512-address limit. A full 50-address buffer may no longer be available."
        }
        return nil
    }

    private func compactActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
    }

    private func relativeAge(from timestamp: TimeInterval, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince1970 - timestamp))
        if elapsed < 60 { return "\(elapsed) sec ago" }
        let minutes = elapsed / 60
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        return "\(hours) hr ago"
    }
}

private struct ProtectedVaultSetupDraftResumeView: View {
    let draft: ProtectedVaultSetupDraft
    let profile: WalletProfile
    let onCreated: (ProtectedVault, [WalletUTXO], ProtectedVaultFundingFeeSelection) -> Void

    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @State private var restoredUTXOs: [WalletUTXO] = []
    @State private var needsUTXOReselection = false
    @State private var isValidating = true
    @State private var validationError: String?
    @State private var hasStartedInitialValidation = false

    var body: some View {
        Group {
            if isValidating {
                ProgressView("Revalidating saved funding UTXOs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let validationError {
                ContentUnavailableView(
                    label: {
                        Label("Funding UTXOs Couldn’t Be Verified", systemImage: "square.stack.3d.up.slash")
                    },
                    description: {
                        Text(validationError)
                    },
                    actions: {
                        Button("Retry") { Task { await validateSavedUTXOs() } }
                            .buttonStyle(.borderedProminent)
                    }
                )
            } else {
                ProtectedVaultRulesView(
                    profile: profile,
                    setupDraft: draft,
                    restoredUTXOs: restoredUTXOs,
                    needsUTXOReselection: needsUTXOReselection,
                    onCreated: onCreated
                )
            }
        }
        .task {
            guard !hasStartedInitialValidation else { return }
            hasStartedInitialValidation = true
            await validateSavedUTXOs()
        }
    }

    @MainActor
    private func validateSavedUTXOs() async {
        isValidating = true
        validationError = nil
        await syncService.refresh(
            profile: profile,
            walletStore: walletStore,
            engine: engine,
            preferences: preferences,
            force: true,
            includeTransactionHistory: false
        )
        guard case .connected = syncService.state,
              let currentUTXOs = syncService.snapshot?.utxos else {
            validationError = "Connect to the wallet network and retry before resuming this draft. Its saved inputs must be checked against current wallet UTXOs."
            isValidating = false
            return
        }

        let savedIDs = Set(draft.selectedUTXOIDs)
        restoredUTXOs = currentUTXOs.filter { savedIDs.contains($0.id) }
        needsUTXOReselection = restoredUTXOs.count != draft.selectedUTXOIDs.count
        isValidating = false
    }
}

private struct ProtectedVaultRulesView: View {
    let profile: WalletProfile
    let onCreated: (ProtectedVault, [WalletUTXO], ProtectedVaultFundingFeeSelection) -> Void
    private let setupDraft: ProtectedVaultSetupDraft?
    @State private var needsUTXOReselection: Bool

    @EnvironmentObject private var protectedVaultStore: ProtectedVaultStore
    @EnvironmentObject private var engine: KasSignerEngine
    @State private var approvedAddressCount = 1
    @State private var approvedAddresses = (0..<1).map { _ in ProtectedVaultAddressDraft() }
    @State private var delayDays = 30
    @State private var delayHours = 0
    @State private var delayMinutes = 0
    @State private var recoveryPath = ProtectedVaultRuleSelection.RecoveryPath.emergencyAnytime
    @State private var recoveryAddress = ProtectedVaultAddressDraft()
    @State private var fundingUTXOs: [WalletUTXO] = []
    @State private var submittedRules: ProtectedVaultRuleSelection?
    @State private var submittedSetupDraft: ProtectedVaultSetupDraft?
    @State private var showingCreateProtectedVault = false
    @State private var showingAddressesInfo = false
    @State private var showingSecurityDelayInfo = false
    @State private var showingRecoveryPathInfo = false
    @State private var showingVaultFlowInfo = false
    @State private var showingExpandedVaultFlow = false
    @State private var showingDraftExitPrompt = false
    @State private var shouldResumeSavedStep = false

    init(
        profile: WalletProfile,
        setupDraft: ProtectedVaultSetupDraft? = nil,
        restoredUTXOs: [WalletUTXO] = [],
        needsUTXOReselection: Bool = false,
        onCreated: @escaping (ProtectedVault, [WalletUTXO], ProtectedVaultFundingFeeSelection) -> Void
    ) {
        self.profile = profile
        self.setupDraft = setupDraft
        self.onCreated = onCreated
        _approvedAddressCount = State(initialValue: setupDraft?.approvedAddressCount ?? 1)
        let savedAddresses = setupDraft?.approvedAddresses.map { ProtectedVaultAddressDraft(address: $0) } ?? []
        _approvedAddresses = State(initialValue: savedAddresses.isEmpty
            ? (0..<max(1, setupDraft?.approvedAddressCount ?? 1)).map { _ in ProtectedVaultAddressDraft() }
            : savedAddresses)
        _delayDays = State(initialValue: setupDraft?.delayDays ?? 30)
        _delayHours = State(initialValue: setupDraft?.delayHours ?? 0)
        _delayMinutes = State(initialValue: setupDraft?.delayMinutes ?? 0)
        _recoveryPath = State(initialValue: setupDraft?.recoveryPath ?? .emergencyAnytime)
        _recoveryAddress = State(initialValue: ProtectedVaultAddressDraft(address: setupDraft?.recoveryAddress ?? ""))
        _fundingUTXOs = State(initialValue: restoredUTXOs)
        _needsUTXOReselection = State(initialValue: needsUTXOReselection)
        let shouldResume = setupDraft != nil
            && setupDraft?.step != .rules
            && !needsUTXOReselection
        _shouldResumeSavedStep = State(initialValue: shouldResume)
        _showingCreateProtectedVault = State(initialValue: shouldResume)
        if let setupDraft, shouldResume {
            var restoredRules = protectedVaultRuleSelection(from: setupDraft)
            restoredRules.fundingUTXOs = restoredUTXOs
            _submittedRules = State(initialValue: restoredRules)
            _submittedSetupDraft = State(initialValue: setupDraft)
        }
    }

    var body: some View {
        Form {
            Section {
                ZStack(alignment: .topTrailing) {
                    ProtectedVaultFlowDiagram()
                        .padding(.vertical, 6)

                    Button {
                        showingExpandedVaultFlow = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Color.secondary.opacity(0.20))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Expand Vault Flow")
                    .padding(.top, 2)
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            } header: {
                HStack(spacing: 6) {
                    Text("Vault Flow")
                    Button {
                        showingVaultFlowInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About the vault flow")
                }
            }

            Section {
                Picker("Approved Addresses", selection: $approvedAddressCount) {
                    ForEach(1...5, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.menu)

                NavigationLink {
                    EnterProtectedVaultAddressesView(addresses: $approvedAddresses)
                } label: {
                    Text("Enter Addresses")
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Addresses")
                    Button {
                        showingAddressesInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About approved addresses")
                }
            }

            Section {
                delayPicker("Days", selection: $delayDays, range: 0...365)
                delayPicker("Hours", selection: $delayHours, range: 0...23)
                delayPicker("Minutes", selection: $delayMinutes, range: 0...59)
            } header: {
                HStack(spacing: 6) {
                    Text("Security Delay")
                    Button {
                        showingSecurityDelayInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About the security delay")
                }
            }

            Section {
                Picker("Path", selection: $recoveryPath) {
                    ForEach(ProtectedVaultRuleSelection.RecoveryPath.allCases) { path in
                        Text(path.rawValue).tag(path)
                    }
                }
                .pickerStyle(.menu)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color(.secondarySystemGroupedBackground))

                NavigationLink {
                    EnterProtectedVaultRecoveryAddressView(address: $recoveryAddress)
                } label: {
                    Text("Enter Recovery Address")
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Recovery Path")
                    Button {
                        showingRecoveryPathInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About recovery paths")
                }
            }

            Section {
                if needsUTXOReselection {
                    Text("One or more saved funding UTXOs are no longer available. Review the selection and replace any missing inputs.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                NavigationLink {
                    SendUTXOSelectionView(
                        profile: profile,
                        transactionType: .standard,
                        clearSelectionOnAppear: true,
                        showingSendFlow: .constant(false),
                        protectedVaultSelection: { fundingUTXOs = $0 },
                        initialProtectedVaultUTXOs: fundingUTXOs
                    )
                } label: {
                    HStack {
                        Text("Select UTXOs")
                        Spacer()
                        if !fundingUTXOs.isEmpty {
                            Text("\(fundingUTXOs.count) selected")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                if let fundingTotalSompi, !fundingUTXOs.isEmpty {
                    let symbol = profile.network == KaspaNetwork.testnet10.rawValue ? "TKAS" : "KAS"
                    Text("Selected input total: \((Decimal(fundingTotalSompi) / Decimal(100_000_000)).formatted()) \(symbol)")
                }
            }

            Section {
                Button {
                    let savedDraft = makeSetupDraft(step: .review)
                    protectedVaultStore.saveSetupDraft(savedDraft)
                    submittedSetupDraft = savedDraft
                    shouldResumeSavedStep = false
                    submittedRules = ProtectedVaultRuleSelection(
                        approvedAddressCount: approvedAddressCount,
                        approvedAddresses: approvedAddresses,
                        fundingUTXOs: fundingUTXOs,
                        recoveryAddress: recoveryAddress,
                        delayDays: delayDays,
                        delayHours: delayHours,
                        delayMinutes: delayMinutes,
                        recoveryPath: recoveryPath
                    )
                    showingCreateProtectedVault = true
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .modifier(ProtectedVaultActionButtonModifier(isProtectedVault: true))
                .controlSize(.large)
                .disabled(
                    (delayDays == 0 && delayHours == 0 && delayMinutes == 0)
                        || !approvedAddressesAreValid
                        || !recoveryAddressIsValid
                        || fundingUTXOs.isEmpty
                        || fundingTotalSompi == nil
                )
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Vault Rules")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(
            ProtectedVaultDraftExitPrompt(
                isPresented: $showingDraftExitPrompt,
                draftID: activeSetupDraftID,
                makeDraft: { makeSetupDraft(step: .rules) }
            )
        )
        .alert("Security Delay", isPresented: $showingSecurityDelayInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Withdrawals to destinations outside your approved list first move into a delayed covenant output. The delay starts with that withdrawal transaction. Once the network reaches the required DAA score, you can broadcast a second transaction to complete the withdrawal. The time shown is an estimate; the DAA threshold is enforced at the consensus level.")
        }
        .alert("Approved Addresses", isPresented: $showingAddressesInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Withdrawals to these addresses can be made immediately through the approved covenant path. The covenant rules are generated from the addresses you enter here. Other destinations use the security delay and require a second transaction to complete the withdrawal.")
        }
        .alert("Recovery Path", isPresented: $showingRecoveryPathInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Emergency Recovery 24/7: enables a recovery spend from an active vault to the configured recovery address without waiting for the security delay. It can also be used to redirect a pending withdrawal. To sign either recovery transaction, the wallet account that controls the recovery address must be imported in the app.\n\nCancel pending withdrawal only: if an unapproved withdrawal has started its security delay, you can redirect the pending funds to the configured recovery address. This option does not provide an immediate recovery route while the vault is active.")
        }
        .alert("Vault Flow Example", isPresented: $showingVaultFlowInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("For example, you deposit 100,000 \(flowCurrencySymbol) into a protected vault and approve five destination addresses. A withdrawal to any of those five addresses can use the immediate approved path. A withdrawal to an unapproved address first broadcasts a transaction that commits to that destination and moves the funds into a pending covenant output. The security delay begins with that transaction. Once the required DAA score is reached, you broadcast a second transaction to complete the withdrawal to the chosen destination. The configured time is an estimate; the DAA threshold is enforced at the consensus level.")
        }
        .onChange(of: approvedAddressCount) { _, count in
            resizeAddressDrafts(to: count)
        }
        .onAppear {
            resizeAddressDrafts(to: approvedAddressCount)
        }
        .onChange(of: fundingUTXOs) { _, selected in
            if !selected.isEmpty { needsUTXOReselection = false }
        }
        .task {
            await revalidateRestoredAddresses()
        }
        .navigationDestination(isPresented: $showingCreateProtectedVault) {
            if let submittedRules {
                ReviewProtectedVaultView(
                    profile: profile,
                    selectedUTXOs: submittedRules.fundingUTXOs,
                    rules: submittedRules,
                    setupDraft: submittedSetupDraft,
                    resumeStep: shouldResumeSavedStep ? setupDraft?.step : nil,
                    onCreated: onCreated
                )
            }
        }
        .fullScreenCover(isPresented: $showingExpandedVaultFlow) {
            ExpandedProtectedVaultFlowView()
        }
    }

    private var activeSetupDraftID: UUID? {
        setupDraft?.id ?? submittedSetupDraft?.id
    }

    private func makeSetupDraft(step: ProtectedVaultSetupDraft.Step) -> ProtectedVaultSetupDraft {
        let latestSavedDraft = activeSetupDraftID.flatMap { protectedVaultStore.setupDraft(id: $0) }
        return ProtectedVaultSetupDraft(
            id: activeSetupDraftID ?? UUID(),
            profileID: profile.id,
            createdAt: latestSavedDraft?.createdAt ?? setupDraft?.createdAt ?? submittedSetupDraft?.createdAt ?? .now,
            approvedAddressCount: approvedAddressCount,
            approvedAddresses: approvedAddresses.prefix(approvedAddressCount).map {
                $0.address.trimmingCharacters(in: .whitespacesAndNewlines)
            },
            recoveryAddress: recoveryAddress.address.trimmingCharacters(in: .whitespacesAndNewlines),
            recoveryPath: recoveryPath,
            delayDays: delayDays,
            delayHours: delayHours,
            delayMinutes: delayMinutes,
            selectedUTXOIDs: fundingUTXOs.map(\.id),
            feeChoiceRawValue: latestSavedDraft?.feeChoiceRawValue ?? setupDraft?.feeChoiceRawValue ?? submittedSetupDraft?.feeChoiceRawValue ?? "normal",
            customFeeText: latestSavedDraft?.customFeeText ?? setupDraft?.customFeeText ?? submittedSetupDraft?.customFeeText ?? "",
            step: step
        )
    }

    private func resizeAddressDrafts(to count: Int) {
        while approvedAddresses.count < count {
            approvedAddresses.append(ProtectedVaultAddressDraft())
        }
        if approvedAddresses.count > count {
            approvedAddresses.removeLast(approvedAddresses.count - count)
        }
    }

    @MainActor
    private func revalidateRestoredAddresses() async {
        guard setupDraft != nil else { return }

        for index in approvedAddresses.indices {
            let value = approvedAddresses[index].address
            guard !value.isEmpty else { continue }
            approvedAddresses[index].isValidating = true
            do {
                let result = try await engine.validateAddress(value)
                approvedAddresses[index].validation = result
                if result.valid, result.network == profile.network, let normalized = result.normalized {
                    approvedAddresses[index].address = normalized
                }
            } catch {
                approvedAddresses[index].validation = AddressValidationResult(
                    valid: false,
                    network: profile.network,
                    normalized: nil,
                    reason: error.localizedDescription
                )
            }
            approvedAddresses[index].isValidating = false
        }

        let recoveryValue = recoveryAddress.address
        guard !recoveryValue.isEmpty else { return }
        recoveryAddress.isValidating = true
        do {
            let result = try await engine.validateAddress(recoveryValue)
            recoveryAddress.validation = result
            if result.valid, result.network == profile.network, let normalized = result.normalized {
                recoveryAddress.address = normalized
            }
        } catch {
            recoveryAddress.validation = AddressValidationResult(
                valid: false,
                network: profile.network,
                normalized: nil,
                reason: error.localizedDescription
            )
        }
        recoveryAddress.isValidating = false
    }

    private var approvedAddressesAreValid: Bool {
        approvedAddresses.count == approvedAddressCount
            && Set(approvedAddresses.map { $0.address.lowercased() }).count == approvedAddressCount
            && approvedAddresses.allSatisfy {
                !$0.address.isEmpty
                    && $0.validation?.valid == true
                    && $0.validation?.network == profile.network
                    && !$0.isValidating
            }
    }

    private var recoveryAddressIsValid: Bool {
        !recoveryAddress.address.isEmpty
            && !recoveryAddress.isValidating
            && recoveryAddress.validation?.valid == true
            && recoveryAddress.validation?.network == profile.network
    }

    private var fundingTotalSompi: UInt64? {
        fundingUTXOs.reduce(into: UInt64?.some(0)) { total, utxo in
            guard let current = total else { return }
            let addition = current.addingReportingOverflow(utxo.amount)
            total = addition.overflow ? nil : addition.partialValue
        }
    }

    private var flowCurrencySymbol: String {
        profile.network == KaspaNetwork.testnet10.rawValue ? "TKAS" : "KAS"
    }

    private func delayPicker(
        _ title: String,
        selection: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        LabeledContent(title) {
            Picker(title, selection: selection) {
                ForEach(range, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

}

private struct ExpandedProtectedVaultFlowView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            VStack {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    ProtectedVaultFlowDiagram(isExpanded: true)
                }
                .padding(16)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .padding(.horizontal, 20)
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .onTapGesture { }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 620)
        }
    }
}

private struct ProtectedVaultFlowDiagram: View {
    var isExpanded = false
    private let accent = Color.accentColor
    private var flowText: Font { (isExpanded ? Font.callout : Font.caption).weight(.medium) }
    private var scale: CGFloat { isExpanded ? 1.25 : 1 }
    // Flip this back to true to restore the current decorative node icons.
    private let showsDecorativeIcons = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                node("UTXOs", systemImage: "square.stack.3d.up", color: accent)
                    .fixedSize(horizontal: true, vertical: false)
                Canvas { context, size in
                    var path = Path()
                    let tipX = size.width - 1
                    let shoulderX = size.width - 7
                    let middleY = size.height / 2
                    path.move(to: CGPoint(x: 0, y: middleY))
                    path.addLine(to: CGPoint(x: shoulderX, y: middleY))
                    path.addLine(to: CGPoint(x: tipX, y: middleY))
                    path.addLine(to: CGPoint(x: shoulderX, y: middleY - 4 * scale))
                    path.move(to: CGPoint(x: tipX, y: middleY))
                    path.addLine(to: CGPoint(x: shoulderX, y: middleY + 4 * scale))
                    context.stroke(
                        path,
                        with: .color(lineColor),
                        style: StrokeStyle(lineWidth: scale, lineCap: .round, lineJoin: .round)
                    )
                }
                .frame(width: isExpanded ? 118 : 158, height: 14 * scale)
                node("Protected Vault", systemImage: "lock.shield", color: accent)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }

            Canvas { context, size in
                var path = Path()
                let trunkX = size.width * 0.70
                let leftX = size.width * 0.18
                let rightX = size.width * 0.78
                let junctionY: CGFloat = 17 * scale
                path.move(to: CGPoint(x: trunkX, y: 9 * scale))
                path.addLine(to: CGPoint(x: trunkX, y: junctionY))
                path.move(to: CGPoint(x: leftX, y: junctionY))
                path.addLine(to: CGPoint(x: rightX, y: junctionY))
                path.move(to: CGPoint(x: leftX, y: junctionY))
                path.addLine(to: CGPoint(x: leftX, y: size.height - 10 * scale))
                path.move(to: CGPoint(x: rightX, y: junctionY))
                path.addLine(to: CGPoint(x: rightX, y: size.height - 10 * scale))
                context.stroke(
                    path,
                    with: .color(connectorColor),
                    style: StrokeStyle(lineWidth: scale, lineCap: .round, lineJoin: .round)
                )
            }
            .frame(height: 31 * scale)

            HStack(alignment: .top, spacing: 16 * scale) {
                VStack(alignment: .leading, spacing: 0) {
                    node("Approved Addresses", systemImage: "checkmark.shield.fill", color: accent)
                    Rectangle()
                        .fill(.clear)
                        .frame(width: 0.75 * scale, height: 41 * scale)
                        .overlay {
                            Rectangle()
                                .fill(connectorColor)
                                .frame(width: scale, height: 25 * scale)
                        }
                        .padding(.top, 7 * scale)
                        .padding(.leading, 21 * scale)
                    HStack(spacing: 6 * scale) {
                        if showsDecorativeIcons {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color(red: 0.20, green: 0.62, blue: 0.57))
                        }
                        Image(systemName: "clock.badge.checkmark")
                            .font(isExpanded ? flowText : .body)
                            .foregroundStyle(Color(red: 0.20, green: 0.62, blue: 0.57))
                        Text("No Security Delay")
                            .font(flowText)
                            .foregroundStyle(Color(red: 0.20, green: 0.62, blue: 0.57))
                    }
                    .padding(.leading, 12 * scale)
                    .padding(.vertical, 8 * scale)
                    Rectangle()
                        .fill(.clear)
                        .frame(width: 0.75 * scale, height: 41 * scale)
                        .overlay {
                            Rectangle()
                                .fill(connectorColor)
                                .frame(width: scale, height: 25 * scale)
                        }
                        .padding(.bottom, 7 * scale)
                        .padding(.leading, 21 * scale)
                    node("Destination", systemImage: "mappin.and.ellipse", color: accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 7 * scale) {
                    node("Unapproved Destinations", systemImage: "arrow.up.right", color: accent, singleLine: true)
                        .offset(x: -8)
                    branchConnector(height: 12)
                    node("Security Delay", systemImage: "clock", color: .red)
                    branchConnector(height: 12)
                    node("Covenant Output", systemImage: "lock.shield", color: accent)
                    branchConnector(height: 18)
                    node("Destination", systemImage: "mappin.and.ellipse", color: accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lineColor: Color { Color.secondary.opacity(0.20) }
    private var connectorColor: Color { lineColor }

    private func node(
        _ title: String,
        systemImage: String,
        color: Color,
        singleLine: Bool = false
    ) -> some View {
        HStack(spacing: 8 * scale) {
            if showsDecorativeIcons || title == "Security Delay" {
                Image(systemName: systemImage)
                    .font(isExpanded ? flowText : .body)
                    .foregroundStyle(title == "Security Delay" ? .red : color)
            }
            Text(title)
                .font(flowText)
                .foregroundStyle(.primary)
                .lineLimit(singleLine ? 1 : nil)
                .minimumScaleFactor(singleLine ? 0.82 : 1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func branchConnector(height: CGFloat = 17) -> some View {
        Rectangle()
            .fill(connectorColor)
            .frame(width: scale, height: height * scale)
            .padding(.leading, 12 * scale)
    }
}

private struct EnterProtectedVaultAddressesView: View {
    @Binding var addresses: [ProtectedVaultAddressDraft]

    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @State private var validationTasks: [UUID: Task<Void, Never>] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach($addresses) { $address in
                    let index = addresses.firstIndex(where: { $0.id == address.id }) ?? 0
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Approved address \(index + 1)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        TextField("\(preferences.network.addressPrefix)...", text: $address.address, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.subheadline, design: .monospaced))
                            .keyboardType(.asciiCapable)
                            .lineLimit(2...4)
                            .fixedSize(horizontal: false, vertical: true)
                            .onChange(of: address.address) { _, newValue in
                                let normalized = normalizeAddress(newValue)
                                if normalized != newValue {
                                    address.address = normalized
                                    return
                                }
                                validateAddress(id: address.id, value: normalized)
                            }
                            .padding(12)
                            .background(
                                Color(.tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    address.address.isEmpty
                                        ? Color.primary.opacity(0.06)
                                        : address.validation?.valid == true
                                            && address.validation?.network == preferences.network.rawValue
                                            ? Color(red: 0.20, green: 0.62, blue: 0.57).opacity(0.75)
                                            : Color.red.opacity(0.65),
                                    lineWidth: 1
                                )
                        }

                        if address.isValidating {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Checking \(preferences.network.title) address…")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else if let validation = address.validation,
                                  !address.address.isEmpty {
                            let isValidMainnet = validation.valid && validation.network == preferences.network.rawValue
                            HStack(spacing: 6) {
                                Image(systemName: isValidMainnet
                                    ? "checkmark.circle.fill"
                                    : "xmark.circle.fill")
                                Text(isValidMainnet
                                    ? "Valid \(preferences.network.title) address."
                                    : (validation.reason ?? "Invalid \(preferences.network.title) address."))
                            }
                            .font(.caption)
                            .foregroundStyle(
                                isValidMainnet
                                    ? Color(red: 0.20, green: 0.62, blue: 0.57)
                                    : .red
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        Color(.secondarySystemGroupedBackground).opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }

                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(red: 0.20, green: 0.62, blue: 0.57))
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Covenant rule")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("These approved addresses are enforced at the consensus level and become fixed when the covenant is created. Double-check every address and make sure you understand and intend to lock in these rules.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .padding(.top, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Destinations")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            validationTasks.values.forEach { $0.cancel() }
            for id in validationTasks.keys {
                updateAddress(id: id) { $0.isValidating = false }
            }
        }
    }

    private func validateAddress(id: UUID, value: String) {
        validationTasks[id]?.cancel()
        updateAddress(id: id) {
            $0.validation = nil
            $0.isValidating = false
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        updateAddress(id: id) { $0.isValidating = true }
        validationTasks[id] = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            do {
                let result = try await engine.validateAddress(trimmed)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    updateAddress(id: id) {
                        $0.validation = result
                        $0.isValidating = false
                        if result.valid, result.network == preferences.network.rawValue,
                           let normalized = result.normalized {
                            $0.address = normalized
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    updateAddress(id: id) {
                        $0.validation = AddressValidationResult(
                            valid: false,
                            network: preferences.network.rawValue,
                            normalized: nil,
                            reason: error.localizedDescription
                        )
                        $0.isValidating = false
                    }
                }
            }
        }
    }

    private func updateAddress(
        id: UUID,
        update: (inout ProtectedVaultAddressDraft) -> Void
    ) {
        guard let index = addresses.firstIndex(where: { $0.id == id }) else { return }
        update(&addresses[index])
    }

    private func normalizeAddress(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "kaspatest://", with: "kaspatest:", options: [.caseInsensitive])
            .replacingOccurrences(of: "kaspa://", with: "kaspa:", options: [.caseInsensitive])
    }
}

private struct EnterProtectedVaultRecoveryAddressView: View {
    @Binding var address: ProtectedVaultAddressDraft

    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @State private var validationTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Approved Recovery Address")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    TextField("\(preferences.network.addressPrefix)...", text: $address.address, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.subheadline, design: .monospaced))
                        .keyboardType(.asciiCapable)
                        .lineLimit(2...4)
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: address.address) { _, value in
                            let normalized = normalizeAddress(value)
                            if normalized != value {
                                address.address = normalized
                                return
                            }
                            validateAddress(normalized)
                        }
                        .padding(12)
                        .background(
                            Color(.tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(addressFieldBorderColor, lineWidth: 1)
                        }

                    validationMessage
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    Color(.secondarySystemGroupedBackground).opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )

                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(red: 0.20, green: 0.62, blue: 0.57))
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Covenant rule")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("The selected recovery path can use this address to recover vault funds. Check it carefully; the recovery destination is fixed when the vault is created.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Destination")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            validationTask?.cancel()
            address.isValidating = false
        }
    }

    private var addressFieldBorderColor: Color {
        if address.address.isEmpty { return Color.primary.opacity(0.06) }
        if address.validation?.valid == true, address.validation?.network == preferences.network.rawValue {
            return Color(red: 0.20, green: 0.62, blue: 0.57).opacity(0.75)
        }
        return Color.red.opacity(0.65)
    }

    @ViewBuilder
    private var validationMessage: some View {
        if address.isValidating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking \(preferences.network.title) address…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let validation = address.validation, !address.address.isEmpty {
            let isValidMainnet = validation.valid && validation.network == preferences.network.rawValue
            HStack(spacing: 6) {
                Image(systemName: isValidMainnet ? "checkmark.circle.fill" : "xmark.circle.fill")
                Text(isValidMainnet
                    ? "Valid \(preferences.network.title) address."
                    : (validation.reason ?? "Invalid \(preferences.network.title) address."))
            }
            .font(.caption)
            .foregroundStyle(isValidMainnet ? Color(red: 0.20, green: 0.62, blue: 0.57) : .red)
        }
    }

    private func validateAddress(_ value: String) {
        validationTask?.cancel()
        address.validation = nil
        address.isValidating = false
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        address.isValidating = true
        validationTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                let result = try await engine.validateAddress(trimmed)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    address.validation = result
                    address.isValidating = false
                    if result.valid, result.network == preferences.network.rawValue, let normalized = result.normalized {
                        address.address = normalized
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    address.validation = AddressValidationResult(
                        valid: false,
                        network: nil,
                        normalized: nil,
                        reason: error.localizedDescription
                    )
                    address.isValidating = false
                }
            }
        }
    }

    private func normalizeAddress(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "kaspatest://", with: "kaspatest:", options: [.caseInsensitive])
            .replacingOccurrences(of: "kaspa://", with: "kaspa:", options: [.caseInsensitive])
    }
}

private struct CreateProtectedVaultView: View {
    let profile: WalletProfile
    let selectedUTXOs: [WalletUTXO]
    let rules: ProtectedVaultRuleSelection
    let onCreated: (ProtectedVault) -> Void

    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var priceService: PriceService
    @EnvironmentObject private var preferences: AppPreferences
    @State private var amountText = ""
    @State private var usdAmountText = ""
    @State private var amountEntryUsesUSD = false
    @State private var sendMax = false
    @State private var usesSendMaxFunding = false
    @State private var sendMaxFeeError: String?
    @State private var approvedAddresses: [ProtectedVaultAddressDraft]
    @State private var delayDays: Int
    @State private var delayHours: Int
    @State private var delayMinutes: Int
    @State private var showingReview = false

    init(
        profile: WalletProfile,
        selectedUTXOs: [WalletUTXO],
        rules: ProtectedVaultRuleSelection,
        onCreated: @escaping (ProtectedVault) -> Void
    ) {
        self.profile = profile
        self.selectedUTXOs = selectedUTXOs
        self.rules = rules
        self.onCreated = onCreated
        let addressCount = min(max(rules.approvedAddressCount, 1), 5)
        _approvedAddresses = State(
            initialValue: rules.approvedAddresses.count == addressCount
                ? rules.approvedAddresses
                : (0..<addressCount).map { _ in ProtectedVaultAddressDraft() }
        )
        _delayDays = State(initialValue: rules.delayDays)
        _delayHours = State(initialValue: rules.delayHours)
        _delayMinutes = State(initialValue: rules.delayMinutes)
    }

    private var amountIsValid: Bool {
        guard let amount = Decimal(string: amountText), amount > 0 else { return false }
        return true
    }

    private var delayIsValid: Bool {
        delayDays > 0 || delayHours > 0 || delayMinutes > 0
    }

    private var approvedAddressIsValid: Bool {
        !approvedAddresses.isEmpty
            && approvedAddresses.count <= 5
            && Set(approvedAddresses.map { normalizeAddress($0.address) }).count == approvedAddresses.count
            && approvedAddresses.allSatisfy {
                !$0.isValidating && $0.validation?.valid == true
                    && $0.validation?.network == profile.network
            }
    }

    var body: some View {
        Form {
            Section {
                Button {
                    showingReview = true
                } label: {
                    Text("Review Protected Vault")
                        .frame(maxWidth: .infinity)
                }
                .modifier(ProtectedVaultActionButtonModifier(isProtectedVault: true))
                .controlSize(.large)
                .disabled(selectedUTXOs.isEmpty || !amountIsValid || !approvedAddressIsValid || !delayIsValid)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Review Vault")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !sendMax else { return }
            sendMax = true
            Task { await updateAmountForSendMax(true) }
        }
        .navigationDestination(isPresented: $showingReview) {
            ReviewProtectedVaultView(
                profile: profile,
                selectedUTXOs: selectedUTXOs,
                rules: rules,
                onCreated: { vault, _, _ in onCreated(vault) }
            )
        }
    }

    private func normalizeAddress(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: "kaspa://",
                with: "kaspa:",
                options: [.caseInsensitive]
            )
    }

    private var selectedInputTotal: UInt64 {
        selectedUTXOs.reduce(0) { total, utxo in
            let sum = total.addingReportingOverflow(utxo.amount)
            return sum.overflow ? UInt64.max : sum.partialValue
        }
    }

    private func formatKas(_ sompi: UInt64) -> String {
        "\((Decimal(sompi) / Decimal(100_000_000)).formatted()) \(preferences.network.currencySymbol)"
    }

    private var amountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Amount")
                    .font(.headline)

                Text(availableBalanceText)
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
                        Text(amountEntryUsesUSD ? "USD" : preferences.network.currencySymbol)
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
                .disabled(usdSpotPrice == nil || sendMax)
                .accessibilityLabel(
                    amountEntryUsesUSD
                        ? "Amount entered in US dollars"
                        : "Amount entered in \(preferences.network.currencySymbol)"
                )
                .accessibilityHint("Double tap to switch between \(preferences.network.currencySymbol) and US dollars.")
            }
            .padding(12)
            .background(
                Color(.tertiarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .sensoryFeedback(.selection, trigger: amountEntryUsesUSD)

            Toggle("Send Max", isOn: $sendMax)
                .onChange(of: sendMax) { _, enabled in
                    Task { await updateAmountForSendMax(enabled) }
                }
                .font(.subheadline.weight(.semibold))
                .tint(Color(red: 0.20, green: 0.62, blue: 0.57))
                .disabled(selectedUTXOs.isEmpty)

            if sendMax && selectedInputTotal > 0 {
                Text(profile.network == KaspaNetwork.testnet10.rawValue
                    ? "Send Max reserves an estimated funding fee. The final deposit updates with the selected fee."
                    : "Send Max uses the full selected input total. The funding review will account for the transaction fee.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let sendMaxFeeError {
                Text(sendMaxFeeError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !amountText.isEmpty && !amountIsValid {
                Text("Enter a valid amount greater than zero.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private var amountEntryText: Binding<String> {
        Binding(
            get: { amountEntryUsesUSD ? usdAmountText : amountText },
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
        guard preferences.network == .mainnet else { return nil }
        guard let price = priceService.price(for: .usd), price.isFinite, price > 0 else {
            return nil
        }
        return price
    }

    private var availableBalanceText: String {
        guard selectedInputTotal > 0 else { return "Available balance: 0 \(preferences.network.currencySymbol)" }
        if amountEntryUsesUSD, let price = usdSpotPrice {
            let kas = Double(selectedInputTotal) / 100_000_000
            return "Available balance: \((kas * price).formatted(.currency(code: "USD").precision(.fractionLength(2))))"
        }
        return "Available balance: \(formatPlainKas(selectedInputTotal)) \(preferences.network.currencySymbol)"
    }

    private func toggleAmountEntryCurrency() {
        guard !sendMax else { return }
        if amountEntryUsesUSD {
            amountEntryUsesUSD = false
            return
        }
        guard let price = usdSpotPrice else { return }
        if let amount = parseKasTextToSompi(amountText) {
            usdAmountText = formatUSDInput(Double(amount) / 100_000_000 * price)
        } else {
            usdAmountText = ""
        }
        amountEntryUsesUSD = true
    }

    private func updateKASAmountFromUSD(_ text: String) {
        guard let price = usdSpotPrice else { return }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty else {
            amountText = ""
            return
        }
        guard let usd = Double(normalized), usd.isFinite, usd >= 0 else {
            amountText = ""
            return
        }
        let sompi = (usd / price * 100_000_000).rounded()
        guard sompi.isFinite, sompi >= 0, sompi < Double(UInt64.max) else {
            amountText = ""
            return
        }
        amountText = formatPlainKas(UInt64(sompi))
    }

    private func formatUSDInput(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...5)))
    }

    private func formatPlainKas(_ sompi: UInt64) -> String {
        let whole = sompi / 100_000_000
        let fractional = sompi % 100_000_000
        guard fractional != 0 else { return String(whole) }
        let fractionalText = String(format: "%08llu", fractional)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        return "\(whole).\(fractionalText)"
    }

    private func parseKasTextToSompi(_ text: String) -> UInt64? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !raw.isEmpty, !raw.contains("-"), !raw.lowercased().contains("e") else {
            return nil
        }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, !parts[0].isEmpty,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let whole = UInt64(parts[0]) else { return nil }
        let fractional = parts.count == 2 ? String(parts[1]) : ""
        guard fractional.count <= 8 else { return nil }
        let wholeSompi = whole.multipliedReportingOverflow(by: 100_000_000)
        guard !wholeSompi.overflow,
              let fractionalSompi = UInt64(fractional.padding(toLength: 8, withPad: "0", startingAt: 0)) else {
            return nil
        }
        let total = wholeSompi.partialValue.addingReportingOverflow(fractionalSompi)
        return total.overflow ? nil : total.partialValue
    }

    @MainActor
    private func updateAmountForSendMax(_ enabled: Bool) async {
        if enabled {
            sendMaxFeeError = nil
            if profile.network == KaspaNetwork.testnet10.rawValue {
                do {
                    let estimate = try await engine.getFeeEstimate(
                        nodeConfiguration: preferences.nodeConfiguration
                    )
                    guard sendMax else { return }
                    guard let fee = protectedVaultNormalFeeEstimate(
                        estimate: estimate,
                        inputCount: selectedUTXOs.count
                    ), selectedInputTotal > fee else {
                        throw VaultFundingBuildError.invalidPlan
                    }
                    let maxDeposit = selectedInputTotal - fee
                    amountText = formatPlainKas(maxDeposit)
                    if amountEntryUsesUSD, let price = usdSpotPrice {
                        usdAmountText = formatUSDInput(Double(maxDeposit) / 100_000_000 * price)
                    }
                    usesSendMaxFunding = true
                } catch {
                    sendMax = false
                    usesSendMaxFunding = false
                    sendMaxFeeError = "Could not estimate the funding fee. Try again before using Send Max."
                }
            } else {
                amountText = formatPlainKas(selectedInputTotal)
                if amountEntryUsesUSD, let price = usdSpotPrice {
                    usdAmountText = formatUSDInput(Double(selectedInputTotal) / 100_000_000 * price)
                }
            }
        } else {
            if usesSendMaxFunding {
                amountText = ""
                usdAmountText = ""
                usesSendMaxFunding = false
            } else if parseKasTextToSompi(amountText) == selectedInputTotal {
                amountText = ""
                usdAmountText = ""
            }
        }
    }
}

private struct ReviewProtectedVaultView: View {
    let profile: WalletProfile
    let selectedUTXOs: [WalletUTXO]
    let rules: ProtectedVaultRuleSelection
    let setupDraft: ProtectedVaultSetupDraft?
    let resumeStep: ProtectedVaultSetupDraft.Step?
    let onCreated: (ProtectedVault, [WalletUTXO], ProtectedVaultFundingFeeSelection) -> Void

    @EnvironmentObject private var protectedVaultStore: ProtectedVaultStore
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @State private var descriptor: ProtectedVaultDescriptor?
    @State private var derivationError: String?
    @State private var verifiedApprovedDestinations = false
    @State private var approvedAddressCheckPassed: Bool?
    @State private var covenantRuleCheckPassed: Bool?
    @State private var vaultAddressCheckPassed: Bool?
    @State private var selectedFee: VaultFundingFeeChoice
    @State private var customFeeText: String
    @State private var feeEstimate: FeeEstimate?
    @State private var feeEstimateError: String?
    @State private var isRefreshingFee = false
    @State private var showingWalletFundingReview = false
    @State private var hasAppliedResumeStep = false

    init(
        profile: WalletProfile,
        selectedUTXOs: [WalletUTXO],
        rules: ProtectedVaultRuleSelection,
        setupDraft: ProtectedVaultSetupDraft? = nil,
        resumeStep: ProtectedVaultSetupDraft.Step? = nil,
        onCreated: @escaping (ProtectedVault, [WalletUTXO], ProtectedVaultFundingFeeSelection) -> Void
    ) {
        self.profile = profile
        self.selectedUTXOs = selectedUTXOs
        self.rules = rules
        self.setupDraft = setupDraft
        self.resumeStep = resumeStep
        self.onCreated = onCreated
        _selectedFee = State(initialValue: VaultFundingFeeChoice(rawValue: setupDraft?.feeChoiceRawValue ?? "normal") ?? .normal)
        _customFeeText = State(initialValue: setupDraft?.customFeeText ?? "")
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    VStack(spacing: 0) {
                        reviewSummaryRow("UTXOs", value: "\(selectedUTXOs.count)")
                        Divider()
                        reviewSummaryRow("Input Total", value: formatKas(selectedInputTotal))
                        Divider()
                        reviewSummaryRow("Approved Addresses", value: "\(approvedAddresses.count)")
                        Divider()
                        reviewSummaryRow("Security Delay", value: delaySummary)
                        Divider()
                        reviewSummaryRow("Estimated Fee", value: requestedFeeSompi.map(formatKas) ?? feeStatusText)
                        Divider()
                        reviewSummaryRow("Recovery Path", value: recoveryPath.rawValue)
                    }
                    .padding(.horizontal, 16)
                    .background(
                        Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Fee").font(.headline)
                        Picker("Fee", selection: $selectedFee) {
                            ForEach(feeChoices) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)
                        if selectedFee == .custom {
                            HStack(spacing: 10) {
                                TextField("0", text: $customFeeText)
                                    .keyboardType(.decimalPad)
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                Text(preferences.network.currencySymbol)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        if feeEstimate == nil, selectedFee != .custom, !isRefreshingFee {
                            Button("Refresh Fee Estimate", systemImage: "arrow.clockwise") {
                                Task { await refreshFeeEstimate() }
                            }
                            .font(.caption.weight(.medium))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("Summary")
            }

            Section {
                Button {
                    persistSetupDraft(step: .destinations)
                    showingWalletFundingReview = true
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .modifier(ProtectedVaultActionButtonModifier(isProtectedVault: true))
                .controlSize(.large)
                .disabled(descriptor == nil || !verifiedApprovedDestinations || !fundingPlanIsValid)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await deriveDescriptor()
            await refreshFeeEstimate()
            guard verifiedApprovedDestinations else { return }
            guard !hasAppliedResumeStep else { return }
            hasAppliedResumeStep = true
            switch resumeStep {
            case .rules:
                break
            case .destinations:
                showingWalletFundingReview = true
            case .reviewDetails:
                if fundingPlanIsValid {
                    showingWalletFundingReview = true
                }
            case .review, nil:
                break
            }
        }
        .onChange(of: selectedFee) { _, choice in
            persistSetupDraft(step: setupDraft?.step ?? .review)
            guard profile.network == KaspaNetwork.testnet10.rawValue, choice == .normal else { return }
            Task { await refreshFeeEstimate() }
        }
        .onChange(of: customFeeText) { _, _ in
            persistSetupDraft(step: setupDraft?.step ?? .review)
        }
        .navigationDestination(isPresented: $showingWalletFundingReview) {
            if let descriptor {
                ReviewWalletFundingView(
                    approvedAddresses: approvedAddresses,
                    recoveryAddress: recoveryAddress,
                    vaultAddress: descriptor.vaultAddress,
                    checks: [
                        ProtectedVaultSecurityCheck(title: "Approved destinations are valid \(preferences.network.title) addresses", passed: approvedAddressCheckPassed),
                        ProtectedVaultSecurityCheck(title: "Covenant rules were generated from these destinations", passed: covenantRuleCheckPassed),
                        ProtectedVaultSecurityCheck(title: "Vault address is valid and derived from the covenant", passed: vaultAddressCheckPassed)
                    ],
                    derivationError: derivationError,
                    autoContinueToDetails: resumeStep == .reviewDetails,
                    onReviewVaultDetails: prepareVaultForFunding
                )
            }
        }
    }

    private var approvedAddresses: [String] {
        rules.approvedAddresses.prefix(rules.approvedAddressCount).map {
            $0.address.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var recoveryAddress: String {
        rules.recoveryAddress.address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var recoveryPath: ProtectedVault.RecoveryPath { rules.recoveryPath }
    private var delayDays: Int { rules.delayDays }
    private var delayHours: Int { rules.delayHours }
    private var delayMinutes: Int { rules.delayMinutes }

    private var feeChoices: [VaultFundingFeeChoice] {
        profile.network == KaspaNetwork.testnet10.rawValue ? [.normal, .custom] : VaultFundingFeeChoice.allCases
    }

    private var requestedFeeSompi: UInt64? {
        if selectedFee == .custom { return parseKasTextToSompi(customFeeText) }
        guard let estimate = feeEstimate, estimate.normalSompiPerGram > 0 else { return nil }
        if profile.network == KaspaNetwork.testnet10.rawValue {
            return protectedVaultNormalFeeEstimate(estimate: estimate, inputCount: selectedUTXOs.count)
        }
        let rate: Double
        switch selectedFee {
        case .low: rate = estimate.lowSompiPerGram
        case .normal: rate = estimate.normalSompiPerGram
        case .priority: rate = estimate.prioritySompiPerGram
        case .custom: return nil
        }
        let mass = ceil(Double(estimate.suggestedFee) / estimate.normalSompiPerGram)
        let fee = mass * rate
        guard fee.isFinite, fee > 0, fee <= Double(UInt64.max) else { return nil }
        return UInt64(fee)
    }

    private var fundingPlanIsValid: Bool {
        guard let fee = requestedFeeSompi else { return false }
        let total = selectedInputTotal
        return total > fee && total != UInt64.max
    }

    private var feeStatusText: String {
        isRefreshingFee ? "Updating…" : "Unavailable"
    }

    private var feeDescription: String {
        guard let fee = requestedFeeSompi else {
            return selectedFee == .custom ? "Enter a positive exact fee in \(preferences.network.currencySymbol)." : "Waiting for a live fee estimate."
        }
        guard selectedInputTotal > fee else { return "The selected inputs cannot cover this fee." }
        return "\(selectedFee.title) • \(formatKas(fee)); the remaining input value funds the vault."
    }

    private func parseKasTextToSompi(_ text: String) -> UInt64? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard !raw.isEmpty, !raw.contains("-"), !raw.lowercased().contains("e"), parts.count <= 2,
              let whole = UInt64(parts[0]), parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        let fractional = parts.count == 2 ? String(parts[1]) : ""
        guard fractional.count <= 8 else { return nil }
        let wholeSompi = whole.multipliedReportingOverflow(by: 100_000_000)
        guard !wholeSompi.overflow, let fraction = UInt64(fractional.padding(toLength: 8, withPad: "0", startingAt: 0)) else { return nil }
        let total = wholeSompi.partialValue.addingReportingOverflow(fraction)
        return !total.overflow && total.partialValue > 0 ? total.partialValue : nil
    }

    @MainActor
    private func refreshFeeEstimate() async {
        guard !isRefreshingFee else { return }
        isRefreshingFee = true
        defer { isRefreshingFee = false }
        do {
            feeEstimate = try await engine.getFeeEstimate(
                nodeConfiguration: preferences.nodeConfiguration
            )
            feeEstimateError = nil
        } catch {
            feeEstimate = nil
            feeEstimateError = error.localizedDescription
        }
    }

    private var delaySummary: String {
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

    private var selectedInputTotal: UInt64 {
        selectedUTXOs.reduce(0) { total, utxo in
            let sum = total.addingReportingOverflow(utxo.amount)
            return sum.overflow ? UInt64.max : sum.partialValue
        }
    }

    private func formatKas(_ sompi: UInt64) -> String {
        "\((Decimal(sompi) / Decimal(100_000_000)).formatted()) \(preferences.network.currencySymbol)"
    }

    private func reviewSummaryRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 13)
    }

    private func prepareVaultForFunding() {
        guard let fee = requestedFeeSompi,
              selectedInputTotal > fee,
              let descriptor
        else { return }

        persistSetupDraft(step: .reviewDetails)

        let amount = Decimal(selectedInputTotal - fee) / Decimal(100_000_000)
        let vault = ProtectedVault(
            id: setupDraft?.id ?? UUID(),
            profileID: profile.id,
            amount: amount,
            usesSendMaxFunding: true,
            approvedAddresses: approvedAddresses,
            recoveryAddress: recoveryAddress,
            recoveryPath: recoveryPath,
            delayDays: delayDays,
            delayHours: delayHours,
            delayMinutes: delayMinutes,
            ownerDerivationIndex: descriptor.ownerDerivationIndex,
            ownerPublicKey: descriptor.ownerPublicKey,
            redeemScriptHex: descriptor.redeemScriptHex,
            vaultAddress: descriptor.vaultAddress
        )
        onCreated(vault, selectedUTXOs, ProtectedVaultFundingFeeSelection(choice: selectedFee, customFeeText: customFeeText))
    }

    private func persistSetupDraft(step: ProtectedVaultSetupDraft.Step) {
        guard var draft = setupDraft else { return }
        draft.feeChoiceRawValue = selectedFee.rawValue
        draft.customFeeText = customFeeText
        draft.step = step
        protectedVaultStore.saveSetupDraft(draft)
    }

    @MainActor
    private func deriveDescriptor() async {
        guard descriptor == nil,
              let profile = walletStore.profiles.first(where: { $0.id == self.profile.id }),
              let delayDAA
        else { return }

        approvedAddressCheckPassed = nil
        covenantRuleCheckPassed = nil
        vaultAddressCheckPassed = nil
        verifiedApprovedDestinations = false

        do {
            let normalizedAddresses = approvedAddresses.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !normalizedAddresses.isEmpty,
                  normalizedAddresses.count <= 5,
                  Set(normalizedAddresses.map { $0.lowercased() }).count == normalizedAddresses.count
            else {
                throw KasSignerEngine.EngineError.javascript(
                    "Approved addresses must be unique and limited to five."
                )
            }

            for address in normalizedAddresses {
                let validation = try await engine.validateAddress(address)
                guard validation.valid,
                      validation.network == profile.network,
                      validation.normalized?.caseInsensitiveCompare(address) == .orderedSame
                else {
                    throw KasSignerEngine.EngineError.javascript(
                        "An approved destination failed address verification for \(profile.network)."
                    )
                }
            }
            let normalizedRecoveryAddress = recoveryAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let recoveryValidation = try await engine.validateAddress(normalizedRecoveryAddress)
            guard recoveryValidation.valid,
                  recoveryValidation.network == profile.network,
                  recoveryValidation.normalized?.caseInsensitiveCompare(normalizedRecoveryAddress) == .orderedSame,
                  !normalizedAddresses.contains(where: {
                      $0.caseInsensitiveCompare(normalizedRecoveryAddress) == .orderedSame
                  })
            else {
                throw KasSignerEngine.EngineError.javascript(
                    "The recovery address must be valid for this network and distinct from approved destinations."
                )
            }
            approvedAddressCheckPassed = true

            let derived = try await engine.deriveProtectedVault(
                profile: profile,
                receiveIndex: profile.nextReceiveIndex,
                approvedAddresses: normalizedAddresses,
                recoveryAddress: recoveryAddress,
                emergencyAnytime: recoveryPath == .emergencyAnytime,
                delayDAA: delayDAA
            )
            guard !derived.redeemScriptHex.isEmpty,
                  !derived.scriptHashHex.isEmpty,
                  !derived.vaultAddress.isEmpty
            else {
                throw KasSignerEngine.EngineError.javascript(
                    "The covenant script or its vault address could not be verified."
                )
            }
            if preferences.network == .testnet10 {
                guard derived.scriptVersion == 2,
                      derived.recoveryAddress?.caseInsensitiveCompare(normalizedRecoveryAddress) == .orderedSame,
                      derived.recoveryPath == (recoveryPath == .emergencyAnytime
                          ? "emergencyAnytime" : "cancelPendingWithdrawal")
                else {
                    throw KasSignerEngine.EngineError.javascript(
                        "The covenant did not commit the selected recovery rules."
                    )
                }
            }
            covenantRuleCheckPassed = true

            let vaultAddressValidation = try await engine.validateAddress(derived.vaultAddress)
            guard vaultAddressValidation.valid,
                  vaultAddressValidation.network == profile.network,
                  vaultAddressValidation.normalized?.caseInsensitiveCompare(derived.vaultAddress) == .orderedSame
            else {
                throw KasSignerEngine.EngineError.javascript(
                    "The derived vault address failed address verification for \(profile.network)."
                )
            }

            descriptor = derived
            vaultAddressCheckPassed = true
            verifiedApprovedDestinations = true
            derivationError = nil
        } catch {
            verifiedApprovedDestinations = false
            if approvedAddressCheckPassed == nil { approvedAddressCheckPassed = false }
            if covenantRuleCheckPassed == nil { covenantRuleCheckPassed = false }
            if vaultAddressCheckPassed == nil { vaultAddressCheckPassed = false }
            derivationError = "Vault address could not be derived: \(error.localizedDescription)"
        }
    }

    private var delayDAA: UInt64? {
        let dayMinutes = delayDays.multipliedReportingOverflow(by: 24 * 60)
        guard !dayMinutes.overflow else { return nil }
        let hourMinutes = delayHours.multipliedReportingOverflow(by: 60)
        guard !hourMinutes.overflow else { return nil }
        let daysAndHours = dayMinutes.partialValue.addingReportingOverflow(hourMinutes.partialValue)
        guard !daysAndHours.overflow else { return nil }
        let totalMinutes = daysAndHours.partialValue.addingReportingOverflow(delayMinutes)
        guard !totalMinutes.overflow, totalMinutes.partialValue > 0 else { return nil }
        let daa = UInt64(totalMinutes.partialValue).multipliedReportingOverflow(by: 60 * 10)
        return daa.overflow ? nil : daa.partialValue
    }
}

private struct ReviewWalletFundingView: View {
    let approvedAddresses: [String]
    let recoveryAddress: String
    let vaultAddress: String
    let checks: [ProtectedVaultSecurityCheck]
    let derivationError: String?
    var autoContinueToDetails = false
    let onReviewVaultDetails: () -> Void

    @EnvironmentObject private var preferences: AppPreferences
    @State private var hasAutoContinued = false

    var body: some View {
        Form {
            Section {
                ForEach(Array(approvedAddresses.enumerated()), id: \.offset) { index, address in
                    ProtectedVaultAddressDisplayCard(title: "Approved Address \(index + 1)", address: address)
                        .padding(.bottom, 12)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                ProtectedVaultAddressDisplayCard(title: "Recovery Address", address: recoveryAddress)
                    .padding(.bottom, 12)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                ProtectedVaultAddressDisplayCard(title: "Vault Address", address: vaultAddress)
                    .padding(.bottom, 12)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                ProtectedVaultSecurityChecksCard(checks: checks, showsTitle: false)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                if let derivationError {
                    Text(derivationError).font(.footnote).foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                }
            } header: {
                Text("Security Checks")
            }

            Section {
                Button(action: onReviewVaultDetails) {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .modifier(ProtectedVaultActionButtonModifier(isProtectedVault: true))
                .controlSize(.large)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Destinations")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard autoContinueToDetails, !hasAutoContinued else { return }
            hasAutoContinued = true
            onReviewVaultDetails()
        }
    }
}

private struct ProtectedVaultDetailView: View {
    let vault: ProtectedVault
    let onFund: () -> Void
    let onSpend: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var protectedVaultStore: ProtectedVaultStore
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var walletStore: WalletStore
    @State private var showingDeleteConfirmation = false
    @State private var showingRenamePrompt = false
    @State private var showingConsensusDetails = false
    @State private var renameText = ""
    @State private var isRefreshing = false
    @State private var showingRefreshDetails = false
    @State private var currentVaultOutputs: [WalletUTXO] = []

    var body: some View {
        let refreshState = protectedVaultStore.refreshState(for: vault.id)
        Form {
            Section("Summary") {
                LabeledContent {
                    if vault.status == .spent || vault.status == .active {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                            Text(vault.status == .spent ? "Spent" : "Active")
                        }
                        .fixedSize()
                        .foregroundStyle(.green)
                    } else {
                        Text(vault.status.title)
                            .foregroundStyle(vault.status == .localDraft ? .orange : .primary)
                    }
                } label: {
                    Text("Status")
                }
                let balance = vault.status == .spent ? Decimal.zero : (vault.lockedAmount ?? vault.amount)
                LabeledContent("Balance", value: "\(balance.formatted()) \(preferences.network.currencySymbol)")
                LabeledContent("Approved Addresses", value: "\(vault.approvedAddresses.count)")
                LabeledContent(
                    "Security Delay",
                    value: vault.delaySummary.isEmpty ? "None" : vault.delaySummary
                )
                LabeledContent(
                    "Recovery Path",
                    value: vault.recoveryPath?.rawValue ?? "Not configured"
                )
                LabeledContent(
                    "Created",
                    value: (vault.fundedAt ?? vault.createdAt).formatted(date: .abbreviated, time: .shortened)
                )
                DisclosureGroup("On-Chain Data", isExpanded: $showingRefreshDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        if refreshState.isRefreshing {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                Text("Refreshing on-chain data…")
                            }
                                .foregroundStyle(.secondary)
                        } else if !refreshState.isStale,
                                  refreshState.lastSuccessfulInfo != nil {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                Text("On-chain data verified")
                            }
                                .foregroundStyle(.green)
                        } else if !refreshState.isStale {
                            HStack(spacing: 6) {
                                Image(systemName: "questionmark.circle")
                                Text("On-chain state not checked yet")
                            }
                                .foregroundStyle(.secondary)
                        }
                        if let info = refreshState.lastSuccessfulInfo {
                            Text("Last verified: \(info.network) · \(info.nodeLabel) · \(info.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                }
                if refreshState.isStale {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            refreshState.lastSuccessfulInfo == nil
                                ? "On-chain state not verified"
                                : "Showing last verified data",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        if let errorMessage = refreshState.errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button("Retry") {
                            Task { await refreshVault() }
                        }
                        .disabled(isRefreshing)
                    }
                    .font(.subheadline)
                }
            }

            if let transactionID = vault.fundingTransactionID {
                transactionCard(title: "Vault Funding Transaction", transactionID: transactionID)
                    .padding(.top, -6)
            }

            let unsupportedDeposits = ProtectedVaultStageOutput.classify(currentVaultOutputs)
                .filter { !$0.isCovenantTagged }
            if !unsupportedDeposits.isEmpty {
                Section("Unsupported Deposits") {
                    Text("These outputs are at the vault address but are not covenant-tagged, so they cannot be spent through the protected-vault flow. They do not prevent spending a separately selected covenant output.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(unsupportedDeposits) { output in
                        LabeledContent(
                            "\(formatTKAS(output.utxo.amount)) · \(shortOutpoint(output.utxo.id))",
                            value: "Unsupported"
                        )
                    }
                }
            }

            if vault.status == .spent {
                if let transactionID = vault.approvedWithdrawalTransactionID {
                    transactionCard(title: "Approved Withdrawal Transaction", transactionID: transactionID)
                }
                ForEach(vault.pendingWithdrawals) { withdrawal in
                    if !withdrawal.transactionID.isEmpty {
                        transactionCard(
                            title: "Withdrawal Initiated (1 of 2)",
                            transactionID: withdrawal.transactionID
                        )
                    }
                    if let transactionID = withdrawal.completionTransactionID,
                       !transactionID.isEmpty {
                        transactionCard(
                            title: pendingWithdrawalCompletionTitle(for: withdrawal),
                            transactionID: transactionID
                        )
                    }
                }
            }

            Section {
                if hasConsensusDetails {
                    Button {
                        showingConsensusDetails = true
                    } label: {
                        HStack {
                            Text("Advanced")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color(red: 0.20, green: 0.62, blue: 0.57))
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }

            if preferences.network == .testnet10,
               let pending = vault.pendingWithdrawals.last(where: { $0.completedAt == nil }) {
                Section("Security Delay in Progress") {
                    Text("Waiting for the configured delay to finish.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ProtectedVaultAddressDisplayCard(title: "Committed Destination", address: pending.destinationAddress)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    if !pending.transactionID.isEmpty {
                        Link("View withdrawal transaction", destination: preferences.explorer.transactionURL(pending.transactionID, network: preferences.network))
                    }
                }
            }

            let hasCovenantOutput = ProtectedVaultStageOutput.classify(currentVaultOutputs)
                .contains { $0.isCovenantTagged }
            if vault.status == .active ||
                (preferences.network == .testnet10 && vault.status == .pendingWithdrawal) ||
                (vault.status == .incompatibleFunding && hasCovenantOutput) {
                Section {
                    Button(action: onSpend) {
                        Text("Spend from Vault")
                            .frame(maxWidth: .infinity)
                    }
                    .modifier(ProtectedVaultActionButtonModifier(isProtectedVault: true))
                    .controlSize(.large)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } else if vault.status == .localDraft {
                Section {
                    Button(action: onFund) {
                        Text("Fund Protected Vault")
                            .frame(maxWidth: .infinity)
                    }
                    .modifier(ProtectedVaultActionButtonModifier(isProtectedVault: true))
                    .controlSize(.large)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

        }
        .listSectionSpacing(12)
        .navigationTitle("Vault Status")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshVault() }
        .refreshable { await refreshVault() }
        .navigationDestination(isPresented: $showingConsensusDetails) {
            ProtectedVaultConsensusDetailsView(
                vault: vault,
                outputs: currentVaultOutputs
            )
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename Vault", systemImage: "pin") {
                        renameText = vault.displayName
                        showingRenamePrompt = true
                    }
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label(deleteMenuTitle, systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Vault Options")
            }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(deleteConfirmationAction, role: .destructive) {
                protectedVaultStore.remove(id: vault.id)
                dismiss()
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .alert("Rename Vault", isPresented: $showingRenamePrompt) {
            TextField("Vault name", text: $renameText)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                protectedVaultStore.rename(id: vault.id, to: renameText)
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Choose a name for this vault.")
        }
    }

    @MainActor
    private func refreshVault() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if let outputs = try? await protectedVaultStore.refreshOnChain(
                id: vault.id,
                engine: engine,
                preferences: preferences
        ) {
            currentVaultOutputs = outputs
        }
    }

    private func formatTKAS(_ sompi: UInt64) -> String {
        "\((Decimal(sompi) / 100_000_000).formatted()) TKAS"
    }

    private func shortOutpoint(_ outpoint: String) -> String {
        guard outpoint.count > 20 else { return outpoint }
        return "\(outpoint.prefix(10))…\(outpoint.suffix(8))"
    }

    private func transactionCard(title: String, transactionID: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline.weight(.semibold))

                Link(destination: preferences.explorer.transactionURL(
                    transactionID,
                    network: preferences.network
                )) {
                    Text(transactionID)
                        .font(.body.monospaced())
                        .foregroundStyle(Color(red: 0.20, green: 0.62, blue: 0.57))
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            Color(.tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                        }
                }
                .accessibilityLabel("Open \(title.lowercased()) transaction \(transactionID)")
                .tint(Color(red: 0.20, green: 0.62, blue: 0.57))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func pendingWithdrawalCompletionTitle(
        for withdrawal: ProtectedVault.PendingWithdrawal
    ) -> String {
        switch withdrawal.completionOutcome {
        case .some(.recovery):
            return "Recovery Transaction (Canceled Withdrawal)"
        case .some(.delayCompleted):
            return "Withdrawal Completion Transaction (Security Delay Satisfied)"
        case .none:
            guard let transactionID = withdrawal.completionTransactionID,
                  let transaction = walletStore.transactions.first(where: {
                      $0.transactionID.caseInsensitiveCompare(transactionID) == .orderedSame
                  }) else {
                return "Withdrawal Completed (2 of 2)"
            }

            let destination = transaction.destination
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if let recoveryAddress = vault.recoveryAddress,
               destination == recoveryAddress
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() {
                return "Recovery Transaction (Canceled Withdrawal)"
            }
            if destination == withdrawal.destinationAddress
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                return "Withdrawal Completion Transaction (Security Delay Satisfied)"
            }
            return "Withdrawal Completed (2 of 2)"
        }
    }

    private var hasOnChainState: Bool {
        vault.status == .active || vault.status == .pendingWithdrawal
            || vault.status == .fundingBroadcast || vault.status == .incompatibleFunding
    }

    private var hasConsensusDetails: Bool {
        vault.fundingTransactionID != nil
            || !vault.fundingOutpoints.isEmpty
            || !vault.covenantIDs.isEmpty
            || vault.approvedWithdrawalTransactionID != nil
            || !vault.pendingWithdrawals.isEmpty
    }

    private var deleteConfirmationTitle: String {
        if hasOnChainState { return "Remove this vault from the app?" }
        return vault.status == .spent ? "Remove completed vault?" : "Delete this vault draft?"
    }

    private var deleteMenuTitle: String {
        hasOnChainState ? "Remove Vault Record" : "Delete Vault"
    }

    private var deleteConfirmationAction: String {
        if hasOnChainState { return "Remove Local Record" }
        return vault.status == .spent ? "Remove Record" : "Delete Draft"
    }

    private var deleteConfirmationMessage: String {
        if hasOnChainState {
            return "This vault has on-chain funds or funding history. Removing its local record will not move or recover funds, and removes the saved vault details needed to manage it in this app."
        }
        return vault.status == .spent
            ? "This removes the completed vault’s local history from this app."
            : "This removes the unfunded vault draft from this app."
    }
}

private struct ProtectedVaultConsensusDetailsView: View {
    let vault: ProtectedVault
    let outputs: [WalletUTXO]

    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        List {
            Section("On-chain Outputs") {
                if outputs.isEmpty {
                    Text(vault.status == .spent
                         ? "No live vault outputs remain for this spent vault. The saved covenant script is available below."
                         : "No live vault outputs are loaded. Return to the vault and refresh, then open Advanced again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(outputs.enumerated()), id: \.element.id) { index, output in
                        outputCard(output, index: index)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
            }

            Section("Covenant Script") {
                if let script = vault.redeemScriptHex, !script.isEmpty {
                    LabeledContent("Redeem script", value: "Saved")
                    LabeledContent("Script size", value: "\(script.count / 2) bytes")
                    DisclosureGroup("View redeem script") {
                        Text(script)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .lineSpacing(3)
                            .padding(.vertical, 6)
                    }
                } else {
                    LabeledContent("Redeem script", value: "Unavailable")
                }
            }

        }
        .listStyle(.insetGrouped)
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func outputCard(_ output: WalletUTXO, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Output \(index + 1)")
                    .font(.headline)
                Spacer()
                Label(
                    output.covenantID == nil ? "ID Missing" : "ID Present",
                    systemImage: output.covenantID == nil ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(
                    output.covenantID == nil
                        ? .orange
                        : Color(red: 0.20, green: 0.62, blue: 0.57)
                )
            }

            LabeledContent(
                "Value",
                value: "\(output.amountKas.formatted()) \(preferences.network.currencySymbol)"
            )
            LabeledContent("DAA score", value: output.blockDAAScore.formatted())

            VStack(alignment: .leading, spacing: 5) {
                Text("Outpoint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(output.id)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Link(
                    destination: preferences.explorer.transactionURL(
                        output.txID,
                        network: preferences.network
                    )
                ) {
                    Label("View transaction", systemImage: "arrow.up.right.square")
                        .font(.footnote.weight(.medium))
                }
            }

            if let covenantID = output.covenantID {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Covenant ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(covenantID)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .padding(.vertical, 5)
    }

}

private struct TestnetProtectedVaultSpendView: View {
    private struct PreparedSpend {
        let signedPSKB: String
        let path: SpendPath
        let destination: String
        let outputAddress: String
        let amountSompi: UInt64
        let feeSompi: UInt64
        let sourceAddress: String
        let sourceOutpoint: String
        let pendingDescriptor: ProtectedVaultPendingDescriptor?
        let pendingID: UUID?
    }

    private enum SpendPath: String, CaseIterable, Identifiable {
        case approved = "Approved destination"
        case beginDelay = "Other Destination (Security Delay Required)"
        case emergency = "Emergency recovery"
        case mature = "Complete delayed withdrawal"
        case cancel = "Cancel to recovery address"
        var id: Self { self }
        var runtimePath: String {
            switch self {
            case .approved: "approved"
            case .beginDelay: "beginDelay"
            case .emergency: "emergency"
            case .mature: "mature"
            case .cancel: "cancel"
            }
        }
    }

    let vaultID: UUID
    let onBroadcast: (String, String?, Bool) -> Void
    @EnvironmentObject private var appLockService: AppLockService
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var protectedVaultStore: ProtectedVaultStore
    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var walletStore: WalletStore
    @State private var path: SpendPath = .approved
    @State private var approvedAddress = ""
    @State private var otherAddress = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var transactionID: String?
    @State private var feeSompi: UInt64 = 500_000
    @State private var stageOutputs: [ProtectedVaultStageOutput] = []
    @State private var selectedStageOutpoint = ""
    @State private var preparedSpend: PreparedSpend?
    @State private var isRestoringPreparedReview = false
    @State private var didInitializePendingSpendPath = false

    private var vault: ProtectedVault? {
        protectedVaultStore.vaults.first { $0.id == vaultID }
    }

    private var spendableStageOutputs: [ProtectedVaultStageOutput] {
        stageOutputs.filter { $0.canCoverFee(feeSompi) }
    }

    private var unsupportedStageOutputs: [ProtectedVaultStageOutput] {
        stageOutputs.filter { !$0.isCovenantTagged }
    }

    private var selectedStageOutput: ProtectedVaultStageOutput? {
        if spendableStageOutputs.count == 1 { return spendableStageOutputs[0] }
        return spendableStageOutputs.first { $0.id == selectedStageOutpoint }
    }

    private var availablePaths: [SpendPath] {
        guard let vault else { return [] }
        if vault.status == .pendingWithdrawal {
            return recoveryWalletAvailable ? [.mature, .cancel] : [.mature]
        }
        if vault.recoveryPath == .emergencyAnytime && recoveryWalletAvailable {
            return [.approved, .beginDelay, .emergency]
        }
        return [.approved, .beginDelay]
    }

    private var recoveryWalletAvailable: Bool {
        guard let recovery = vault?.recoveryAddress else { return false }
        return walletStore.profiles.contains { profile in
            profile.network == KaspaNetwork.testnet10.rawValue
                && (profile.receiveAddresses + profile.changeAddresses).contains {
                    $0.caseInsensitiveCompare(recovery) == .orderedSame
                }
        }
    }

    var body: some View {
        Form {
            if let vault {
                if vault.status == .spent {
                    Section("Withdrawal Complete") {
                        Text("The vault output has been spent.")
                            .foregroundStyle(.secondary)
                    }
                } else if isRestoringPreparedReview {
                    Section("Summary") {
                        ProgressView("Rechecking the 2/2 transaction…")
                    }
                } else if let preparedSpend {
                    Section("Summary") {
                        if preparedSpend.path == .mature {
                            VStack(spacing: 0) {
                                LabeledContent("Transaction", value: transactionSummaryTitle(for: preparedSpend.path))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                Divider().padding(.leading, 16)
                                LabeledContent("Amount to Send", value: formatTKAS(preparedSpend.amountSompi))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                Divider().padding(.leading, 16)
                                LabeledContent("Network Fee", value: formatTKAS(preparedSpend.feeSompi))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                Divider().padding(.leading, 16)
                                ProtectedVaultAddressDisplayCard(
                                    title: "Committed Destination",
                                    address: preparedSpend.destination,
                                    embedded: true
                                )
                                .padding(16)
                            }
                            .background(
                                Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                        } else {
                            VStack(spacing: 0) {
                                if preparedSpend.path != .approved {
                                    LabeledContent("Transaction", value: transactionSummaryTitle(for: preparedSpend.path))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 12)
                                    Divider().padding(.leading, 16)
                                }
                                LabeledContent("Spending Path", value: preparedSpend.path.rawValue)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                Divider().padding(.leading, 16)
                                LabeledContent("Amount to Send", value: formatTKAS(preparedSpend.amountSompi))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                Divider().padding(.leading, 16)
                                LabeledContent("Network Fee", value: formatTKAS(preparedSpend.feeSompi))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                Divider().padding(.leading, 16)
                                ProtectedVaultAddressDisplayCard(
                                    title: preparedSpend.path == .approved ? "Approved Destination" : "Destination",
                                    address: preparedSpend.destination,
                                    embedded: true
                                )
                                .padding(16)
                            }
                            .background(
                                Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                        }
                    }
                    Section {
                        Button {
                            Task { await broadcastPreparedSpend() }
                        } label: {
                            if isWorking { ProgressView().frame(maxWidth: .infinity) }
                            else {
                                Text(broadcastButtonTitle(for: preparedSpend.path))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .modifier(ProtectedVaultActionButtonModifier(isProtectedVault: true))
                        .disabled(isWorking)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } else {
                    if vault.status == .pendingWithdrawal,
                       let pending = vault.pendingWithdrawals.first(where: { $0.completedAt == nil }) {
                        Section("Withdrawal Progress") {
                            VStack(spacing: 0) {
                                LabeledContent("Transaction", value: "1 of 2 · Security delay started")
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                Divider().padding(.leading, 16)
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    LabeledContent("Security Delay") {
                                        Text(remainingDelayText(
                                            for: pending,
                                            delayDAA: delayDAA(for: vault),
                                            at: context.date
                                        ))
                                            .foregroundStyle(.red)
                                            .monospacedDigit()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                }
                                Divider().padding(.leading, 16)
                                Group {
                                    if let pendingBlockDAAScore = pending.pendingBlockDAAScore {
                                        LabeledContent(
                                            "Spendable at DAA score",
                                            value: (pendingBlockDAAScore + delayDAA(for: vault)).formatted()
                                        )
                                    } else {
                                        LabeledContent("Spendable at DAA score", value: "Waiting for confirmation")
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                Divider().padding(.leading, 16)
                                ProtectedVaultInfoCard(
                                    message: "The countdown is an estimate. The DAA threshold is enforced by consensus before the withdrawal can be completed.",
                                    symbol: "checkmark.shield.fill"
                                )
                                .padding(16)
                            }
                            .background(
                                Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                        }
                    }
                    Section("Spend Path") {
                        Picker("Action", selection: $path) {
                            ForEach(availablePaths) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        LabeledContent("Estimated Amount", value: estimatedAmountText(for: vault))
                        LabeledContent("Network Fee", value: formatTKAS(feeSompi))
                        if spendableStageOutputs.count > 1 {
                            Picker("Covenant Output", selection: $selectedStageOutpoint) {
                                Text("Select an output").tag("")
                                ForEach(spendableStageOutputs) { output in
                                    Text("\(formatTKAS(output.utxo.amount)) · \(shortOutpoint(output.utxo.id))")
                                        .tag(output.id)
                                }
                            }
                            .pickerStyle(.navigationLink)
                        } else if spendableStageOutputs.count == 1,
                                  let output = spendableStageOutputs.first {
                            LabeledContent("Covenant Output", value: "\(formatTKAS(output.utxo.amount)) · \(shortOutpoint(output.utxo.id))")
                        } else {
                            Text("No spendable covenant-tagged output is currently available at this stage.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if path == .approved {
                            LabeledContent("Security Delay", value: "None")
                        }
                        if path == .approved {
                            Picker(
                                vault.approvedAddresses.count == 1 ? "Approved Destination" : "Approved Destinations",
                                selection: $approvedAddress
                            ) {
                                Text("Select an approved destination").tag("")
                                ForEach(vault.approvedAddresses, id: \.self) { address in
                                    Text(address).tag(address)
                                }
                            }
                            .pickerStyle(.navigationLink)
                        } else if path == .beginDelay {
                            TextField("kaspatest:…", text: $otherAddress, axis: .vertical)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.subheadline, design: .monospaced))
                                .keyboardType(.asciiCapable)
                                .lineLimit(2...4)
                        } else if path == .emergency, let recovery = vault.recoveryAddress {
                            ProtectedVaultAddressDisplayCard(title: "Recovery Destination", address: recovery)
                        } else if let pending = vault.pendingWithdrawals.first(where: { $0.completedAt == nil }) {
                            ProtectedVaultAddressDisplayCard(
                                title: path == .cancel ? "Recovery Destination" : "Committed Destination",
                                address: path == .cancel ? (vault.recoveryAddress ?? "") : pending.destinationAddress
                            )
                        }
                    }
                    if !unsupportedStageOutputs.isEmpty {
                        Section("Unsupported Deposits") {
                            Text("These deposits are not covenant-tagged and cannot be spent through this vault flow. They are excluded from the output choices above.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            ForEach(unsupportedStageOutputs) { output in
                                LabeledContent(
                                    "\(formatTKAS(output.utxo.amount)) · \(shortOutpoint(output.utxo.id))",
                                    value: "Unsupported"
                                )
                            }
                        }
                    }
                    Section {
                        if path == .mature,
                           vault.status == .pendingWithdrawal,
                           let pending = vault.pendingWithdrawals.first(where: { $0.completedAt == nil }) {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Button {
                                    Task { await prepareSpend() }
                                } label: {
                                    if isWorking {
                                        ProgressView().frame(maxWidth: .infinity)
                                    } else {
                                        let remaining = remainingDelaySeconds(
                                            for: pending,
                                            delayDAA: delayDAA(for: vault),
                                            at: context.date
                                        )
                                        Text(pending.pendingBlockDAAScore == nil
                                             ? "Waiting for Confirmation"
                                             : (remaining > 0 ? "Waiting for Security Delay" : "Continue to 2/2 Transaction"))
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                                .modifier(ProtectedVaultActionButtonModifier(isProtectedVault: true))
                                .disabled(
                                    isWorking
                                        || pending.pendingBlockDAAScore == nil
                                        || selectedStageOutput == nil
                                        || (spendableStageOutputs.count > 1 && selectedStageOutpoint.isEmpty)
                                        || remainingDelaySeconds(
                                            for: pending,
                                            delayDAA: delayDAA(for: vault),
                                            at: context.date
                                        ) > 0
                                )
                            }
                        } else {
                            Button {
                                Task { await prepareSpend() }
                            } label: {
                                if isWorking { ProgressView().frame(maxWidth: .infinity) }
                                else {
                                    Text(prepareButtonTitle(for: path))
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .modifier(ProtectedVaultActionButtonModifier(isProtectedVault: true))
                            .disabled(isWorking
                                || transactionID != nil
                                || selectedStageOutput == nil
                                || (spendableStageOutputs.count > 1 && selectedStageOutpoint.isEmpty))
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                if let errorMessage {
                    Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle(preparedSpend == nil ? "Details" : "Review Withdrawal")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            var shouldRestorePreparedReview = false
            if let vault {
                approvedAddress = vault.approvedAddresses.first ?? ""
                if vault.status == .pendingWithdrawal {
                    if !didInitializePendingSpendPath {
                        path = .mature
                        didInitializePendingSpendPath = true
                    }
                    shouldRestorePreparedReview = vault.pendingWithdrawals
                        .first(where: { $0.completedAt == nil })?
                        .completionReviewRequested == true
                    isRestoringPreparedReview = shouldRestorePreparedReview
                    await refreshPendingDAAScore(for: vault)
                }
                await refreshStageOutputs(for: vault, path: path)
            }
            if let estimate = try? await engine.getFeeEstimate(nodeConfiguration: preferences.nodeConfiguration) {
                feeSompi = min(10_000_000, max(500_000, estimate.suggestedFee))
            }
            if shouldRestorePreparedReview {
                await prepareSpend()
                isRestoringPreparedReview = false
            }
        }
        .onChange(of: path) { _, newPath in
            guard let vault else { return }
            Task { await refreshStageOutputs(for: vault, path: newPath) }
        }
    }

    private func formatTKAS(_ sompi: UInt64) -> String {
        "\((Decimal(sompi) / 100_000_000).formatted()) TKAS"
    }

    private func shortOutpoint(_ outpoint: String) -> String {
        guard outpoint.count > 20 else { return outpoint }
        return "\(outpoint.prefix(10))…\(outpoint.suffix(8))"
    }

    private func prepareButtonTitle(for path: SpendPath) -> String {
        switch path {
        case .beginDelay: "Prepare Delay Transaction"
        case .mature: "Prepare Completion Transaction"
        default: "Prepare Withdrawal"
        }
    }

    private func broadcastButtonTitle(for path: SpendPath) -> String {
        switch path {
        case .beginDelay: "Start Security Delay"
        case .mature: "Complete Vault Withdrawal"
        case .approved, .emergency, .cancel: "Broadcast Transaction"
        }
    }

    private func transactionSummaryTitle(for path: SpendPath) -> String {
        switch path {
        case .approved: "Single transaction · Approved destination"
        case .beginDelay: "1 of 2 · Start security delay"
        case .mature: "2 of 2 · Complete withdrawal"
        case .emergency: "Single transaction · Emergency recovery"
        case .cancel: "Single transaction · Cancel delayed withdrawal"
        }
    }

    private func delayDAA(for vault: ProtectedVault) -> UInt64 {
        let minutes = vault.delayDays * 1440 + vault.delayHours * 60 + vault.delayMinutes
        return UInt64(max(0, minutes)) * 600
    }

    private func remainingDelayText(
        for pending: ProtectedVault.PendingWithdrawal,
        delayDAA: UInt64,
        at date: Date
    ) -> String {
        let remaining = Int(remainingDelaySeconds(for: pending, delayDAA: delayDAA, at: date).rounded(.up))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        let seconds = remaining % 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m \(seconds)s" }
        if hours > 0 { return "\(hours)h \(minutes)m \(seconds)s" }
        return "\(minutes)m \(seconds)s"
    }

    private func remainingDelaySeconds(
        for pending: ProtectedVault.PendingWithdrawal,
        delayDAA: UInt64,
        at date: Date
    ) -> TimeInterval {
        let estimatedDelaySeconds = TimeInterval(delayDAA / 10)
        return max(0, pending.createdAt.addingTimeInterval(estimatedDelaySeconds).timeIntervalSince(date))
    }

    @MainActor
    private func refreshStageOutputs(for vault: ProtectedVault, path: SpendPath) async {
        guard preferences.network == .testnet10 else { return }
        let pending = vault.pendingWithdrawals.first { $0.completedAt == nil }
        let sourceAddress = (path == .mature || path == .cancel)
            ? pending?.pendingAddress
            : vault.vaultAddress
        guard let sourceAddress else { return }
        do {
            let sync = try await engine.syncAddress(
                sourceAddress,
                nodeConfiguration: preferences.nodeConfiguration
            )
            let outputs = ProtectedVaultStageOutput.classify(sync.utxos)
            stageOutputs = outputs
            let candidates = outputs.filter { $0.canCoverFee(feeSompi) }
            if candidates.count == 1 {
                selectedStageOutpoint = candidates[0].id
            } else if !candidates.contains(where: { $0.id == selectedStageOutpoint }) {
                selectedStageOutpoint = ""
            }
        } catch {
            // The explicit prepare action retries the lookup before building.
        }
    }

    @MainActor
    private func refreshPendingDAAScore(for vault: ProtectedVault) async {
        guard preferences.network == .testnet10,
              vault.status == .pendingWithdrawal,
              let pending = vault.pendingWithdrawals.first(where: { $0.completedAt == nil }) else { return }
        do {
            let result = try await engine.syncAddress(
                pending.pendingAddress,
                nodeConfiguration: preferences.nodeConfiguration
            )
            guard let utxo = ProtectedVaultStageOutput.classify(result.utxos)
                .filter({ $0.isCovenantTagged })
                .map(\.utxo)
                .sorted(by: { $0.id < $1.id })
                .first else { return }
            protectedVaultStore.recordPendingWithdrawal(
                id: vault.id,
                destination: pending.destinationAddress,
                pendingAddress: pending.pendingAddress,
                transactionID: pending.transactionID,
                pendingBalanceSompi: utxo.amount,
                pendingBlockDAAScore: utxo.blockDAAScore
            )
        } catch {
            // Retry the node lookup the next time this screen is opened.
        }
    }

    private func estimatedAmountText(for vault: ProtectedVault) -> String {
        let balanceSompi = selectedStageOutput?.utxo.amount
            ?? vault.lockedSompi
            ?? NSDecimalNumber(decimal: vault.amount * Decimal(100_000_000)).uint64Value
        return formatTKAS(balanceSompi > feeSompi ? balanceSompi - feeSompi : 0)
    }

    @MainActor
    private func prepareSpend() async {
        guard !isWorking, preferences.network == .testnet10,
              let vault, availablePaths.contains(path) else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let pending = vault.pendingWithdrawals.first { $0.completedAt == nil }
            let destination: String
            switch path {
            case .approved: destination = approvedAddress
            case .beginDelay: destination = otherAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            case .emergency, .cancel:
                guard let recovery = vault.recoveryAddress else { throw KasSignerEngine.EngineError.invalidResponse }
                destination = recovery
            case .mature:
                guard let pending else { throw KasSignerEngine.EngineError.invalidResponse }
                destination = pending.destinationAddress
            }
            let validation = try await engine.validateAddress(destination)
            guard validation.valid, validation.network == KaspaNetwork.testnet10.rawValue else {
                throw KasSignerEngine.EngineError.javascript("Enter a valid Testnet 10 destination.")
            }
            let isPending = path == .mature || path == .cancel
            let sourceAddress = isPending ? pending?.pendingAddress : vault.vaultAddress
            guard let sourceAddress else { throw KasSignerEngine.EngineError.invalidResponse }
            let sync = try await engine.syncAddress(sourceAddress, nodeConfiguration: preferences.nodeConfiguration)
            let outputs = ProtectedVaultStageOutput.classify(sync.utxos)
            stageOutputs = outputs
            let candidates = outputs.filter { $0.canCoverFee(feeSompi) }
            if candidates.count == 1 {
                selectedStageOutpoint = candidates[0].id
            }
            guard let utxo = candidates.first(where: { $0.id == selectedStageOutpoint })?.utxo else {
                if candidates.isEmpty {
                    throw KasSignerEngine.EngineError.javascript("No covenant-tagged vault output with enough balance to cover the fee is available at this stage.")
                }
                throw KasSignerEngine.EngineError.javascript("Select the covenant-tagged vault output to spend.")
            }
            let pendingDescriptor = path == .beginDelay
                ? try await engine.deriveProtectedVaultPendingWithRecovery(vault: vault, destination: destination)
                : nil
            let pskb: String
            if isPending {
                pskb = try await engine.buildProtectedVaultV2PendingSpendPSKB(
                    utxo: utxo, vault: vault, committedDestination: pending!.destinationAddress,
                    path: path.runtimePath, feeSompi: feeSompi
                )
            } else {
                pskb = try await engine.buildProtectedVaultV2SpendPSKB(
                    utxo: utxo, vault: vault, destination: destination,
                    path: path.runtimePath, feeSompi: feeSompi
                )
            }
            let summary = try await engine.summarizePSKB(pskb, network: .testnet10)
            let expectedOutput = pendingDescriptor?.pendingAddress ?? destination
            guard summary.transactionVersion == 1,
                  summary.inputCount == 1, summary.outputCount == 1,
                  summary.totalInputSompi == utxo.amount,
                  summary.totalOutputSompi == utxo.amount - feeSompi,
                  summary.feeSompi == feeSompi,
                  summary.inputs?.first?.txID?.lowercased() == utxo.txID.lowercased(),
                  summary.inputs?.first?.index == utxo.index,
                  summary.outputs?.first?.address?.lowercased() == expectedOutput.lowercased(),
                  summary.outputs?.first?.covenantID?.lowercased() == utxo.covenantID?.lowercased()
            else {
                throw KasSignerEngine.EngineError.javascript("Vault transaction does not match its source, destination, fee, or covenant binding.")
            }
            let recoverySigner = path == .emergency || path == .cancel
            let signingProfile: WalletProfile
            let chain: Int
            let index: Int
            if recoverySigner {
                guard let match = walletStore.profiles
                    .filter({ $0.network == KaspaNetwork.testnet10.rawValue })
                    .compactMap({ profile -> (WalletProfile, Int, Int)? in
                        if let index = profile.receiveAddresses.firstIndex(of: destination) { return (profile, 0, index) }
                        if let index = profile.changeAddresses.firstIndex(of: destination) { return (profile, 1, index) }
                        return nil
                    }).first else {
                    throw KasSignerEngine.EngineError.javascript("Import the Testnet recovery wallet as a separate account to sign this path.")
                }
                (signingProfile, chain, index) = match
            } else {
                guard let profile = walletStore.profiles.first(where: { $0.id == vault.profileID }),
                      let ownerIndex = vault.ownerDerivationIndex else {
                    throw KasSignerEngine.EngineError.invalidResponse
                }
                signingProfile = profile; chain = 0; index = ownerIndex
            }
            let mnemonic = try TestnetSeedStore.load(for: signingProfile.id)
            let signed = try await engine.signTestnet10VaultV2PSKB(pskb, mnemonic: mnemonic, chain: chain, index: index)
            let signedSummary = try await engine.summarizePSKB(signed, network: .testnet10)
            try SignedProtectedVaultFundingVerifier.verify(unsigned: summary, signed: signedSummary)
            // Do not pass V2 covenant spends through the legacy PSKB→KSPT
            // preflight converter. It treats non-IF vault redeems as generic
            // multisig and rejects them. Broadcast uses the PSKB-native
            // finalizer, which assembles the protected-vault witness by path.
            preparedSpend = PreparedSpend(
                signedPSKB: signed, path: path, destination: destination,
                outputAddress: expectedOutput,
                amountSompi: utxo.amount - feeSompi,
                feeSompi: feeSompi,
                sourceAddress: sourceAddress, sourceOutpoint: utxo.id,
                pendingDescriptor: pendingDescriptor, pendingID: pending?.id
            )
            if path == .mature, let pending {
                protectedVaultStore.setCompletionReviewRequested(
                    id: vault.id,
                    pendingID: pending.id,
                    requested: true
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func broadcastPreparedSpend() async {
        guard !isWorking, preferences.network == .testnet10,
              let vault, let preparedSpend else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let latest = try await engine.syncAddress(
                preparedSpend.sourceAddress,
                nodeConfiguration: preferences.nodeConfiguration
            )
            guard latest.utxos.contains(where: {
                $0.id == preparedSpend.sourceOutpoint && $0.covenantID?.count == 64
            }) else {
                throw KasSignerEngine.EngineError.javascript(
                    "The vault output changed since review. Prepare the withdrawal again."
                )
            }
            let isAuthorized = await appLockService.authorizeTransactionBroadcast()
            guard isAuthorized else {
                errorMessage = appLockService.authenticationError.map {
                    "Authentication failed: \($0)"
                } ?? "Authentication is required to broadcast this transaction."
                return
            }
            if preparedSpend.path == .beginDelay,
               let pendingDescriptor = preparedSpend.pendingDescriptor {
                protectedVaultStore.rememberPendingDestination(
                    id: vault.id, destination: preparedSpend.destination,
                    pendingAddress: pendingDescriptor.pendingAddress
                )
            }
            let txid = try await engine.broadcastSignedPSKB(
                preparedSpend.signedPSKB,
                nodeConfiguration: preferences.nodeConfiguration
            )
            let walletRecorded = walletStore.recordBroadcastedTransaction(
                profileID: vault.profileID,
                transactionID: txid,
                destination: preparedSpend.outputAddress,
                amountSompi: preparedSpend.amountSompi,
                feeSompi: preparedSpend.feeSompi
            )
            let vaultRecorded: Bool
            if preparedSpend.path == .beginDelay,
               let pendingDescriptor = preparedSpend.pendingDescriptor {
                vaultRecorded = protectedVaultStore.recordPendingWithdrawal(
                    id: vault.id, destination: preparedSpend.destination,
                    pendingAddress: pendingDescriptor.pendingAddress, transactionID: txid
                )
            } else if let pendingID = preparedSpend.pendingID {
                vaultRecorded = protectedVaultStore.completePendingWithdrawal(
                    id: vault.id,
                    pendingID: pendingID,
                    transactionID: txid,
                    outcome: preparedSpend.path == .cancel ? .recovery : .delayCompleted
                )
            } else {
                vaultRecorded = protectedVaultStore.recordApprovedSpend(id: vault.id, transactionID: txid)
            }
            transactionID = txid
            self.preparedSpend = nil
            let warning = (!walletRecorded || !vaultRecorded)
                ? "The transaction was broadcast, but its local record could not be saved. Refresh the wallet and check the transaction ID before sending again."
                : nil
            if preparedSpend.path == .beginDelay && !vaultRecorded {
                errorMessage = "The security-delay transaction was broadcast with ID \(txid), but its local vault record could not be saved. Refresh the vault before taking another action."
            } else {
                onBroadcast(txid, warning, preparedSpend.path == .beginDelay)
            }
            Task {
                await syncService.refreshAfterBroadcast(
                    profileID: vault.profileID,
                    walletStore: walletStore,
                    protectedVaultStore: protectedVaultStore,
                    engine: engine,
                    preferences: preferences
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ProtectedVaultSendView: View {
    let vault: ProtectedVault

    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var protectedVaultStore: ProtectedVaultStore
    @State private var isBuilding = false
    @State private var errorMessage: String?
    @State private var signingReview: VerifiedTransactionReview?
    @State private var showingSigning = false
    @State private var selectedApprovedAddress: String
    @State private var stageOutputs: [ProtectedVaultStageOutput] = []
    @State private var selectedStageOutpoint = ""

    private let feeSompi: UInt64 = 1_000_000

    private var spendableStageOutputs: [ProtectedVaultStageOutput] {
        stageOutputs.filter { $0.canCoverFee(feeSompi) }
    }

    private var unsupportedStageOutputs: [ProtectedVaultStageOutput] {
        stageOutputs.filter { !$0.isCovenantTagged }
    }

    init(vault: ProtectedVault) {
        self.vault = vault
        _selectedApprovedAddress = State(initialValue: vault.approvedAddresses.first ?? "")
    }

    var body: some View {
        Form {
            Section("Available in Vault") {
                LabeledContent("Locked Balance", value: "\((vault.lockedAmount ?? vault.amount).formatted()) \(preferences.network.currencySymbol)")
                LabeledContent("Unspent Outputs", value: "\(vault.fundingOutpoints.count)")
            }
            Section("Spend Paths") {
                Label("Approved destination — available immediately", systemImage: "checkmark.shield")
                Label("Other destinations — not enabled yet", systemImage: "clock.badge.exclamationmark")
            }
            Section("Approved Destination") {
                Picker("Destination", selection: $selectedApprovedAddress) {
                    ForEach(vault.approvedAddresses, id: \.self) { address in
                        Text(address).tag(address)
                    }
                }
                .pickerStyle(.navigationLink)
                LabeledContent("Network Fee", value: formatKas(feeSompi))
                if spendableStageOutputs.count > 1 {
                    Picker("Covenant Output", selection: $selectedStageOutpoint) {
                        Text("Select an output").tag("")
                        ForEach(spendableStageOutputs) { output in
                            Text("\(formatKas(output.utxo.amount)) · \(shortOutpoint(output.utxo.id))")
                                .tag(output.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } else if let output = spendableStageOutputs.first {
                    LabeledContent("Covenant Output", value: "\(formatKas(output.utxo.amount)) · \(shortOutpoint(output.utxo.id))")
                } else {
                    Text("No covenant-tagged vault output is currently available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("This sends the vault's entire balance, minus the fee, to the selected approved address.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !unsupportedStageOutputs.isEmpty {
                Section("Unsupported Deposits") {
                    Text("These deposits are not covenant-tagged and cannot be spent through this vault flow. They are excluded from the output choices above.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(unsupportedStageOutputs) { output in
                        LabeledContent(
                            "\(formatKas(output.utxo.amount)) · \(shortOutpoint(output.utxo.id))",
                            value: "Unsupported"
                        )
                    }
                }
            }
            Section {
                Button {
                    Task { await buildApprovedSpend() }
                } label: {
                    if isBuilding {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Send to Approved Destination").frame(maxWidth: .infinity)
                    }
                }
                .modifier(ProtectedVaultActionButtonModifier(isProtectedVault: true))
                .controlSize(.large)
                .disabled(isBuilding
                    || !vault.approvedAddresses.contains(selectedApprovedAddress)
                    || spendableStageOutputs.isEmpty
                    || (spendableStageOutputs.count > 1 && selectedStageOutpoint.isEmpty))
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            if let errorMessage {
                Section {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Spend from Vault")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshStageOutputs() }
        .navigationDestination(isPresented: $showingSigning) {
            if let signingReview {
                VerifiedSigningPreparationView(
                    review: signingReview,
                    protectedVaultMode: true,
                    protectedVaultApprovedSpend: true,
                    onBroadcastComplete: { transactionID in
                        protectedVaultStore.recordApprovedSpend(
                            id: vault.id,
                            transactionID: transactionID
                        )
                    },
                    onComplete: { showingSigning = false }
                )
            }
        }
    }

    @MainActor
    private func refreshStageOutputs() async {
        guard let address = vault.vaultAddress else { return }
        do {
            let sync = try await engine.syncAddress(
                address,
                nodeConfiguration: preferences.nodeConfiguration
            )
            stageOutputs = ProtectedVaultStageOutput.classify(sync.utxos)
            let candidates = stageOutputs.filter { $0.canCoverFee(feeSompi) }
            if candidates.count == 1 {
                selectedStageOutpoint = candidates[0].id
            } else if !candidates.contains(where: { $0.id == selectedStageOutpoint }) {
                selectedStageOutpoint = ""
            }
        } catch {
            // The send action will retry the on-chain lookup.
        }
    }

    @MainActor
    private func buildApprovedSpend() async {
        guard !isBuilding, let redeem = vault.redeemScriptHex,
              vault.approvedAddresses.contains(selectedApprovedAddress) else { return }
        isBuilding = true
        errorMessage = nil
        defer { isBuilding = false }
        do {
            guard let address = vault.vaultAddress else {
                throw KasSignerEngine.EngineError.javascript("Vault address is unavailable.")
            }
            let sync = try await engine.syncAddress(
                address, nodeConfiguration: preferences.nodeConfiguration
            )
            stageOutputs = ProtectedVaultStageOutput.classify(sync.utxos)
            let candidates = stageOutputs.filter { $0.canCoverFee(feeSompi) }
            if candidates.count == 1 {
                selectedStageOutpoint = candidates[0].id
            }
            guard let utxo = candidates.first(where: { $0.id == selectedStageOutpoint })?.utxo,
                  let covenantID = utxo.covenantID else {
                throw KasSignerEngine.EngineError.javascript(
                    candidates.isEmpty
                        ? "No covenant-tagged vault output with enough balance to cover the fee is available."
                        : "Select the covenant-tagged vault output to spend."
                )
            }
            let pskb = try await engine.buildProtectedVaultApprovedSpendPSKB(
                utxo: utxo,
                redeemScriptHex: redeem,
                approvedAddress: selectedApprovedAddress,
                feeSompi: feeSompi
            )
            let summary = try await engine.summarizePSKB(pskb, network: preferences.network)
            let sendAmount = utxo.amount - feeSompi
            guard summary.transactionVersion == 1,
                  summary.inputCount == 1, summary.outputCount == 1,
                  summary.totalInputSompi == utxo.amount,
                  summary.totalOutputSompi == sendAmount,
                  summary.feeSompi == feeSompi,
                  summary.inputs?.first?.txID?.lowercased() == utxo.txID.lowercased(),
                  summary.inputs?.first?.index == utxo.index,
                  summary.outputs?.first?.address?.lowercased() == selectedApprovedAddress.lowercased(),
                  summary.outputs?.first?.amountSompi == sendAmount,
                  summary.outputs?.first?.covenantAuthorizingInput == 0,
                  summary.outputs?.first?.covenantID?.lowercased() == covenantID.lowercased()
            else {
                throw KasSignerEngine.EngineError.javascript(
                    "The unsigned vault spend failed independent content verification."
                )
            }
            let digest = SHA256.hash(data: Data(pskb.utf8)).map { String(format: "%02x", $0) }.joined()
            signingReview = VerifiedTransactionReview(
                profileID: vault.profileID,
                destination: selectedApprovedAddress,
                amountSompi: sendAmount,
                feeSompi: feeSompi,
                changeSompi: 0,
                selectedInputCount: 1,
                selectedOutpoints: [utxo.id],
                unsignedPSKB: pskb,
                verifiedDigest: digest,
                selectedInputsVerified: true,
                destinationVerified: true,
                changeVerified: true,
                feeVerified: true
            )
            showingSigning = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatKas(_ sompi: UInt64) -> String {
        "\((Decimal(sompi) / Decimal(100_000_000)).formatted()) \(preferences.network.currencySymbol)"
    }

    private func shortOutpoint(_ outpoint: String) -> String {
        guard outpoint.count > 20 else { return outpoint }
        return "\(outpoint.prefix(10))…\(outpoint.suffix(8))"
    }
}

private struct FundProtectedVaultView: View {
    let vault: ProtectedVault
    let profile: WalletProfile
    let selectedUTXOs: [WalletUTXO]?
    let initialFeeSelection: ProtectedVaultFundingFeeSelection
    let onBroadcast: (String, String?) -> Void

    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    fundingSummaryCard
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))

            NavigationLink {
                if let selectedUTXOs {
                    ReviewVaultFundingView(
                        vault: vault,
                        profile: profile,
                        selectedUTXOs: selectedUTXOs,
                        initialFeeSelection: initialFeeSelection,
                        onBroadcast: onBroadcast
                    )
                } else {
                    VaultFundingUTXOSelectionView(
                        vault: vault,
                        profile: profile,
                        initialFeeSelection: initialFeeSelection,
                        onBroadcast: onBroadcast
                    )
                }
            } label: {
                Text(selectedUTXOs == nil ? "Select Funding UTXOs" : "Review Funding")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .modifier(ProtectedVaultActionButtonModifier(isProtectedVault: true))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .navigationTitle("Fund \(vault.displayName)")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
    }

    private var fundingSummaryCard: some View {
        VStack(spacing: 0) {
            fundingRow("Available Balance", value: availableBalanceText)
            Divider()
            fundingRow("Deposit", value: "\(vault.amount.formatted()) \(preferences.network.currencySymbol)")
        }
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var availableBalanceText: String {
        guard let balance = syncService.snapshot?.balance.totalKas else {
            return "Unavailable"
        }

        return "\(balance.formatted(.number.precision(.fractionLength(0...8)))) \(preferences.network.currencySymbol)"
    }

    private func fundingRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 14)
    }
}

private struct VaultFundingUTXOSelectionView: View {
    let vault: ProtectedVault
    let profile: WalletProfile
    let initialFeeSelection: ProtectedVaultFundingFeeSelection
    let onBroadcast: (String, String?) -> Void

    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var coinControlStore: UTXOCoinControlStore
    @State private var showingSelectionLimit = false
    @State private var fundingSelectionSnapshot: [WalletUTXO] = []
    @State private var showingFundingReview = false
    @State private var selectionSession = ProtectedVaultFundingSelectionSession()

    private let accentColor = Color(red: 0.20, green: 0.62, blue: 0.57)

    var body: some View {
        VStack(spacing: 0) {
            selectionSummary
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .background(Color(.systemGroupedBackground))

            if utxos.isEmpty {
                ContentUnavailableView(
                    "No Spendable UTXOs",
                    systemImage: "square.stack.3d.up.slash"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(utxos) { utxo in
                            fundingUTXOCard(utxo)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
                }
            }

            Button {
                fundingSelectionSnapshot = selectedUTXOs
                showingFundingReview = true
            } label: {
                Text("Review Funding")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .modifier(ProtectedVaultActionButtonModifier(isProtectedVault: true))
            .disabled(!selectionCoversDeposit)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .navigationTitle("Select UTXOs")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .navigationDestination(isPresented: $showingFundingReview) {
            ReviewVaultFundingView(
                vault: vault,
                profile: profile,
                selectedUTXOs: fundingSelectionSnapshot,
                initialFeeSelection: initialFeeSelection,
                onBroadcast: onBroadcast
            )
        }
        .onAppear {
            coinControlStore.activate(profileID: profile.id)
            guard selectionSession.begin(profileID: profile.id) else { return }
            coinControlStore.clearSelection()
        }
        .alert("Eight-UTXO limit", isPresented: $showingSelectionLimit) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("KasSigner supports at most 8 selected UTXOs in one funding transaction.")
        }
    }

    private var utxos: [WalletUTXO] {
        (syncService.snapshot?.utxos ?? []).sorted {
                if $0.blockDAAScore != $1.blockDAAScore {
                    return $0.blockDAAScore > $1.blockDAAScore
                }
                if $0.txID != $1.txID {
                    return $0.txID < $1.txID
                }
                return $0.index < $1.index
            }
    }

    private var selectedUTXOs: [WalletUTXO] {
        coinControlStore.selectedUTXOs(from: utxos)
    }

    private var maximumSelectableCount: Int {
        min(utxos.count, UTXOCoinControlStore.maximumSelectedUTXOs)
    }

    private var selectedTotalSompi: UInt64? {
        selectedUTXOs.reduce(into: UInt64?.some(0)) { total, utxo in
            guard let current = total else { return }
            let addition = current.addingReportingOverflow(utxo.amount)
            total = addition.overflow ? nil : addition.partialValue
        }
    }

    private var selectedTotalKas: Decimal? {
        selectedTotalSompi.map { Decimal($0) / Decimal(100_000_000) }
    }

    private var selectionCoversDeposit: Bool {
        guard let selectedTotalKas else { return false }
        return selectedTotalKas >= vault.amount
    }

    private var selectionSummary: some View {
        VStack(spacing: 11) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(selectedUTXOs.count) UTXO\(selectedUTXOs.count == 1 ? "" : "s")")
                        .font(.system(size: 16, weight: .semibold))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Input total")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(selectedTotalSompi.map(formatKas) ?? "0 \(preferences.network.currencySymbol)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }

            HStack {
                Text("Vault deposit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(vault.amount.formatted()) \(preferences.network.currencySymbol)")
                    .font(.subheadline.weight(.medium).monospacedDigit())
            }

            HStack(spacing: 10) {
                Button(selectedUTXOs.count == maximumSelectableCount
                    ? "Clear All"
                    : (utxos.count > UTXOCoinControlStore.maximumSelectedUTXOs
                        ? "Select First 8"
                        : "Select All")) {
                    if selectedUTXOs.count == maximumSelectableCount {
                        coinControlStore.clearSelection()
                    } else if coinControlStore.selectAll(utxos) > 0 {
                        showingSelectionLimit = true
                    }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)

                if !selectedUTXOs.isEmpty && selectedUTXOs.count != maximumSelectableCount {
                    Button("Clear") {
                        coinControlStore.clearSelection()
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                }

                Spacer()
            }

            if !selectedUTXOs.isEmpty && !selectionCoversDeposit {
                Text("Select enough inputs to cover the vault deposit and your chosen network fee.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func fundingUTXOCard(_ utxo: WalletUTXO) -> some View {
        let selected = coinControlStore.isSelected(utxo)
        let label = coinControlStore.label(for: utxo)

        return Button {
            if !coinControlStore.toggle(utxo) {
                showingSelectionLimit = true
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Text(formatKas(utxo.amount))
                        .font(.body.weight(.regular).monospacedDigit())
                        .foregroundStyle(.primary)

                    Spacer()

                    UTXOKYCStatusBadge(status: coinControlStore.kycStatus(for: utxo))
                }

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    Text("Transaction ID")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(utxo.txID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Label")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .leading)

                    if !label.isEmpty {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(selected ? accentColor.opacity(0.78) : Color.primary.opacity(0.05), lineWidth: selected ? 2 : 1)
            }
        }
        .buttonStyle(SubtlePressButtonStyle())
    }

    private func formatKas(_ sompi: UInt64) -> String {
        let amount = Double(sompi) / 100_000_000
        return "\(amount.formatted(.number.precision(.fractionLength(0...8)))) \(preferences.network.currencySymbol)"
    }
}

private struct ReviewVaultFundingView: View {
    let vault: ProtectedVault
    let profile: WalletProfile
    let selectedUTXOs: [WalletUTXO]
    let initialFeeSelection: ProtectedVaultFundingFeeSelection
    let onDraftBuilt: ((ProtectedVault) -> Bool)?
    let onBroadcast: (String, String?) -> Void

    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var walletStore: WalletStore
    @State private var selectedFee: VaultFundingFeeChoice = .normal
    @State private var customFeeText = ""
    @State private var feeEstimate: FeeEstimate?
    @State private var feeEstimateError: String?
    @State private var isRefreshingFee = false
    @State private var isBuilding = false
    @State private var buildErrorMessage = ""
    @State private var showingBuildError = false
    @State private var verifiedReview: VerifiedVaultFundingReview?

    init(
        vault: ProtectedVault,
        profile: WalletProfile,
        selectedUTXOs: [WalletUTXO],
        initialFeeSelection: ProtectedVaultFundingFeeSelection = ProtectedVaultFundingFeeSelection(),
        onDraftBuilt: ((ProtectedVault) -> Bool)? = nil,
        onBroadcast: @escaping (String, String?) -> Void
    ) {
        self.vault = vault
        self.profile = profile
        self.selectedUTXOs = selectedUTXOs
        self.initialFeeSelection = initialFeeSelection
        self.onDraftBuilt = onDraftBuilt
        self.onBroadcast = onBroadcast
        _selectedFee = State(initialValue: initialFeeSelection.choice)
        _customFeeText = State(initialValue: initialFeeSelection.customFeeText)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    detailSectionTitle("Summary")
                    summaryCard
                    detailSectionTitle("Rules")
                    vaultRulesCard
                    vaultDetailsCards
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            Button {
                Task { await buildAndVerifyUnsignedFunding() }
            } label: {
                if isBuilding {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Build Funding PSKB")
                        .frame(maxWidth: .infinity)
                }
            }
                .font(.headline)
                .modifier(ProtectedVaultActionButtonModifier(isProtectedVault: true))
                .disabled(fundingPlan == nil || isBuilding || vault.vaultAddress == nil)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .navigationTitle("Review Details")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .alert("Funding PSKB could not be built", isPresented: $showingBuildError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(buildErrorMessage)
        }
        .navigationDestination(item: $verifiedReview) { review in
            VerifiedVaultFundingReviewView(review: review, onBroadcast: onBroadcast)
        }
        .task {
            _ = await refreshFeeEstimate()
        }
        .onChange(of: selectedFee) { _, choice in
            guard profile.network == KaspaNetwork.testnet10.rawValue,
                  choice == .normal else { return }
            Task { await refreshFeeEstimate() }
        }
    }

    private var fundingPlan: ProtectedVaultFundingPlan? {
        guard let requestedFeeSompi else { return nil }
        return try? ProtectedVaultFundingPlan(
            vault: vault,
            inputs: selectedUTXOs,
            feeSompi: requestedFeeSompi
        )
    }

    private var selectedFeeRateSompiPerGram: Double? {
        guard let estimate = feeEstimate else { return nil }
        switch selectedFee {
        case .low: return estimate.lowSompiPerGram
        case .normal: return estimate.normalSompiPerGram
        case .priority: return estimate.prioritySompiPerGram
        case .custom: return nil
        }
    }

    private var feeChoices: [VaultFundingFeeChoice] {
        profile.network == KaspaNetwork.testnet10.rawValue
            ? [.normal, .custom]
            : VaultFundingFeeChoice.allCases
    }

    @MainActor
    private func buildAndVerifyUnsignedFunding() async {
        guard !isBuilding else { return }
        isBuilding = true
        defer { isBuilding = false }

        do {
            if selectedFee != .custom, !(await refreshFeeEstimate()) {
                throw VaultFundingBuildError.feeEstimateUnavailable
            }
            guard let plan = fundingPlan,
                  let vaultAddress = vault.vaultAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !vaultAddress.isEmpty
            else {
                throw VaultFundingBuildError.invalidPlan
            }

            guard let activeProfile = walletStore.profiles.first(where: { $0.id == profile.id }) else {
                throw VaultFundingBuildError.walletStateChanged
            }

            let usesExactFee = selectedFee == .custom
            let pskb = try await engine.buildProtectedVaultFundingPSKB(
                profile: activeProfile,
                selectedInputs: selectedUTXOs,
                vaultAddress: vaultAddress,
                amountSompi: plan.depositSompi,
                feeSompi: plan.feeSompi
            )
            let summary = try await engine.summarizePSKB(pskb, network: preferences.network)
            let expectedChangeAddress = activeProfile.changeAddresses.indices.contains(
                activeProfile.nextChangeIndex
            ) ? activeProfile.changeAddresses[activeProfile.nextChangeIndex] : nil
            let verified = try ProtectedVaultFundingVerifier.verify(
                summary: summary,
                plan: plan,
                vaultAddress: vaultAddress,
                expectedChangeAddress: expectedChangeAddress,
                requiresExactFee: usesExactFee
            )

            if verified.changeSompi > 0 {
                guard walletStore.reserveChangeAddress(
                    profileID: activeProfile.id,
                    index: activeProfile.nextChangeIndex
                ) else {
                    throw VaultFundingBuildError.walletStateChanged
                }
            }

            let digest = SHA256.hash(data: Data(pskb.utf8)).map {
                String(format: "%02x", $0)
            }.joined()
            if let onDraftBuilt, !onDraftBuilt(vault) {
                throw VaultFundingBuildError.walletStateChanged
            }
            verifiedReview = VerifiedVaultFundingReview(
                profileID: activeProfile.id,
                vaultID: vault.id,
                vaultAddress: vaultAddress,
                covenantScriptHex: vault.redeemScriptHex,
                securityDelay: vault.delaySummary,
                verified: verified,
                unsignedPSKB: pskb,
                digest: digest
            )
        } catch {
            showBuildError(error.localizedDescription)
        }
    }

    private func showBuildError(_ message: String) {
        buildErrorMessage = message
        showingBuildError = true
    }

    @MainActor
    private func refreshFeeEstimate() async -> Bool {
        guard !isRefreshingFee else { return feeEstimate != nil }
        isRefreshingFee = true
        feeEstimate = nil
        defer { isRefreshingFee = false }
        do {
            feeEstimate = try await engine.getFeeEstimate(
                nodeConfiguration: preferences.nodeConfiguration
            )
            feeEstimateError = nil
            return true
        } catch {
            feeEstimate = nil
            feeEstimateError = error.localizedDescription
            return false
        }
    }

    private var inputSompi: UInt64 {
        fundingPlan?.inputTotalSompi ?? selectedUTXOs.reduce(0) { $0 &+ $1.amount }
    }

    private var depositSompi: UInt64 {
        fundingPlan?.depositSompi ?? 0
    }

    private var feeSompi: UInt64 {
        requestedFeeSompi ?? 0
    }

    private var changeSompi: UInt64 {
        fundingPlan?.changeSompi ?? 0
    }

    private var summaryCard: some View {
        VStack(spacing: 0) {
            reviewRow("Funding Wallet", value: profile.name)
            Divider()
            reviewRow("Selected Inputs", value: "\(selectedUTXOs.count)")
            Divider()
            reviewRow("Vault Deposit", value: formatKas(depositSompi))
            Divider()
            reviewRow("Funding Fee", value: requestedFeeSompi.map(formatKas) ?? "Unavailable")
            Divider()
            reviewRow("Wallet Change", value: formatKas(changeSompi))
        }
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var vaultRulesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            reviewRow("Security Delay", value: vault.delaySummary, verticalPadding: 8)
            Divider()
            reviewRow("Recovery Path", value: vault.recoveryPath?.rawValue ?? "Not set", verticalPadding: 8)
        }
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var feeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fee")
                .font(.headline)

            Picker("Fee", selection: $selectedFee) {
                ForEach(feeChoices) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            if selectedFee == .custom {
                HStack(spacing: 10) {
                    TextField("0", text: $customFeeText)
                        .keyboardType(.decimalPad)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Text(preferences.network.currencySymbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(
                    Color(.tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }

            Text(feeDescription)
                .font(.caption)
                .foregroundStyle(fundingPlan == nil ? .orange : .secondary)

            if feeEstimate == nil, selectedFee != .custom, !isRefreshingFee {
                Button("Refresh Fee Estimate", systemImage: "arrow.clockwise") {
                    Task { await refreshFeeEstimate() }
                }
                .font(.caption.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
    }

    private var vaultDetailsCards: some View {
        VStack(spacing: 10) {
            ForEach(Array(vault.approvedAddresses.enumerated()), id: \.offset) { index, address in
                ProtectedVaultAddressDisplayCard(
                    title: "Approved Address \(index + 1)",
                    address: address,
                    compact: true
                )
            }
            if let recoveryAddress = vault.recoveryAddress {
                ProtectedVaultAddressDisplayCard(title: "Recovery Address", address: recoveryAddress, compact: true)
            }
            if let vaultAddress = vault.vaultAddress {
                ProtectedVaultAddressDisplayCard(title: "Vault Address", address: vaultAddress, compact: true)
            }
        }
    }

    private func detailSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.bottom, -6)
    }

    private func reviewRow(_ title: String, value: String, verticalPadding: CGFloat = 13) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, verticalPadding)
    }

    private func formatKas(_ sompi: UInt64) -> String {
        let amount = Decimal(sompi) / Decimal(100_000_000)
        return "\(amount.formatted()) \(preferences.network.currencySymbol)"
    }

    private var requestedFeeSompi: UInt64? {
        if selectedFee == .custom {
            return parseKasTextToSompi(customFeeText)
        }

        guard let estimate = feeEstimate,
              estimate.normalSompiPerGram > 0
        else { return nil }

        if profile.network == KaspaNetwork.testnet10.rawValue {
            return protectedVaultNormalFeeEstimate(
                estimate: estimate,
                inputCount: selectedUTXOs.count
            )
        }

        let rate: Double
        switch selectedFee {
        case .low: rate = estimate.lowSompiPerGram
        case .normal: rate = estimate.normalSompiPerGram
        case .priority: rate = estimate.prioritySompiPerGram
        case .custom: return nil
        }

        let quotedMass = ceil(Double(estimate.suggestedFee) / estimate.normalSompiPerGram)
        let fee = quotedMass * rate
        guard fee.isFinite, fee > 0, fee <= Double(UInt64.max) else { return nil }
        return UInt64(fee)
    }

    private var feeDescription: String {
        guard let requestedFeeSompi else {
            return selectedFee == .custom
                ? "Enter a positive exact fee in \(preferences.network.currencySymbol)."
                : isRefreshingFee
                    ? "Updating live fee estimate…"
                    : feeEstimateError.map { "Fee estimate unavailable: \($0)" }
                        ?? "Waiting for a live fee estimate."
        }
        guard fundingPlan != nil else {
            return "The selected inputs cannot cover the deposit and this fee."
        }
        return "\(selectedFee.title) • \(formatKas(requestedFeeSompi))"
    }

    private func parseKasTextToSompi(_ text: String) -> UInt64? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard !raw.isEmpty, !raw.contains("-"), !raw.lowercased().contains("e"),
              parts.count <= 2, let whole = UInt64(parts[0]),
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return nil }
        let fractional = parts.count == 2 ? String(parts[1]) : ""
        guard fractional.count <= 8 else { return nil }
        let wholeResult = whole.multipliedReportingOverflow(by: 100_000_000)
        guard !wholeResult.overflow else { return nil }
        let padded = fractional.padding(toLength: 8, withPad: "0", startingAt: 0)
        guard let fraction = UInt64(padded) else { return nil }
        let total = wholeResult.partialValue.addingReportingOverflow(fraction)
        return !total.overflow && total.partialValue > 0 ? total.partialValue : nil
    }
}

private struct VerifiedVaultFundingReview: Identifiable, Hashable {
    let id = UUID()
    let profileID: UUID
    let vaultID: UUID
    let vaultAddress: String
    let covenantScriptHex: String?
    let securityDelay: String
    let depositSompi: UInt64
    let feeSompi: UInt64
    let changeSompi: UInt64
    let inputCount: Int
    let selectedOutpoints: [String]
    let selectedInputsMatchDecodedPSKB: Bool
    let vaultDepositMatches: Bool
    let changeOutputsMatchWallet: Bool
    let feeMatchesInputOutputTotals: Bool
    let unsignedPSKB: String
    let digest: String

    init(
        profileID: UUID,
        vaultID: UUID,
        vaultAddress: String,
        covenantScriptHex: String?,
        securityDelay: String,
        verified: VerifiedProtectedVaultFunding,
        unsignedPSKB: String,
        digest: String
    ) {
        self.profileID = profileID
        self.vaultID = vaultID
        self.vaultAddress = vaultAddress
        self.covenantScriptHex = covenantScriptHex
        self.securityDelay = securityDelay
        depositSompi = verified.depositSompi
        feeSompi = verified.feeSompi
        changeSompi = verified.changeSompi
        inputCount = verified.inputCount
        selectedOutpoints = verified.selectedOutpoints
        selectedInputsMatchDecodedPSKB = verified.selectedInputsMatchDecodedPSKB
        vaultDepositMatches = verified.vaultDepositMatches
        changeOutputsMatchWallet = verified.changeOutputsMatchWallet
        feeMatchesInputOutputTotals = verified.feeMatchesInputOutputTotals
        self.unsignedPSKB = unsignedPSKB
        self.digest = digest
    }
}

private struct VerifiedVaultFundingReviewView: View {
    let review: VerifiedVaultFundingReview
    let onBroadcast: (String, String?) -> Void
    @EnvironmentObject private var appLockService: AppLockService
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var protectedVaultStore: ProtectedVaultStore
    @State private var isCovenantScriptExpanded = false
    @State private var showingM5Signing = false
    @State private var showingFundingConfirmation = false
    @State private var isAuthorizingFunding = false
    @State private var isBroadcastingTestnet = false
    @State private var fundingError: String?
    @State private var testnetTransactionID: String?

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Selected Inputs", value: "\(review.inputCount)")
                LabeledContent("Vault Deposit", value: formatKas(review.depositSompi))
                LabeledContent("Security Delay", value: review.securityDelay.isEmpty ? "None" : review.securityDelay)
                LabeledContent("Transaction Fee", value: formatKas(review.feeSompi))
                LabeledContent("Wallet Change", value: formatKas(review.changeSompi))
            }

            Section {
                ProtectedVaultAddressDisplayCard(
                    title: "Vault Address",
                    address: review.vaultAddress
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if let covenantScriptHex = review.covenantScriptHex,
               !covenantScriptHex.isEmpty {
                Section("Covenant") {
                    DisclosureGroup(
                        "Show Covenant Script",
                        isExpanded: $isCovenantScriptExpanded
                    ) {
                        Text(covenantScriptHex)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .padding(.top, 8)
                    }
                    Text("This is the vault redeem script, not a private key. It defines the covenant spending rules committed by the vault address.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Unsigned PSKB Fingerprint") {
                LabeledContent("SHA-256", value: review.digest)
                    .font(.caption2.monospaced())
            }

            Section {
                ProtectedVaultSecurityChecksCard(checks: [
                    ProtectedVaultSecurityCheck(
                        title: "Selected inputs match the decoded PSKB",
                        passed: review.selectedInputsMatchDecodedPSKB
                    ),
                    ProtectedVaultSecurityCheck(
                        title: "Vault destination and amount match",
                        passed: review.vaultDepositMatches
                    ),
                    ProtectedVaultSecurityCheck(
                        title: "All change outputs belong to this wallet",
                        passed: review.changeOutputsMatchWallet
                    ),
                    ProtectedVaultSecurityCheck(
                        title: "Fee matches decoded input and output totals",
                        passed: review.feeMatchesInputOutputTotals
                    )
                ])
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                Group {
                  if preferences.network == .testnet10 {
                    Button {
                        showingFundingConfirmation = true
                    } label: {
                        if isBroadcastingTestnet {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Fund Protected Vault")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }
                    .disabled(isBroadcastingTestnet || testnetTransactionID != nil)
                  } else {
                    Button {
                        showingM5Signing = true
                    } label: {
                        Text("Continue to M5 Signing")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                  }
                }
                .modifier(ProtectedVaultActionButtonModifier(isProtectedVault: true))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            if let fundingError {
                Section { Text(fundingError).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("Verify PSKB")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Confirm Vault Funding", isPresented: $showingFundingConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Confirm & Authenticate") {
                Task { await authorizeAndContinueFunding() }
            }
        } message: {
            Text("You are about to deposit \(formatKas(review.depositSompi)) into this Protected Vault.\n\nDestination: \(review.vaultAddress)\n\nAuthenticate to continue.")
        }
        .navigationDestination(isPresented: $showingM5Signing) {
            VerifiedSigningPreparationView(
                review: signingReview,
                protectedVaultMode: true,
                onBroadcastComplete: { transactionID in
                    protectedVaultStore.recordFundingBroadcast(
                        id: review.vaultID,
                        transactionID: transactionID
                    )
                },
                onComplete: {
                    showingM5Signing = false
                    NotificationCenter.default.post(
                        name: .protectedVaultFundingCompleted,
                        object: review.vaultID
                    )
                }
            )
        }
    }

    private var signingReview: VerifiedTransactionReview {
        VerifiedTransactionReview(
            profileID: review.profileID,
            destination: review.vaultAddress,
            amountSompi: review.depositSompi,
            feeSompi: review.feeSompi,
            changeSompi: review.changeSompi,
            selectedInputCount: review.inputCount,
            selectedOutpoints: review.selectedOutpoints,
            unsignedPSKB: review.unsignedPSKB,
            verifiedDigest: review.digest,
            selectedInputsVerified: review.selectedInputsMatchDecodedPSKB,
            destinationVerified: review.vaultDepositMatches,
            changeVerified: review.changeOutputsMatchWallet,
            feeVerified: review.feeMatchesInputOutputTotals
        )
    }

    private func formatKas(_ sompi: UInt64) -> String {
        let amount = Decimal(sompi) / Decimal(100_000_000)
        return "\(amount.formatted()) \(preferences.network.currencySymbol)"
    }

    @MainActor
    private func signAndBroadcastTestnetFunding() async {
        guard !isBroadcastingTestnet, preferences.network == .testnet10,
              let vault = protectedVaultStore.vaults.first(where: { $0.id == review.vaultID }),
              vault.recoveryAddress != nil, vault.recoveryPath != nil,
              vault.vaultAddress == review.vaultAddress else { return }
        isBroadcastingTestnet = true
        fundingError = nil
        defer { isBroadcastingTestnet = false }
        do {
            let digest = SHA256.hash(data: Data(review.unsignedPSKB.utf8))
                .map { String(format: "%02x", $0) }.joined()
            guard digest == review.digest else {
                throw KasSignerEngine.EngineError.javascript("Funding PSKB changed since review.")
            }
            let mnemonic = try TestnetSeedStore.load(for: review.profileID)
            let signed = try await engine.signTestnet10FundingPSKB(review.unsignedPSKB, mnemonic: mnemonic)
            let unsignedSummary = try await engine.summarizePSKB(review.unsignedPSKB, network: .testnet10)
            let signedSummary = try await engine.summarizePSKB(signed, network: .testnet10)
            try SignedProtectedVaultFundingVerifier.verify(unsigned: unsignedSummary, signed: signedSummary)
            try await engine.verifyStandardPSKBSignatures(signed)
            _ = try await engine.finalizeSignedPSKB(signed)
            let txid = try await engine.broadcastSignedPSKB(signed, nodeConfiguration: preferences.nodeConfiguration)
            let vaultRecorded = protectedVaultStore.recordFundingBroadcast(id: review.vaultID, transactionID: txid)
            let walletRecorded = walletStore.recordBroadcastedTransaction(
                profileID: review.profileID, transactionID: txid,
                destination: review.vaultAddress, amountSompi: review.depositSompi,
                feeSompi: review.feeSompi
            )
            testnetTransactionID = txid
            let warning = (!vaultRecorded || !walletRecorded)
                ? "The transaction was broadcast, but its local record could not be saved. Refresh the wallet and check the transaction ID before sending again."
                : nil
            onBroadcast(txid, warning)
        } catch {
            fundingError = error.localizedDescription
        }
    }

    @MainActor
    private func authorizeAndContinueFunding() async {
        guard !isAuthorizingFunding, !isBroadcastingTestnet,
              testnetTransactionID == nil else { return }
        isAuthorizingFunding = true
        fundingError = nil
        let authorized = await appLockService.authorizeProtectedVaultFunding()
        isAuthorizingFunding = false

        guard authorized else {
            if let authenticationError = appLockService.authenticationError {
                fundingError = "Authentication failed: \(authenticationError)"
            }
            return
        }

        if preferences.network == .testnet10 {
            await signAndBroadcastTestnetFunding()
        } else {
            showingM5Signing = true
        }
    }
}

private enum VaultFundingBuildError: LocalizedError {
    case walletStateChanged
    case invalidPlan
    case feeEstimateUnavailable

    var errorDescription: String? {
        switch self {
        case .walletStateChanged:
            return "The wallet address state changed. Return to the wallet and try again."
        case .invalidPlan:
            return "The funding inputs cannot cover the vault deposit and selected fee, or the vault address is unavailable."
        case .feeEstimateUnavailable:
            return "A fresh network fee estimate could not be loaded. Refresh the estimate and try again."
        }
    }
}

private func protectedVaultNormalFeeEstimate(
    estimate: FeeEstimate,
    inputCount: Int
) -> UInt64? {
    let normalRate = estimate.normalSompiPerGram
    guard normalRate.isFinite, normalRate > 0 else { return nil }

    let baselineMass = ceil(Double(estimate.suggestedFee) / normalRate)
    let extraInputMass = Double(max(0, inputCount - 1)) * 1_115
    let fee = max(Double(estimate.suggestedFee), ceil((baselineMass + extraInputMass) * normalRate))
    guard fee.isFinite, fee > 0, fee <= Double(UInt64.max) else { return nil }
    return UInt64(fee)
}

private enum VaultFundingFeeChoice: String, CaseIterable, Identifiable {
    case low, normal, priority, custom

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct SendTransactionTypeSelectionView: View {
    let profile: WalletProfile
    @Binding var showingSendFlow: Bool

    @State private var selectedType: SendTransactionType = .standard
    @State private var showingUTXOSelection = false

    private let accentColor = Color(red: 0.20, green: 0.62, blue: 0.57)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    transactionTypeCard(
                        .standard,
                        title: "Standard",
                        subtitle: "1–4 recipients • 0–1 change output",
                        detail: "The simplest option with the lowest transaction fee.",
                        systemImage: "arrow.up.right"
                    )

                    transactionTypeCard(
                        .privacyFocused,
                        title: "Privacy",
                        subtitle: "1–4 recipients • 2–4 change outputs",
                        detail: "Splits change across fresh wallet addresses for added ambiguity.",
                        systemImage: "shield.lefthalf.filled"
                    )

                    transactionTypeCard(
                        .decoy,
                        title: "Decoy",
                        subtitle: "1 recipient • 4 change outputs",
                        detail: "Creates a matching decoy amount and additional change outputs.",
                        systemImage: "theatermasks"
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))

            Button {
                showingUTXOSelection = true
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(accentColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .navigationTitle("Transaction Type")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .navigationDestination(isPresented: $showingUTXOSelection) {
            SendUTXOSelectionView(
                profile: profile,
                transactionType: selectedType,
                clearSelectionOnAppear: true,
                showingSendFlow: $showingSendFlow
            )
        }
    }

    private func transactionTypeCard(
        _ type: SendTransactionType,
        title: String,
        subtitle: String,
        detail: String,
        systemImage: String
    ) -> some View {
        Button {
            selectedType = type
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(accentColor)

                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: selectedType == type ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedType == type ? accentColor : Color.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selectedType == type
                    ? accentColor.opacity(0.12)
                    : Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        selectedType == type ? accentColor : Color.clear,
                        lineWidth: 1.5
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(SubtlePressButtonStyle())
        .accessibilityLabel("\(title). \(subtitle). \(detail)")
        .accessibilityAddTraits(selectedType == type ? .isSelected : [])
    }
}

/// Read-only rendering of the saved UTXO status, shared by the UTXO tab and
/// every selection list. Status editing remains in the UTXO tab's Menu.
struct UTXOKYCStatusBadge: View {
    let status: UTXOKYCStatus?

    private var tint: Color {
        switch status {
        case .kyc: .red
        case .nonKYC: .green
        case nil: .secondary
        }
    }

    private var symbol: String {
        switch status {
        case .kyc: "exclamationmark.shield.fill"
        case .nonKYC: "checkmark.shield.fill"
        case nil: "shield.lefthalf.filled"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(status?.title ?? "Set status")
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.map { "KYC status: \($0.title)" } ?? "Set KYC status")
    }
}

struct SendUTXOSelectionView: View {
    let profile: WalletProfile
    let transactionType: SendTransactionType
    let clearSelectionOnAppear: Bool
    @Binding var showingSendFlow: Bool
    var protectedVaultSelection: (([WalletUTXO]) -> Void)? = nil
    var initialProtectedVaultUTXOs: [WalletUTXO] = []

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var coinControlStore: UTXOCoinControlStore
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var priceService: PriceService
    @State private var showingUTXOSelectionLimit = false
    @State private var showingSessionError = false
    @State private var showingDestination = false
    @State private var showingTestnetDestination = false
    @State private var activeSessionID: UUID?
    @State private var activeSession: SendSession?

    private let accentColor = Color(red: 0.20, green: 0.62, blue: 0.57)

    var body: some View {
        Group {
            if utxos.isEmpty {
                ContentUnavailableView(
                    "No Spendable UTXOs",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Refresh the wallet before creating a transaction.")
                )
            } else {
                VStack(spacing: 0) {
                    selectionHeader
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                        .background(Color(.systemGroupedBackground))

                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(utxos) { utxo in
                                sendUTXOCard(utxo)
                            }
                        }
                        .padding(.top, 2)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 20)
                    }
                    .background(Color(.systemGroupedBackground))

                    Button {
                        if let protectedVaultSelection {
                            protectedVaultSelection(selectedUTXOs)
                            dismiss()
                            return
                        }
                        startSendSession()
                    } label: {
                        Text(selectedUTXOs.count == 1 ? "Spend UTXO" : "Spend UTXOs")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .modifier(ProtectedVaultActionButtonModifier(isProtectedVault: protectedVaultSelection != nil))
                    .disabled(
                        selectedUTXOs.isEmpty
                            || (protectedVaultSelection != nil && selectedTotalSompi == nil)
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background {
                        if protectedVaultSelection == nil {
                            Rectangle().fill(.ultraThinMaterial)
                        }
                    }
                }
            }
        }
        .navigationTitle("Select UTXOs")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .navigationDestination(isPresented: $showingDestination) {
            if let activeSessionID,
               let session = walletStore.sendSession(
                   id: activeSessionID,
                   profileID: profile.id
               ) {
                SendDestinationView(
                    profile: profile,
                    selectedUTXOs: session.selectedUTXOs,
                    transactionType: session.transactionType,
                    sessionID: activeSessionID,
                    showingSendFlow: $showingSendFlow
                )
            }
        }
        .fullScreenCover(isPresented: $showingTestnetDestination) {
            if let activeSessionID,
               let session = activeSession {
                NavigationStack {
                    SendDestinationView(
                        profile: profile,
                        selectedUTXOs: session.selectedUTXOs,
                        transactionType: session.transactionType,
                        sessionID: activeSessionID,
                        showingSendFlow: $showingSendFlow
                    )
                }
            }
        }
        .onChange(of: showingSendFlow) { _, isShowing in
            if !isShowing {
                showingTestnetDestination = false
            }
        }
        .onAppear {
            coinControlStore.activate(profileID: profile.id)
            if protectedVaultSelection != nil {
                coinControlStore.clearSelection()
                let selectedIDs = Set(initialProtectedVaultUTXOs.map(\.id))
                for utxo in utxos where selectedIDs.contains(utxo.id) {
                    _ = coinControlStore.toggle(utxo)
                }
            } else if clearSelectionOnAppear {
                coinControlStore.clearSelection()
            }
        }
        .alert("Eight-UTXO limit", isPresented: $showingUTXOSelectionLimit) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("KasSigner supports at most 8 selected UTXOs in one transaction. Additional UTXOs were not selected.")
        }
        .alert("Send could not begin", isPresented: $showingSessionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sendSessionErrorMessage)
        }
    }

    private var sendSessionErrorMessage: String {
        switch transactionType {
        case .standard:
            "No fresh change address is available. Refresh the wallet and try again."
        case .privacyFocused:
            "Privacy-Focused Send requires at least two available change addresses. Refresh the wallet and try again."
        case .decoy:
            "Decoy Transaction requires at least four available change addresses. Refresh the wallet and try again."
        }
    }

    private func startSendSession() {
        guard let session = walletStore.beginSendSession(
            profileID: profile.id,
            selectedUTXOs: selectedUTXOs,
            transactionType: transactionType
        ) else {
            showingSessionError = true
            return
        }
        activeSessionID = session.id
        activeSession = session
        if profile.network == KaspaNetwork.testnet10.rawValue {
            showingTestnetDestination = true
        } else {
            showingDestination = true
        }
    }

    private var utxos: [WalletUTXO] {
        (syncService.snapshot?.utxos ?? []).sorted {
            if $0.blockDAAScore != $1.blockDAAScore {
                return $0.blockDAAScore > $1.blockDAAScore
            }
            if $0.txID != $1.txID {
                return $0.txID < $1.txID
            }
            return $0.index < $1.index
        }
    }

    private var selectedUTXOs: [WalletUTXO] {
        coinControlStore.selectedUTXOs(from: utxos)
    }

    private var maximumSelectableCount: Int {
        min(utxos.count, UTXOCoinControlStore.maximumSelectedUTXOs)
    }

    private var selectedTotalSompi: UInt64? {
        selectedUTXOs.reduce(into: UInt64?.some(0)) { total, utxo in
            guard let current = total else { return }
            let addition = current.addingReportingOverflow(utxo.amount)
            total = addition.overflow ? nil : addition.partialValue
        }
    }

    private var selectionHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(selectedUTXOs.count) of \(maximumSelectableCount) selected")
                    .font(.headline)
                Text(
                    selectedTotalSompi.map {
                        "\(formatKas(sompi: $0)) total"
                    } ?? "Invalid total"
                )
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if selectedUTXOs.isEmpty {
                Button("Select All") {
                    if coinControlStore.selectAll(utxos) > 0 {
                        showingUTXOSelectionLimit = true
                    }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
            } else {
                Button("Clear All") {
                    coinControlStore.clearSelection()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func sendUTXOCard(_ utxo: WalletUTXO) -> some View {
        let selected = coinControlStore.isSelected(utxo)
        let label = coinControlStore.label(for: utxo)

        return Button {
            if !coinControlStore.toggle(utxo) {
                showingUTXOSelectionLimit = true
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(formatKas(sompi: utxo.amount))
                            .font(.body.weight(.regular).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .allowsTightening(true)
                            .foregroundStyle(.primary)

                        if let usdValue = usdValueText(for: utxo) {
                            Text(usdValue)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        UTXOKYCStatusBadge(status: coinControlStore.kycStatus(for: utxo))

                        Text(utxoTypeLabel(for: utxo))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    Text("Transaction ID")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(utxo.txID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Label")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .leading)

                    if !label.isEmpty {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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
                        selected ? accentColor.opacity(0.78) : Color.primary.opacity(0.05),
                        lineWidth: selected ? 2 : 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SubtlePressButtonStyle())
    }

    private func formatKas(sompi: UInt64) -> String {
        let whole = sompi / 100_000_000
        let fractional = sompi % 100_000_000
        let symbol = profile.network == KaspaNetwork.testnet10.rawValue ? "TKAS" : "KAS"

        guard fractional != 0 else {
            return "\(whole) \(symbol)"
        }

        let fractionalText = String(format: "%08llu", fractional)
            .replacingOccurrences(
                of: "0+$",
                with: "",
                options: .regularExpression
            )

        return "\(whole).\(fractionalText) \(symbol)"
    }

    private func utxoTypeLabel(for utxo: WalletUTXO) -> String {
        switch utxo.derivationChain?.lowercased() {
        case "receive": "Receive"
        case "change": "Change"
        default: "Unknown"
        }
    }

    private func usdValueText(for utxo: WalletUTXO) -> String? {
        guard let price = priceService.price(for: .usd),
              price.isFinite,
              price > 0 else { return nil }

        return (utxo.amountKas * price).formatted(
            .currency(code: "USD")
                .precision(.fractionLength(2))
        )
    }
}
