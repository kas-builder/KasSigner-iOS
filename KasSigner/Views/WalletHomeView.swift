import SwiftUI
import UIKit
import CryptoKit

private extension Notification.Name {
    static let protectedVaultFundingCompleted = Notification.Name(
        "org.kassigner.protectedVaultFundingCompleted"
    )
}

enum SendTransactionType: String, CaseIterable, Identifiable, Codable, Hashable {
    case standard
    case privacyFocused
    case decoy

    var id: Self { self }
}

struct WalletHomeView: View {
    private enum WalletRoute: Hashable {
        case receive(UUID)
        case programmableUTXOTypes(UUID)
        case createTimeLockedUTXO(UUID)
        case createProtectedVault(UUID)
        case protectedVaultDetail(UUID)
        case fundProtectedVault(UUID)
    }

    @State private var navigationPath = NavigationPath()
    @State private var showingSendFlow = false
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
    @State private var showingSecondaryCurrency = false
    @State private var showingCurrencyConverter = false
    @State private var currencyConverterDetent: PresentationDetent = .fraction(0.54)

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if let profile = walletStore.selectedProfile {
                    walletContent(profile)
                } else {
                    ContentUnavailableView {
                        Label("No Account", systemImage: "wallet.pass")
                    } description: {
                        Text("Import the public wallet data exported by KasSigner. Private keys remain on the signing device.")
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
                        programmableUTXOTypeSelection(profile)
                    } else {
                        unavailableAccountView
                    }
                case .createTimeLockedUTXO(let profileID):
                    if let profile = walletStore.profiles.first(where: { $0.id == profileID }) {
                        CreateTimeLockedUTXOView(
                            returnAddress: walletHomeReceiveAddress(for: profile)
                        )
                    } else {
                        unavailableAccountView
                    }
                case .createProtectedVault(let profileID):
                    if let profile = walletStore.profiles.first(where: { $0.id == profileID }) {
                        CreateProtectedVaultView(profile: profile) {
                            navigationPath = NavigationPath()
                            navigationPath.append(WalletRoute.programmableUTXOTypes(profileID))
                        }
                    } else {
                        unavailableAccountView
                    }
                case .protectedVaultDetail(let vaultID):
                    if let vault = protectedVaultStore.vaults.first(where: { $0.id == vaultID }) {
                        ProtectedVaultDetailView(vault: vault) {
                            navigationPath.append(WalletRoute.fundProtectedVault(vaultID))
                        }
                    } else {
                        ContentUnavailableView(
                            "Vault Unavailable",
                            systemImage: "lock.slash"
                        )
                    }
                case .fundProtectedVault(let vaultID):
                    if let vault = protectedVaultStore.vaults.first(where: { $0.id == vaultID }),
                       let profile = walletStore.profiles.first(where: { $0.id == vault.profileID }) {
                        FundProtectedVaultView(vault: vault, profile: profile)
                    } else {
                        ContentUnavailableView(
                            "Vault Unavailable",
                            systemImage: "lock.slash"
                        )
                    }
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
                  let profileID = protectedVaultStore.vaults.first(where: { $0.id == vaultID })?.profileID
            else { return }
            navigationPath = NavigationPath()
            navigationPath.append(WalletRoute.programmableUTXOTypes(profileID))
            navigationPath.append(WalletRoute.protectedVaultDetail(vaultID))
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

                            if !balanceUnitText.isEmpty {
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
                    .accessibilityHint("Double tap to switch between KAS and \(preferences.secondaryCurrency.displayName).")
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
                    navigationPath.append(WalletRoute.programmableUTXOTypes(profile.id))
                } label: {
                    Text("Create Programmable UTXO")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.bordered)
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
                    VStack(alignment: .leading, spacing: 12) {
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

    private func programmableUTXOTypeSelection(_ profile: WalletProfile) -> some View {
        List {
            Section("Types") {
                NavigationLink(value: WalletRoute.createTimeLockedUTXO(profile.id)) {
                    Label("Time-Locked UTXO", systemImage: "clock.badge.checkmark")
                }

                NavigationLink(value: WalletRoute.createProtectedVault(profile.id)) {
                    Label("Protected Vault", systemImage: "lock.shield")
                }
            }

            Section("Active Vaults") {
                let vaults = protectedVaultStore.vaults(for: profile.id)
                if vaults.isEmpty {
                    Label("No Active Vaults", systemImage: "lock.open")
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(vaults) { vault in
                        NavigationLink(value: WalletRoute.protectedVaultDetail(vault.id)) {
                            activeVaultCard(vault)
                        }
                    }
                }
            }
        }
        .navigationTitle("Programmable UTXOs")
        .navigationBarTitleDisplayMode(.large)
    }

    private func activeVaultCard(_ vault: ProtectedVault) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(vault.status.title)
                        .font(.headline)

                    Spacer()

                    Text(vault.status == .active
                        ? "Spendable"
                        : (vault.status == .incompatibleFunding ? "Untagged" : (vault.status == .spent ? "Complete" : "Not Funded")))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(vault.status == .active ? .green : .orange)
                }

                HStack {
                    Text("\((vault.lockedAmount ?? vault.amount).formatted()) KAS")
                        .font(.subheadline.weight(.medium))

                    Spacer()

                    Text(vault.delaySummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(vault.approvedAddress)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(vault.status.title), \((vault.lockedAmount ?? vault.amount).formatted()) KAS, "
                + "\(vault.status == .active ? "spendable" : "not spendable"), \(vault.delaySummary)"
        )
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
        guard showingSecondaryCurrency else {
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
        if force {
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

private struct CreateTimeLockedUTXOView: View {
    let returnAddress: String

    @State private var amountText = ""
    @State private var unlockDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now

    private var amountIsValid: Bool {
        guard let amount = Decimal(string: amountText), amount > 0 else { return false }
        return true
    }

    var body: some View {
        Form {
            Section("Amount") {
                HStack {
                    TextField("0", text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)

                    Text("KAS")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Unlock Date & Time") {
                DatePicker(
                    "Unlock",
                    selection: $unlockDate,
                    in: Date.now...,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }

            Section("Return Address") {
                Text(returnAddress)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }

            Section("Summary") {
                LabeledContent("Amount", value: amountSummary)
                LabeledContent(
                    "Unlocks",
                    value: unlockDate.formatted(date: .abbreviated, time: .shortened)
                )
                LabeledContent("Estimated Fee", value: "—")
            }

            Section {
                Button("Review Time Lock") {
                }
                .frame(maxWidth: .infinity)
                .disabled(!amountIsValid || unlockDate <= .now)
            }
        }
        .navigationTitle("Create Time-Locked UTXO")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var amountSummary: String {
        amountIsValid ? "\(amountText) KAS" : "—"
    }
}

private struct CreateProtectedVaultView: View {
    let profile: WalletProfile
    let onCreated: () -> Void

    @EnvironmentObject private var engine: KasSignerEngine
    @State private var amountText = ""
    @State private var approvedAddress = ""
    @State private var addressValidation: AddressValidationResult?
    @State private var isValidatingAddress = false
    @State private var addressValidationTask: Task<Void, Never>?
    @State private var delayDays = 30
    @State private var delayHours = 0
    @State private var delayMinutes = 0
    @State private var showingScanner = false
    @State private var showingReview = false

    private var amountIsValid: Bool {
        guard let amount = Decimal(string: amountText), amount > 0 else { return false }
        return true
    }

    private var delayIsValid: Bool {
        delayDays > 0 || delayHours > 0 || delayMinutes > 0
    }

    private var normalizedApprovedAddress: String {
        normalizeAddress(approvedAddress)
    }

    private var approvedAddressIsValid: Bool {
        addressValidation?.valid == true
    }

    private var addressValidationMessage: String? {
        guard !approvedAddress.isEmpty else { return nil }

        if isValidatingAddress {
            return "Validating mainnet address..."
        }

        if approvedAddressIsValid {
            return "Valid Kaspa address."
        }

        return addressValidation?.reason ?? "Invalid Kaspa address."
    }

    private var addressValidationColor: Color {
        if isValidatingAddress {
            return .secondary
        }

        return approvedAddressIsValid ? .green : .red
    }

    var body: some View {
        Form {
            Section("Deposit") {
                LabeledContent("Amount") {
                    HStack(spacing: 6) {
                        TextField("0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)

                        Text("KAS")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Approved Address") {
                TextField("kaspa:...", text: $approvedAddress, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(2...4)
                    .onChange(of: approvedAddress) { _, newValue in
                        let normalized = normalizeAddress(newValue)

                        if normalized != approvedAddress {
                            approvedAddress = normalized
                            return
                        }

                        validateApprovedAddress(normalized)
                    }

                HStack(spacing: 10) {
                    Button {
                        let pastedAddress = normalizeAddress(
                            UIPasteboard.general.string ?? ""
                        )
                        approvedAddress = pastedAddress
                        validateApprovedAddress(pastedAddress)
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showingScanner = true
                    } label: {
                        Label("Scan QR", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if let addressValidationMessage {
                    Text(addressValidationMessage)
                        .font(.caption)
                        .foregroundStyle(addressValidationColor)
                }

            }

            Section {
                delayPicker("Days", selection: $delayDays, range: 0...365)
                delayPicker("Hours", selection: $delayHours, range: 0...23)
                delayPicker("Minutes", selection: $delayMinutes, range: 0...59)
            } header: {
                Text("Security Delay")
            } footer: {
                Text("An unapproved withdrawal must first enter a destination-committed pending state, then wait for the full consensus-enforced delay.")
            }

            Section("How It Works") {
                vaultBehaviorRow(
                    title: "Approved destinations",
                    detail: "Withdrawals can be sent immediately.",
                    systemImage: "checkmark.shield"
                )

                vaultBehaviorRow(
                    title: "Other destinations",
                    detail: "Withdrawals must wait for the full security delay.",
                    systemImage: "clock.badge.exclamationmark"
                )

            }

            Section {
                Button {
                    showingReview = true
                } label: {
                    Text("Review Protected Vault")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!amountIsValid || !approvedAddressIsValid || !delayIsValid)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Create Protected Vault")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingReview) {
            ReviewProtectedVaultView(
                profileID: profile.id,
                amountText: amountText,
                approvedAddress: normalizedApprovedAddress,
                delayDays: delayDays,
                delayHours: delayHours,
                delayMinutes: delayMinutes,
                onCreated: onCreated
            )
        }
        .sheet(isPresented: $showingScanner) {
            QRScannerView { scannedValue in
                let scannedAddress = normalizeAddress(scannedValue)
                approvedAddress = scannedAddress
                validateApprovedAddress(scannedAddress)
                showingScanner = false
            }
        }
        .onDisappear {
            addressValidationTask?.cancel()
        }
    }

    private func validateApprovedAddress(_ address: String) {
        addressValidationTask?.cancel()
        addressValidation = nil

        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
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
                       normalized != approvedAddress {
                        approvedAddress = normalized
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

    private func normalizeAddress(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: "kaspa://",
                with: "kaspa:",
                options: [.caseInsensitive]
            )
    }

    private func vaultBehaviorRow(
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))

                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ReviewProtectedVaultView: View {
    let profileID: UUID
    let amountText: String
    let approvedAddress: String
    let delayDays: Int
    let delayHours: Int
    let delayMinutes: Int
    let onCreated: () -> Void

    @EnvironmentObject private var appLockService: AppLockService
    @EnvironmentObject private var protectedVaultStore: ProtectedVaultStore
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var engine: KasSignerEngine
    @State private var isSaving = false
    @State private var descriptor: ProtectedVaultDescriptor?
    @State private var derivationError: String?

    var body: some View {
        Form {
            Section("Vault Summary") {
                LabeledContent("Deposit", value: "\(amountText) KAS")
                LabeledContent("Approved Addresses", value: "1")
                LabeledContent("Security Delay", value: delaySummary)
                LabeledContent("Estimated Fee", value: "—")
            }

            Section("Approved Destinations") {
                Text(approvedAddress)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.vertical, 3)
            }

            Section("Vault Address") {
                if let descriptor {
                    Text(descriptor.vaultAddress)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    LabeledContent("Signing Key", value: descriptor.ownerDerivationPath)
                } else if let derivationError {
                    Text(derivationError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    ProgressView("Deriving vault address…")
                }
            }

            Section {
                Label {
                    Text("Review every address and the security delay carefully. These settings define how the vault can be spent.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.footnote)
            }

            if !isSaving {
                Section {
                    Button {
                        Task {
                            if await appLockService.authorizeProtectedVaultCreation() {
                                saveLocalDraft()
                            }
                        }
                    } label: {
                        Label(
                            "Confirm with \(appLockService.biometricName)",
                            systemImage: "faceid"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(appLockService.isAuthenticating || descriptor == nil)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if let authenticationError = appLockService.authenticationError {
                Section {
                    Text(authenticationError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Review Protected Vault")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await deriveDescriptor()
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

    private func saveLocalDraft() {
        guard !isSaving,
              let amount = Decimal(string: amountText),
              amount > 0,
              let descriptor,
              walletStore.reserveReceiveAddress(
                profileID: profileID,
                index: descriptor.ownerDerivationIndex
              )
        else { return }

        isSaving = true
        protectedVaultStore.add(
            ProtectedVault(
                profileID: profileID,
                amount: amount,
                approvedAddress: approvedAddress,
                delayDays: delayDays,
                delayHours: delayHours,
                delayMinutes: delayMinutes,
                ownerDerivationIndex: descriptor.ownerDerivationIndex,
                ownerPublicKey: descriptor.ownerPublicKey,
                redeemScriptHex: descriptor.redeemScriptHex,
                vaultAddress: descriptor.vaultAddress
            )
        )
        onCreated()
    }

    @MainActor
    private func deriveDescriptor() async {
        guard descriptor == nil,
              let profile = walletStore.profiles.first(where: { $0.id == profileID }),
              let delayDAA
        else { return }

        do {
            descriptor = try await engine.deriveProtectedVault(
                profile: profile,
                receiveIndex: profile.nextReceiveIndex,
                approvedAddress: approvedAddress,
                delayDAA: delayDAA
            )
            derivationError = nil
        } catch {
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

private struct ProtectedVaultDetailView: View {
    let vault: ProtectedVault
    let onFund: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var protectedVaultStore: ProtectedVaultStore
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @State private var showingDeleteConfirmation = false
    @State private var showingSend = false
    @State private var isRefreshing = false
    @State private var refreshError: String?

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("State", value: vault.status.title)
                LabeledContent("Funding", value: vault.fundingOutpoints.isEmpty ? "Not Funded" : "Funded")
                if let lockedAmount = vault.lockedAmount {
                    LabeledContent("Locked Balance", value: "\(lockedAmount.formatted()) KAS")
                }
                LabeledContent(
                    "Created",
                    value: vault.createdAt.formatted(date: .abbreviated, time: .shortened)
                )
            }

            Section("Vault Settings") {
                LabeledContent("Deposit", value: "\(vault.amount.formatted()) KAS")
                LabeledContent("Approved Addresses", value: "1")
                LabeledContent("Security Delay", value: vault.delaySummary)
            }

            Section("Approved Destination") {
                Text(vault.approvedAddress)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.vertical, 3)
            }


            if let vaultAddress = vault.vaultAddress {
                Section("Vault Address") {
                    Text(vaultAddress)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let transactionID = vault.fundingTransactionID {
                Section("Funding Transaction") {
                    Link(transactionID, destination: preferences.explorer.transactionURL(transactionID))
                        .font(.caption.monospaced())
                }
            }

            if !vault.fundingOutpoints.isEmpty {
                Section("Consensus Binding") {
                    if vault.covenantIDs.isEmpty {
                        LabeledContent("Covenant ID", value: "Missing")
                        Text("This funding output was created without a covenant ID. The pinned Kaspa consensus engine rejects both Protected Vault spending paths from this state.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else {
                        ForEach(vault.covenantIDs, id: \.self) { covenantID in
                            Text(covenantID)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section {
                Text(statusExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let refreshError {
                    Text("Refresh failed: \(refreshError)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if vault.status == .active {
                Section {
                    Button(action: { showingSend = true }) {
                        Text("Send from Vault")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
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
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

        }
        .navigationTitle("Protected Vault")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshVault() }
        .refreshable { await refreshVault() }
        .navigationDestination(isPresented: $showingSend) {
            ProtectedVaultSendView(vault: vault)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Delete Vault", systemImage: "trash", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Vault Options")
            }
        }
        .confirmationDialog(
            "Delete this vault?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Vault", role: .destructive) {
                protectedVaultStore.remove(id: vault.id)
                dismiss()
            }
        } message: {
            Text("This removes only the local vault record. No on-chain funds are affected.")
        }
    }

    @MainActor
    private func refreshVault() async {
        guard !isRefreshing, let address = vault.vaultAddress else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let result = try await engine.syncAddress(
                address,
                nodeConfiguration: preferences.nodeConfiguration
            )
            protectedVaultStore.updateOnChainFunding(id: vault.id, utxos: result.utxos)
            refreshError = nil
        } catch {
            refreshError = error.localizedDescription
        }
    }

    private var statusExplanation: String {
        switch vault.status {
        case .active:
            return "The connected node reports a covenant-tagged unspent output at this vault address."
        case .incompatibleFunding:
            return "Funds are present, but this output is untagged and cannot satisfy the Protected Vault covenant under the pinned consensus rules."
        case .fundingBroadcast:
            return "The funding transaction was broadcast, but its output is not visible from the connected node yet."
        case .localDraft:
            return "No unspent covenant output is currently visible at this vault address."
        case .spent:
            return "This vault was spent to its approved destination."
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

    private let feeSompi: UInt64 = 1_000_000

    var body: some View {
        Form {
            Section("Available in Vault") {
                LabeledContent("Locked Balance", value: "\((vault.lockedAmount ?? vault.amount).formatted()) KAS")
                LabeledContent("Unspent Outputs", value: "\(vault.fundingOutpoints.count)")
            }
            Section("Spend Paths") {
                Label("Approved destination — available immediately", systemImage: "checkmark.shield")
                Label("Other destinations — not enabled yet", systemImage: "clock.badge.exclamationmark")
            }
            Section("Approved Destination") {
                Text(vault.approvedAddress)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                LabeledContent("Network Fee", value: formatKas(feeSompi))
                Text("V1 sends the vault's entire balance, minus the fee, to this exact approved address.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isBuilding)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            if let errorMessage {
                Section {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Send from Vault")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingSigning) {
            if let signingReview {
                VerifiedSigningPreparationView(
                    review: signingReview,
                    protectedVaultMode: true,
                    protectedVaultApprovedSpend: true,
                    onBroadcastComplete: { _ in
                        protectedVaultStore.recordApprovedSpend(id: vault.id)
                    },
                    onComplete: { showingSigning = false }
                )
            }
        }
    }

    @MainActor
    private func buildApprovedSpend() async {
        guard !isBuilding, let redeem = vault.redeemScriptHex else { return }
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
            guard sync.utxos.count == 1, let utxo = sync.utxos.first,
                  let covenantID = utxo.covenantID,
                  covenantID.count == 64 else {
                throw KasSignerEngine.EngineError.javascript(
                    "Approved V1 spending requires exactly one covenant-tagged vault output."
                )
            }
            guard utxo.amount > feeSompi else {
                throw KasSignerEngine.EngineError.javascript("Vault balance does not cover the network fee.")
            }
            let pskb = try await engine.buildProtectedVaultApprovedSpendPSKB(
                utxo: utxo,
                redeemScriptHex: redeem,
                approvedAddress: vault.approvedAddress,
                feeSompi: feeSompi
            )
            let summary = try await engine.summarizePSKB(pskb)
            let sendAmount = utxo.amount - feeSompi
            guard summary.transactionVersion == 1,
                  summary.inputCount == 1, summary.outputCount == 1,
                  summary.totalInputSompi == utxo.amount,
                  summary.totalOutputSompi == sendAmount,
                  summary.feeSompi == feeSompi,
                  summary.inputs?.first?.txID?.lowercased() == utxo.txID.lowercased(),
                  summary.inputs?.first?.index == utxo.index,
                  summary.outputs?.first?.address?.lowercased() == vault.approvedAddress.lowercased(),
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
                destination: vault.approvedAddress,
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
        "\((Decimal(sompi) / Decimal(100_000_000)).formatted()) KAS"
    }
}

private struct FundProtectedVaultView: View {
    let vault: ProtectedVault
    let profile: WalletProfile

    @EnvironmentObject private var syncService: WalletSyncService

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    fundingSummaryCard
                    approvedDestinationCard
                    securityCard
                    fundingEffectCard
                    availabilityNotice
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))

            NavigationLink {
                VaultFundingUTXOSelectionView(vault: vault, profile: profile)
            } label: {
                Text("Select Funding UTXOs")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
        }
        .navigationTitle("Fund Protected Vault")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
    }

    private var fundingSummaryCard: some View {
        VStack(spacing: 0) {
            fundingRow("Funding Wallet", value: profile.name)
            Divider()
            fundingRow("Available Balance", value: availableBalanceText)
            Divider()
            fundingRow("Deposit", value: "\(vault.amount.formatted()) KAS")
            Divider()
            fundingRow("Estimated Fee", value: "Not calculated")
        }
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var approvedDestinationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Approved Destination")
                .font(.subheadline.weight(.medium))

            Text(vault.approvedAddress)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var securityCard: some View {
        VStack(spacing: 0) {
            fundingRow("Security Delay", value: vault.delaySummary)
            Divider()
            fundingRow("Network", value: "Kaspa Mainnet")
        }
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var fundingEffectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("What Funding Does", systemImage: "lock.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)

            Text("Funding moves the deposit from \(profile.name) into a new protected covenant UTXO. The approved destination can be used immediately; every other destination must wait \(vault.delaySummary).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var availabilityNotice: some View {
        Label {
            Text("Funding transaction construction and signing are the next implementation step. This screen cannot move funds yet.")
        } icon: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.tint)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var availableBalanceText: String {
        guard let balance = syncService.snapshot?.balance.totalKas else {
            return "Unavailable"
        }

        return "\(balance.formatted(.number.precision(.fractionLength(0...8)))) KAS"
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

    @EnvironmentObject private var syncService: WalletSyncService
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
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!selectionCoversDeposit)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .navigationTitle("Select Funding UTXOs")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .navigationDestination(isPresented: $showingFundingReview) {
            ReviewVaultFundingView(
                vault: vault,
                profile: profile,
                selectedUTXOs: fundingSelectionSnapshot
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
                    Text(selectedTotalSompi.map(formatKas) ?? "0 KAS")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }

            HStack {
                Text("Vault deposit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(vault.amount.formatted()) KAS")
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

                    Text(utxo.blockDAAScore > 0 ? "Confirmed" : "Not confirmed")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(
                            utxo.blockDAAScore > 0
                                ? Color(red: 0.18, green: 0.68, blue: 0.62)
                                : Color.orange
                        )
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
        return "\(amount.formatted(.number.precision(.fractionLength(0...8)))) KAS"
    }
}

private struct ReviewVaultFundingView: View {
    let vault: ProtectedVault
    let profile: WalletProfile
    let selectedUTXOs: [WalletUTXO]

    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var walletStore: WalletStore
    @State private var selectedFee: VaultFundingFeeChoice = .normal
    @State private var customFeeText = ""
    @State private var isBuilding = false
    @State private var buildErrorMessage = ""
    @State private var showingBuildError = false
    @State private var verifiedReview: VerifiedVaultFundingReview?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    summaryCard
                    feeCard
                    destinationCard
                    noticeCard
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            Button {
                Task { await buildAndVerifyUnsignedFunding() }
            } label: {
                if isBuilding {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    Text("Build Unsigned Funding PSKB")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
                .font(.headline)
                .buttonStyle(.borderedProminent)
                .disabled(fundingPlan == nil || isBuilding || vault.vaultAddress == nil)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
        }
        .navigationTitle("Review Vault Funding")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .alert("Funding PSKB could not be built", isPresented: $showingBuildError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(buildErrorMessage)
        }
        .navigationDestination(item: $verifiedReview) { review in
            VerifiedVaultFundingReviewView(review: review)
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
        guard let estimate = syncService.feeEstimate else { return nil }
        switch selectedFee {
        case .low: return estimate.lowSompiPerGram
        case .normal: return estimate.normalSompiPerGram
        case .priority: return estimate.prioritySompiPerGram
        case .custom: return nil
        }
    }

    @MainActor
    private func buildAndVerifyUnsignedFunding() async {
        guard !isBuilding else { return }
        guard let plan = fundingPlan,
              let vaultAddress = vault.vaultAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
              !vaultAddress.isEmpty
        else {
            showBuildError("The vault funding plan or derived vault address is unavailable.")
            return
        }

        isBuilding = true
        defer { isBuilding = false }

        do {
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
            let summary = try await engine.summarizePSKB(pskb)
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
            verifiedReview = VerifiedVaultFundingReview(
                profileID: activeProfile.id,
                vaultID: vault.id,
                vaultAddress: vaultAddress,
                covenantScriptHex: vault.redeemScriptHex,
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
            reviewRow("Input Total", value: formatKas(inputSompi))
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

    private var feeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fee")
                .font(.headline)

            Picker("Fee", selection: $selectedFee) {
                ForEach(VaultFundingFeeChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            if selectedFee == .custom {
                HStack(spacing: 10) {
                    TextField("0", text: $customFeeText)
                        .keyboardType(.decimalPad)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Text("KAS")
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Approved Destination")
                .font(.subheadline.weight(.medium))
            Text(vault.approvedAddress)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Divider()
            reviewRow("Security Delay", value: vault.delaySummary)
            Divider()
            reviewRow("Network", value: "Kaspa Mainnet")
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var noticeCard: some View {
        Label {
            Text("Initial funding behaves like a normal KasSigner send: selected wallet inputs fund the vault deposit, fee, and wallet change. The covenant restrictions apply after the vault is funded. No transaction, signature, or broadcast has been created.")
        } icon: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.tint)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func reviewRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 13)
    }

    private func formatKas(_ sompi: UInt64) -> String {
        let amount = Decimal(sompi) / Decimal(100_000_000)
        return "\(amount.formatted()) KAS"
    }

    private var requestedFeeSompi: UInt64? {
        if selectedFee == .custom {
            return parseKasTextToSompi(customFeeText)
        }

        guard let estimate = syncService.feeEstimate,
              estimate.normalSompiPerGram > 0
        else { return nil }

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
                ? "Enter a positive exact fee in KAS."
                : "Connecting to the node for a live fee estimate."
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
    let depositSompi: UInt64
    let feeSompi: UInt64
    let changeSompi: UInt64
    let inputCount: Int
    let selectedOutpoints: [String]
    let unsignedPSKB: String
    let digest: String

    init(
        profileID: UUID,
        vaultID: UUID,
        vaultAddress: String,
        covenantScriptHex: String?,
        verified: VerifiedProtectedVaultFunding,
        unsignedPSKB: String,
        digest: String
    ) {
        self.profileID = profileID
        self.vaultID = vaultID
        self.vaultAddress = vaultAddress
        self.covenantScriptHex = covenantScriptHex
        depositSompi = verified.depositSompi
        feeSompi = verified.feeSompi
        changeSompi = verified.changeSompi
        inputCount = verified.inputCount
        selectedOutpoints = verified.selectedOutpoints
        self.unsignedPSKB = unsignedPSKB
        self.digest = digest
    }
}

private struct VerifiedVaultFundingReviewView: View {
    let review: VerifiedVaultFundingReview
    @EnvironmentObject private var protectedVaultStore: ProtectedVaultStore
    @State private var isCovenantScriptExpanded = false
    @State private var showingM5Signing = false

    private let accentColor = Color(red: 0.20, green: 0.62, blue: 0.57)

    var body: some View {
        List {
            Section("Verified Funding") {
                LabeledContent("Selected Inputs", value: "\(review.inputCount)")
                LabeledContent("Vault Deposit", value: formatKas(review.depositSompi))
                LabeledContent("Funding Fee", value: formatKas(review.feeSompi))
                LabeledContent("Wallet Change", value: formatKas(review.changeSompi))
            }

            Section("Security Checks") {
                VStack(alignment: .leading, spacing: 12) {
                    checkRow("Selected inputs match the decoded PSKB")
                    checkRow("Vault destination and amount match")
                    checkRow("All change outputs belong to this wallet")
                    checkRow("Fee matches decoded input and output totals")
                }
                .padding(.vertical, 4)
            }

            Section("Vault Address") {
                Text(review.vaultAddress)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
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
                Text("The M5 may sign this verified funding transaction. Broadcasting remains disabled for Protected Vault funding.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    showingM5Signing = true
                } label: {
                    Text("Continue to M5 Signing")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Verified Funding PSKB")
        .navigationBarTitleDisplayMode(.inline)
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
            selectedInputsVerified: true,
            destinationVerified: true,
            changeVerified: true,
            feeVerified: true
        )
    }

    private func checkRow(_ title: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(accentColor)
            Text(title)
                .font(.subheadline)
        }
    }

    private func formatKas(_ sompi: UInt64) -> String {
        let amount = Decimal(sompi) / Decimal(100_000_000)
        return "\(amount.formatted()) KAS"
    }
}

private enum VaultFundingBuildError: LocalizedError {
    case walletStateChanged

    var errorDescription: String? {
        "The wallet address state changed. Return to the wallet and try again."
    }
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

struct SendUTXOSelectionView: View {
    let profile: WalletProfile
    let transactionType: SendTransactionType
    let clearSelectionOnAppear: Bool
    @Binding var showingSendFlow: Bool

    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var coinControlStore: UTXOCoinControlStore
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var priceService: PriceService
    @State private var showingUTXOSelectionLimit = false
    @State private var showingDestination = false
    @State private var showingSessionError = false
    @State private var activeSessionID: UUID?

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
                        guard let session = walletStore.beginSendSession(
                            profileID: profile.id,
                            selectedUTXOs: selectedUTXOs,
                            transactionType: transactionType
                        ) else {
                            showingSessionError = true
                            return
                        }
                        activeSessionID = session.id
                        showingDestination = true
                    } label: {
                        Text(selectedUTXOs.count == 1 ? "Spend UTXO" : "Spend UTXOs")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedUTXOs.isEmpty)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
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
        .onAppear {
            coinControlStore.activate(profileID: profile.id)
            if clearSelectionOnAppear {
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
                        Text(utxo.blockDAAScore > 0 ? "Confirmed" : "Not confirmed")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(
                                utxo.blockDAAScore > 0
                                    ? Color(red: 0.18, green: 0.68, blue: 0.62)
                                    : Color.orange
                            )

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
