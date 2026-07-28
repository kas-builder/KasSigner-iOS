import SwiftUI

struct AddWalletView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var engine: KasSignerEngine

    @State private var walletName = ""
    @State private var kpub = ""
    @State private var isImporting = false
    @State private var isShowingScanner = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Account name", text: $walletName)

                    TextField("KasSigner kpub", text: $kpub, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(4...8)

                    Button {
                        isShowingScanner = true
                    } label: {
                        Label("Scan kpub from M5 Stack", systemImage: "qrcode.viewfinder")
                    }
                }

                Text("KasSigner stores watch-only public wallet data. It never requests or stores the seed phrase or private keys.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)

                if isImporting {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Validating wallet and deriving addresses…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { importWallet() }
                        .disabled(!canImport)
                }
            }
            .task {
                engine.startIfNeeded()
            }
            .fullScreenCover(isPresented: $isShowingScanner) {
                QRScannerView { scannedValue in
                    kpub = scannedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    errorMessage = nil
                    isShowingScanner = false
                }
            }
        }
    }

    private var canImport: Bool {
        !walletName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !kpub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        engine.isReady &&
        !isImporting
    }

    private func importWallet() {
        isImporting = true
        errorMessage = nil

        let cleanedName = walletName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedKpub = kpub.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                let imported = try await engine.importKpub(cleanedKpub)
                walletStore.add(
                    WalletProfile(
                        name: cleanedName,
                        kpub: imported.kpub,
                        receiveAddresses: imported.receiveAddresses,
                        changeAddresses: imported.changeAddresses
                    )
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }
}
