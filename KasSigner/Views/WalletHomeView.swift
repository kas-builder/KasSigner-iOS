import SwiftUI
import UIKit

struct WalletHomeView: View {
    private enum WalletRoute: Hashable {
        case receive(UUID)
        case programmableUTXOTypes(UUID)
        case createTimeLockedUTXO(UUID)
        case createProtectedVault(UUID)
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
    @State private var showingAddWallet = false
    @State private var showingSecondaryCurrency = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if let profile = walletStore.selectedProfile {
                    walletContent(profile)
                } else {
                    ContentUnavailableView {
                        Label("No Account", systemImage: "wallet.pass")
                    } description: {
                        Text("Import the public wallet data exported by KasSigner. Private keys remain on the M5 device.")
                    } actions: {
                        Button("Add KasSigner Account") { showingAddWallet = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle(walletStore.selectedProfile == nil ? "KasSigner" : "")
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
                        CreateProtectedVaultView(profile: profile)
                    } else {
                        unavailableAccountView
                    }
                }
            }
        }
        .onChange(of: walletStore.selectedProfileID) { oldValue, newValue in
            guard oldValue != newValue else { return }
            showingSendFlow = false
            navigationPath = NavigationPath()
        }
    }

    private func walletContent(_ profile: WalletProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 0) {
                    Text("Kas")
                        .foregroundStyle(.primary)
                    Text("Signer")
                        .foregroundStyle(.primary)
                }
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

                if let snapshot = syncService.snapshot {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("UTXOs", value: "\(snapshot.balance.utxoCount)")
                        TimelineView(.periodic(from: .now, by: 9)) { context in
                            LabeledContent("Last refreshed", value: relativeAge(from: snapshot.syncedAt, now: context.date))
                        }
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
            SendUTXOSelectionView(
                profile: profile,
                clearSelectionOnAppear: true,
                showingSendFlow: $showingSendFlow
            )
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
        }
        .navigationTitle("Programmable UTXO")
        .navigationBarTitleDisplayMode(.large)
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
        UIPasteboard.general.string = address
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

    @State private var amountText = ""
    @State private var addressDraft = ""
    @State private var approvedAddresses: [String] = []
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

    private var normalizedDraft: String {
        normalizeAddress(addressDraft)
    }

    private var draftCanBeAdded: Bool {
        normalizedDraft.hasPrefix("kaspa:")
            && normalizedDraft.count > "kaspa:".count
            && !approvedAddresses.contains(normalizedDraft)
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

            Section("Approved Addresses") {
                ForEach(approvedAddresses, id: \.self) { address in
                    HStack(spacing: 12) {
                        Text(address)
                            .font(.footnote.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button(role: .destructive) {
                            approvedAddresses.removeAll { $0 == address }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }

                TextField("kaspa:...", text: $addressDraft, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(2...4)

                HStack(spacing: 10) {
                    Button {
                        addressDraft = normalizeAddress(UIPasteboard.general.string ?? "")
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

                Button("Add Approved Address") {
                    approvedAddresses.append(normalizedDraft)
                    addressDraft = ""
                }
                .frame(maxWidth: .infinity)
                .disabled(!draftCanBeAdded)
            }

            Section {
                delayPicker("Days", selection: $delayDays, range: 0...365)
                delayPicker("Hours", selection: $delayHours, range: 0...23)
                delayPicker("Minutes", selection: $delayMinutes, range: 0...59)
            } header: {
                Text("Security Delay")
            } footer: {
                Text("Unapproved withdrawals and changes to approved addresses remain cancellable for this delay.")
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

                vaultBehaviorRow(
                    title: "Cancellation window",
                    detail: "Delayed withdrawals and approved-address changes can be cancelled during the delay.",
                    systemImage: "arrow.uturn.backward.circle"
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
                .disabled(!amountIsValid || approvedAddresses.isEmpty || !delayIsValid)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Create Protected Vault")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingReview) {
            ReviewProtectedVaultView(
                amountText: amountText,
                approvedAddresses: approvedAddresses,
                delayDays: delayDays,
                delayHours: delayHours,
                delayMinutes: delayMinutes
            )
        }
        .sheet(isPresented: $showingScanner) {
            QRScannerView { scannedValue in
                addressDraft = normalizeAddress(scannedValue)
                showingScanner = false
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
    let amountText: String
    let approvedAddresses: [String]
    let delayDays: Int
    let delayHours: Int
    let delayMinutes: Int

    @State private var showingFinalConfirmation = false

    var body: some View {
        Form {
            Section("Vault Summary") {
                LabeledContent("Deposit", value: "\(amountText) KAS")
                LabeledContent("Approved Addresses", value: "\(approvedAddresses.count)")
                LabeledContent("Security Delay", value: delaySummary)
                LabeledContent("Estimated Fee", value: "—")
            }

            Section("Approved Destinations") {
                ForEach(Array(approvedAddresses.enumerated()), id: \.offset) { index, address in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Address #\(index + 1)")
                            .font(.subheadline.weight(.medium))

                        Text(address)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
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

            Section {
                Button {
                    showingFinalConfirmation = true
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Review Protected Vault")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingFinalConfirmation) {
            ConfirmProtectedVaultView(
                amountText: amountText,
                approvedAddresses: approvedAddresses,
                delaySummary: delaySummary
            )
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
}

private struct ConfirmProtectedVaultView: View {
    let amountText: String
    let approvedAddresses: [String]
    let delaySummary: String

    @EnvironmentObject private var appLockService: AppLockService
    @State private var identityConfirmed = false

    var body: some View {
        Form {
            Section("Final Confirmation") {
                LabeledContent("Deposit", value: "\(amountText) KAS")
                LabeledContent("Approved Addresses", value: "\(approvedAddresses.count)")
                LabeledContent("Security Delay", value: delaySummary)
                LabeledContent("Estimated Fee", value: "—")
            }

            Section("Approved Destinations") {
                ForEach(Array(approvedAddresses.enumerated()), id: \.offset) { index, address in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Address #\(index + 1)")
                            .font(.subheadline.weight(.medium))

                        Text(address)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
                }
            }

            Section {
                Label {
                    Text("Confirm the deposit, approved destinations, and security delay before continuing.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.footnote)
            }

            if identityConfirmed {
                Section {
                    Label("Identity Confirmed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Section {
                    Button {
                        Task {
                            if await appLockService.authorizeProtectedVaultCreation() {
                                identityConfirmed = true
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
                    .disabled(appLockService.isAuthenticating)
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
        .navigationTitle("Confirm Protected Vault")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SendUTXOSelectionView: View {
    let profile: WalletProfile
    let clearSelectionOnAppear: Bool
    @Binding var showingSendFlow: Bool

    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var coinControlStore: UTXOCoinControlStore
    @State private var showingUTXOSelectionLimit = false

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
                        .padding(.horizontal, 14)
                        .padding(.bottom, 20)
                    }
                    .background(Color(.systemGroupedBackground))

                    NavigationLink {
                        SendDestinationView(
                            profile: profile,
                            selectedUTXOs: selectedUTXOs,
                            showingSendFlow: $showingSendFlow
                        )
                    } label: {
                        Text(selectedUTXOs.count == 1 ? "Send UTXO" : "Send UTXOs")
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
                    Text(
                        selectedTotalSompi.map {
                            formatKas(sompi: $0)
                        } ?? "Invalid total"
                    )
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }

            HStack(spacing: 10) {
                Button(selectedUTXOs.count == maximumSelectableCount
                    ? "Clear All"
                    : (utxos.count > UTXOCoinControlStore.maximumSelectedUTXOs
                        ? "Select First 8"
                        : "Select All")) {
                    if selectedUTXOs.count == maximumSelectableCount {
                        coinControlStore.clearSelection()
                    } else {
                        if coinControlStore.selectAll(utxos) > 0 {
                            showingUTXOSelectionLimit = true
                        }
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
                    Text(formatKas(sompi: utxo.amount))
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
}
