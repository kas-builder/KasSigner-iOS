import SwiftUI

struct SettingsView: View {
    let onWalletSelected: (() -> Void)?

    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var syncService: WalletSyncService
    @State private var isDeriving = false
    @State private var derivationError: String?

    init(onWalletSelected: (() -> Void)? = nil) {
        self.onWalletSelected = onWalletSelected
    }

    var body: some View {
        NavigationStack {
            List {
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
                        }
                        .onDelete(perform: walletStore.remove)
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

                Section("About") {
                    LabeledContent("App", value: "KasSigner")
                    LabeledContent("Version", value: "1.22")
                }
            }
            .navigationTitle("Settings")
            .alert("Address Derivation Failed", isPresented: Binding(
                get: { derivationError != nil },
                set: { if !$0 { derivationError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(derivationError ?? "Unknown error")
            }
        }
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
            engine: engine,
            preferences: preferences,
            force: true
        )
    }

    private func nodeHost(_ nodeURL: String) -> String {
        URL(string: nodeURL)?.host ?? nodeURL
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
            syncService.reset()
        } catch {
            derivationError = error.localizedDescription
        }
    }
}
