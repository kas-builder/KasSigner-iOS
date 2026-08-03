import SwiftUI
import UIKit

struct SettingsView: View {
    let onWalletSelected: (() -> Void)?

    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var coinControlStore: UTXOCoinControlStore
    @State private var isDeriving = false
    @State private var derivationError: String?
    @State private var profileBeingRenamed: WalletProfile?
    @State private var renameDraft = ""
    @State private var profilePendingDeletion: WalletProfile?
    @State private var showKpubCopiedBanner = false

    init(onWalletSelected: (() -> Void)? = nil) {
        self.onWalletSelected = onWalletSelected
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    Picker("Appearance", selection: $preferences.appearanceTheme) {
                        ForEach(AppearanceTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                Section("Network") {
                    LabeledContent("Kaspa network", value: "Mainnet")
                    LabeledContent("Wallet engine", value: engine.statusText)
                }

                Section {
                    Picker("Explorer", selection: $preferences.explorer) {
                        ForEach(ExplorerChoice.allCases) { explorer in
                            Text(explorer.title).tag(explorer)
                        }
                    }
                } header: {
                    Text("Block Explorer")
                }

                Section {
                    Menu {
                        ForEach(NodeConnectionMode.allCases) { mode in
                            Button {
                                preferences.nodeMode = mode
                            } label: {
                                if preferences.nodeMode == mode {
                                    Label(mode.title, systemImage: "checkmark")
                                } else {
                                    Text(mode.title)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(preferences.nodeMode.title)
                                .foregroundStyle(.tint)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        .contentShape(Rectangle())
                    }

                    if preferences.nodeMode == .custom {
                        TextField("wss://your-node.example", text: $preferences.customNodeURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                    }

                    statusRow

                    if let snapshot = syncService.snapshot {
                        LabeledContent("Active node", value: nodeHost(snapshot.nodeURL))
                        Text(snapshot.nodeURL)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Node Settings")
                } footer: {
                    if preferences.nodeMode == .automatic {
                    } else {
                        Text("Connect directly to your own Kaspa node. Wallet access requires a public ws:// or wss:// wRPC endpoint with UTXO indexing enabled.")
                    }
                }

                if !walletStore.profiles.isEmpty {
                    Section("Accounts") {
                        ForEach(walletStore.profiles) { profile in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(profile.name)
                                    Text("Watch-only account")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if profile.id == walletStore.selectedProfile?.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                walletStore.selectedProfileID = profile.id
                                syncService.preload(profile: profile)
                                onWalletSelected?()
                            }
                            .contextMenu {
                                Button {
                                    beginRenaming(profile)
                                } label: {
                                    Label {
                                        Text("Rename")
                                    } icon: {
                                        Image(uiImage: primaryMenuIcon("pencil"))
                                    }
                                }

                                Button {
                                    copyKpub(profile)
                                } label: {
                                    Label {
                                        Text("Copy kpub")
                                    } icon: {
                                        Image(uiImage: primaryMenuIcon("doc.on.doc"))
                                    }
                                }

                                Divider()

                                Button(role: .destructive) {
                                    profilePendingDeletion = profile
                                } label: {
                                    Label {
                                        Text("Delete")
                                    } icon: {
                                        Image(uiImage: destructiveMenuIcon("trash"))
                                    }
                                }
                            }
                        }
                    }
                }

                if let profile = walletStore.selectedProfile {
                    Section {
                        LabeledContent("Receive addresses", value: "\(profile.receiveAddresses.count)")
                        LabeledContent("Change addresses", value: "\(profile.changeAddresses.count)")
                        Button {
                            Task { await deriveMoreAddresses(profile) }
                        } label: {
                            if isDeriving {
                                ProgressView()
                            } else {
                                Text("Derive 20 More of Each")
                            }
                        }
                        .disabled(isDeriving)
                    } header: {
                        Text("Address Derivation")
                    } footer: {
                        Text("Extends the watch-only receive and change address pools from the imported kpub. Private keys remain on the M5 KasSigner.")
                    }
                }

                Section("General") {
                    NavigationLink {
                        OtherSettingsView()
                    } label: {
                        Text("Currency & Price")
                    }
                }

                Section("About") {
                    LabeledContent("App", value: "KasSigner")
                    LabeledContent(
                        "Version",
                        value: Bundle.main.object(
                            forInfoDictionaryKey: "CFBundleShortVersionString"
                        ) as? String ?? "—"
                    )

                    NavigationLink {
                        DonateView()
                    } label: {
                        Text("Donate")
                    }
                }
            }
            .alert("Rename Account", isPresented: renameAlertIsPresented) {
                TextField("Account name", text: $renameDraft)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()

                Button("Cancel", role: .cancel) {
                    clearRenameState()
                }

                Button("Save") {
                    saveRenamedProfile()
                }
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("Enter a new name for this watch-only account.")
            }
            .navigationTitle("Settings")
            .alert(
                "Delete account?",
                isPresented: deleteAlertIsPresented,
                presenting: profilePendingDeletion
            ) { profile in
                Button("Delete", role: .destructive) {
                    deleteProfile(profile)
                }

                Button("Cancel", role: .cancel) {
                    profilePendingDeletion = nil
                }
            } message: { profile in
                Text(
                    "This removes “\(profile.name)” from this iPhone. "
                        + "It does not affect funds or the KasSigner device."
                )
            }
            .alert("Address Derivation Failed", isPresented: Binding(
                get: { derivationError != nil },
                set: { if !$0 { derivationError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(derivationError ?? "Unknown error")
            }
            .overlay(alignment: .top) {
                if showKpubCopiedBanner {
                    Label("kpub copied", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(radius: 8, y: 3)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityAddTraits(.isStaticText)
                }
            }
        }
    }

    private var renameAlertIsPresented: Binding<Bool> {
        Binding(
            get: { profileBeingRenamed != nil },
            set: { isPresented in
                if !isPresented {
                    clearRenameState()
                }
            }
        )
    }

    private var deleteAlertIsPresented: Binding<Bool> {
        Binding(
            get: { profilePendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    profilePendingDeletion = nil
                }
            }
        )
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack {
            Text("Status")
            Spacer()
            switch syncService.state {
            case .failed:
                Text("No connection")
                    .foregroundStyle(.red)
            case .syncing:
                Text("Connecting...")
                    .foregroundStyle(.yellow)
            case .connected:
                Text("Connected")
                    .foregroundStyle(.green)
            case .idle:
                Text(syncService.isNetworkAvailable ? "Ready" : "No connection")
                    .foregroundStyle(syncService.isNetworkAvailable ? Color.secondary : Color.red)
            }
        }
    }

    private func refreshSelectedAccount() async {
        guard let profile = walletStore.selectedProfile else { return }
        await syncService.refresh(
            profile: profile,
            walletStore: walletStore,
            engine: engine,
            preferences: preferences,
            force: true
        )
    }

    private func nodeHost(_ nodeURL: String) -> String {
        URL(string: nodeURL)?.host ?? nodeURL
    }

    private func primaryMenuIcon(_ systemName: String) -> UIImage {
        UIImage(systemName: systemName)?
            .withTintColor(.label, renderingMode: .alwaysOriginal)
            ?? UIImage()
    }

    private func destructiveMenuIcon(_ systemName: String) -> UIImage {
        UIImage(systemName: systemName)?
            .withTintColor(.systemRed, renderingMode: .alwaysOriginal)
            ?? UIImage()
    }

    private func beginRenaming(_ profile: WalletProfile) {
        profileBeingRenamed = profile
        renameDraft = profile.name
    }

    private func clearRenameState() {
        profileBeingRenamed = nil
        renameDraft = ""
    }

    private func saveRenamedProfile() {
        let cleanedName = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var profile = profileBeingRenamed, !cleanedName.isEmpty else { return }
        profile.name = cleanedName
        walletStore.update(profile)
        clearRenameState()
    }

    private func copyKpub(_ profile: WalletProfile) {
        UIPasteboard.general.string = profile.kpub

        withAnimation(.snappy) {
            showKpubCopiedBanner = true
        }

        Task {
            try? await Task.sleep(for: .seconds(1.6))
            await MainActor.run {
                withAnimation(.snappy) {
                    showKpubCopiedBanner = false
                }
            }
        }
    }

    private func deleteProfile(_ profile: WalletProfile) {
        guard let index = walletStore.profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }

        let wasSelected = walletStore.selectedProfile?.id == profile.id
        WalletSnapshotCache.shared.remove(profileID: profile.id)
        coinControlStore.removeData(profileID: profile.id)
        walletStore.remove(at: IndexSet(integer: index))

        if wasSelected {
            syncService.reset()
        }

        profilePendingDeletion = nil
    }

    private func deriveMoreAddresses(_ profile: WalletProfile) async {
        isDeriving = true
        defer { isDeriving = false }

        do {
            let result = try await engine.extendAddresses(for: profile)
            var updated = profile
            updated.receiveAddresses = result.receiveAddresses
            updated.changeAddresses = result.changeAddresses
            walletStore.update(updated)
            await refreshSelectedAccount()
        } catch {
            derivationError = error.localizedDescription
        }
    }
}

private struct OtherSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var priceService: PriceService

    var body: some View {
        Form {
            Section {
                Picker("Currency", selection: $preferences.secondaryCurrency) {
                    ForEach(SecondaryCurrency.allCases) { currency in
                        Text(currency.title).tag(currency)
                    }
                }
            } header: {
                Text("Secondary Currency")
            } footer: {
                Text("Price the displayed KAS balance in USD or BTC.")
            }

            Section {
                Picker("Price Source", selection: $preferences.priceProvider) {
                    ForEach(PriceProviderChoice.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }

                LabeledContent("Active source") {
                    Text(priceService.activeProvider?.title ?? "Not available")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Status") {
                    priceStatus
                }

                if let lastUpdated = priceService.lastUpdated {
                    LabeledContent("Last updated") {
                        Text(lastUpdated, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task {
                        await priceService.refresh(preferences: preferences, force: true)
                    }
                } label: {
                    if priceService.state == .refreshing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Refreshing Price…")
                        }
                    } else {
                        Label("Refresh Price", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(priceService.state == .refreshing)
            } header: {
                Text("Price Data")
            } footer: {
                if preferences.priceProvider == .automatic {
                    Text("Automatically uses the healthiest available source, with CoinGecko and CoinPaprika as fallbacks.")
                } else {
                    Text("Use \(preferences.priceProvider.title) as the preferred source. Automatic fallback will remain available if it cannot be reached.")
                }
            }
        }
        .navigationTitle("Currency & Price")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await priceService.refresh(preferences: preferences)
        }
        .onChange(of: preferences.priceProvider) { _, _ in
            Task {
                await priceService.refresh(preferences: preferences, force: true)
            }
        }
    }

    @ViewBuilder
    private var priceStatus: some View {
        switch priceService.state {
        case .idle:
            Text("Ready")
                .foregroundStyle(.secondary)
        case .refreshing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Refreshing")
            }
            .foregroundStyle(.secondary)
        case .available:
            Text("Current")
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct DonateView: View {
    private let donationAddress =
        "kaspa:qqpzpn5e7enn2ylfdxvlwtm3829gn6j9z9dnnmcsw5arkgnurktty6ulgzkfk"

    @State private var showCopiedBanner = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                SharedQRCodeView(payload: donationAddress)
                    .accessibilityLabel("Donation address QR code")

                Button {
                    UIPasteboard.general.string = donationAddress
                    showCopyBanner()
                } label: {
                    VStack(spacing: 8) {
                        Text(twoLineDonationAddress)
                            .font(.system(size: 14.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: false, vertical: true)

                        Label("Tap address to copy", systemImage: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(donationAddress)
                .accessibilityHint("Copies the full donation address")
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Donate")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if showCopiedBanner {
                Label("Address copied", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 8, y: 3)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.isStaticText)
            }
        }
    }

    private var twoLineDonationAddress: String {
        let midpoint = donationAddress.index(
            donationAddress.startIndex,
            offsetBy: donationAddress.count / 2
        )
        return String(donationAddress[..<midpoint])
            + "\n"
            + String(donationAddress[midpoint...])
    }

    private func showCopyBanner() {
        withAnimation(.snappy) {
            showCopiedBanner = true
        }

        Task {
            try? await Task.sleep(for: .seconds(1.6))
            await MainActor.run {
                withAnimation(.snappy) {
                    showCopiedBanner = false
                }
            }
        }
    }
}
