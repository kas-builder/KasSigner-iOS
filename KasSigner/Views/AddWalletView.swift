import CryptoKit
import SwiftUI
import UIKit

enum KpubQRPayloadError: LocalizedError {
    case invalidHex
    case invalidLength
    case unsupportedTransport
    case invalidKpub

    var errorDescription: String? {
        switch self {
        case .invalidHex:
            return "The KasSigner QR contained invalid binary data."
        case .invalidLength:
            return "The KasSigner QR contained an unexpected payload length."
        case .unsupportedTransport:
            return "This KasSigner QR format is not supported."
        case .invalidKpub:
            return "The KasSigner QR did not contain a valid account kpub."
        }
    }
}

enum KpubQRPayload {
    private static let transportVersion: UInt8 = 0x01
    private static let kpubVersion: [UInt8] = [0x03, 0x8f, 0x33, 0x2e]
    private static let accountZero: [UInt8] = [0x80, 0x00, 0x00, 0x00]
    private static let base58Alphabet = Array(
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    )

    static func rawKpubHex(from completedPayloadHex: String) throws -> String {
        let hex = completedPayloadHex.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard hex.count == 158 else { throw KpubQRPayloadError.invalidLength }
        guard hex.allSatisfy({ $0.isHexDigit }) else {
            throw KpubQRPayloadError.invalidHex
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(79)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw KpubQRPayloadError.invalidHex
            }
            bytes.append(byte)
            index = next
        }

        guard bytes[0] == transportVersion else {
            throw KpubQRPayloadError.unsupportedTransport
        }
        let raw = Array(bytes.dropFirst())
        guard Array(raw[0..<4]) == kpubVersion,
              raw[4] == 3,
              Array(raw[9..<13]) == accountZero,
              raw[45] == 0x02 || raw[45] == 0x03
        else {
            throw KpubQRPayloadError.invalidKpub
        }

        return raw.map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalKpub(from completedPayloadHex: String) throws -> String {
        let rawHex = try rawKpubHex(from: completedPayloadHex)
        var raw: [UInt8] = []
        raw.reserveCapacity(78)
        var index = rawHex.startIndex
        while index < rawHex.endIndex {
            let next = rawHex.index(index, offsetBy: 2)
            guard let byte = UInt8(rawHex[index..<next], radix: 16) else {
                throw KpubQRPayloadError.invalidHex
            }
            raw.append(byte)
            index = next
        }

        let firstHash = SHA256.hash(data: Data(raw))
        let secondHash = SHA256.hash(data: Data(firstHash))
        return base58Encode(raw + Array(secondHash.prefix(4)))
    }

    private static func base58Encode<C: Collection>(_ bytes: C) -> String
    where C.Element == UInt8 {
        let input = Array(bytes)
        var digits = [0]

        for byte in input {
            var carry = Int(byte)
            for index in digits.indices {
                carry += digits[index] << 8
                digits[index] = carry % 58
                carry /= 58
            }
            while carry > 0 {
                digits.append(carry % 58)
                carry /= 58
            }
        }

        let leadingZeros = input.prefix(while: { $0 == 0 }).count
        let prefix = String(repeating: "1", count: leadingZeros)
        let encoded = digits.reversed().map { base58Alphabet[$0] }
        return prefix + String(encoded)
    }
}

struct AddWalletView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var walletStore: WalletStore
    @EnvironmentObject private var protectedVaultStore: ProtectedVaultStore
    @EnvironmentObject private var engine: KasSignerEngine
    @EnvironmentObject private var syncService: WalletSyncService
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var discoveryPresentation:
        AccountDiscoveryPresentationModel

    @State private var walletName = ""
    @State private var kpub = ""
    @State private var isImporting = false
    @State private var isShowingScanner = false
    @State private var errorMessage: String?
    @State private var duplicateProfile: WalletProfile?
    @State private var scannerFeedback: QRScanFeedback = .idle
    @State private var scannerProgressText: String?
    @State private var lastScannedFrame = ""
    @State private var isProcessingScan = false
    @State private var recoveryWords = ""
    @State private var pendingTestnetWallet: TestnetHotWalletImportResult?
    @State private var showingTestnetWords = false
    @State private var didCopyTestnetWords = false
    @State private var isRestoringTestnetWallet = false
    @StateObject private var testnetImport = TestnetAccountImportCoordinator()

    private let teal = Color(red: 0.20, green: 0.62, blue: 0.57)

    var body: some View {
        NavigationStack {
            Form {
                if preferences.network == .testnet10 {
                    Section("Testnet 10 Account") {
                        TextField("Account name", text: $walletName)
                        Button("Generate 12-word wallet") {
                            Task { await prepareTestnetWallet(restore: false) }
                        }
                        .disabled(walletName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
                    }
                    Section("Restore from 12 words") {
                        TextField("Enter 12 recovery words", text: $recoveryWords, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(3...6)
                        Button("Import Account") {
                            Task { await prepareTestnetWallet(restore: true) }
                        }
                        .disabled(walletName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || recoveryWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || isImporting)
                    }
                } else {
                Section("Account") {
                    TextField("Account name", text: $walletName)

                    TextField("Paste kpub", text: $kpub, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(4...8)

                    Button {
                        isShowingScanner = true
                    } label: {
                        Label("Scan kpub", systemImage: "qrcode.viewfinder")
                    }
                }

                Text("KasSigner stores watch-only public wallet data. It never requests or stores the seed phrase or private keys.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(preferences.network == .testnet10 && isImporting)
                }
                ToolbarItem(placement: .principal) {
                    Text("Add Account")
                        .font(.headline)
                        .foregroundStyle(teal)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if preferences.network == .mainnet {
                        Button("Import") { importWallet() }
                            .disabled(!canImport)
                    }
                }
            }
            .task {
                engine.startIfNeeded()
            }
            .fullScreenCover(
                isPresented: $isShowingScanner,
                onDismiss: resetKpubScanner
            ) {
                QRScannerView(
                    feedback: scannerFeedback,
                    progressText: scannerProgressText
                ) { scannedValue in
                    Task { await processKpubScan(scannedValue) }
                }
            }
            .alert(
                "Account Already Added",
                isPresented: Binding(
                    get: { duplicateProfile != nil },
                    set: { isPresented in
                        if !isPresented {
                            duplicateProfile = nil
                        }
                    }
                ),
                presenting: duplicateProfile
            ) { profile in
                Button("View Account") {
                    walletStore.selectedProfileID = profile.id
                    duplicateProfile = nil
                    dismiss()
                }
                Button("Cancel", role: .cancel) {
                    duplicateProfile = nil
                }
            } message: { _ in
                Text("This KasSigner account is already on this iPhone.")
            }
            .overlay {
                if isImporting && preferences.network == .mainnet {
                    AccountDiscoveryLoadingView(
                        progress: discoveryPresentation.progress,
                        detail: discoveryPresentation.detail
                    )
                }
            }
            .sheet(isPresented: $showingTestnetWords, onDismiss: clearTestnetImportDraft) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Testnet 10 recovery words")
                                .font(.title2.bold())
                            Text(pendingTestnetWallet?.mnemonic ?? "")
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                            HStack(spacing: 12) {
                                Button {
                                    guard let words = pendingTestnetWallet?.mnemonic else { return }
                                    UIPasteboard.general.string = words
                                    didCopyTestnetWords = UIPasteboard.general.string == words
                                } label: {
                                    Label(didCopyTestnetWords ? "Copied" : "Copy",
                                          systemImage: didCopyTestnetWords ? "checkmark" : "doc.on.doc")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .sensoryFeedback(.success, trigger: didCopyTestnetWords)

                                Button {
                                    Task { await finishTestnetWallet() }
                                } label: {
                                    HStack(spacing: 8) {
                                        if testnetImport.isRunning {
                                            ProgressView()
                                                .tint(.white)
                                        }
                                        Text(testnetImport.errorMessage == nil ? "Add Account" : "Retry")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .frame(maxWidth: .infinity)
                                .disabled(testnetImport.isRunning)
                            }
                            .frame(maxWidth: .infinity)

                            if testnetImport.isRunning {
                                Text(testnetImport.stage.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if let message = testnetImport.errorMessage {
                                Text(message)
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding()
                    }
                    .navigationTitle("Import Testnet Account")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(testnetImport.hasSavedAccount ? "Close" : "Cancel") {
                                guard testnetImport.close(removeSeed: removeUnsavedTestnetSeed) else { return }
                                showingTestnetWords = false
                            }
                            .disabled(testnetImport.isRunning)
                        }
                    }
                }
                .interactiveDismissDisabled(testnetImport.isRunning || testnetImport.needsSeedCleanup)
            }
        }
        .interactiveDismissDisabled(preferences.network == .testnet10 && (isImporting || testnetImport.isRunning))
        .tint(teal)
    }

    private var canImport: Bool {
        !walletName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !kpub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        engine.isReady &&
        !isImporting
    }

    @MainActor
    private func prepareTestnetWallet(restore: Bool) async {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }
        do {
            let result = try await engine.testnetHotWallet(mnemonic: restore ? recoveryWords : nil)
            if let existing = walletStore.profiles.first(where: {
                $0.network == KaspaNetwork.testnet10.rawValue && $0.kpub == result.wallet.kpub
            }) {
                if walletStore.pendingAccountDeletionIDs.contains(existing.id) {
                    errorMessage = "Account cleanup is still pending. Reopen the app before importing this account again."
                    return
                }
                if !existing.requiresTestnetVaultRecovery {
                    duplicateProfile = existing
                    return
                }
            }
            testnetImport.reset()
            didCopyTestnetWords = false
            pendingTestnetWallet = result
            isRestoringTestnetWallet = restore
            showingTestnetWords = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func finishTestnetWallet() async {
        guard let result = pendingTestnetWallet else { return }
        let completed = await testnetImport.finish(
            result: result, name: walletName, isRestoring: isRestoringTestnetWallet, walletStore: walletStore,
            saveSeed: { try TestnetSeedStore.save($0, for: $1) },
            removeSeed: removeUnsavedTestnetSeed,
            reassociateVaults: { protectedVaultStore.reassociateVaults(to: $0) },
            recoverLegacyVaults: { profile in
                _ = try await protectedVaultStore.recoverLegacyOrphanedVaults(
                    to: profile, knownProfileIDs: Set(walletStore.profiles.map(\.id)), engine: engine
                )
            }
        )
        guard completed else { return }
        showingTestnetWords = false
    }

    private func removeUnsavedTestnetSeed(_ profileID: UUID) throws {
        try TestnetSeedStore.remove(for: profileID)
        try TestnetSeedStore.verifyAbsent(for: profileID)
    }

    private func clearTestnetImportDraft() {
        let savedID = testnetImport.savedProfileID
        let saved = savedID != nil
        pendingTestnetWallet = nil
        recoveryWords = ""
        didCopyTestnetWords = false
        testnetImport.reset()
        isRestoringTestnetWallet = false
        if saved {
            if let profile = walletStore.selectedProfile, profile.id == savedID,
               profile.requiresInitialDiscovery || profile.requiresInitialHistorySync {
                Task { @MainActor in
                    await syncService.refresh(profile: profile, walletStore: walletStore, engine: engine,
                        preferences: preferences, force: false, includeTransactionHistory: true,
                        addressDiscoveryPolicy: profile.requiresInitialDiscovery ? .comprehensive : .lightweight)
                    guard !Task.isCancelled, walletStore.selectedProfileID == profile.id else { return }
                    syncService.completeTransactionHistoryReconciliation(profileID: profile.id, walletStore: walletStore)
                }
            }
            dismiss()
        }
    }

    @MainActor
    private func processKpubScan(_ scannedValue: String) async {
        let value = scannedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value != lastScannedFrame,
              !isProcessingScan
        else { return }

        lastScannedFrame = value
        isProcessingScan = true
        defer { isProcessingScan = false }

        do {
            if value.hasPrefix("KSBIN:") {
                let frameHex = String(value.dropFirst("KSBIN:".count))
                guard !frameHex.isEmpty,
                      frameHex.count.isMultiple(of: 2),
                      frameHex.allSatisfy({ $0.isHexDigit })
                else { throw KpubQRPayloadError.invalidHex }

                if let completedHex = try await engine.decodeQRFrame(frameHex) {
                    let canonicalKpub = try KpubQRPayload.canonicalKpub(
                        from: completedHex
                    )
                    let imported = try await engine.importKpub(canonicalKpub)
                    kpub = imported.kpub
                    errorMessage = nil
                    scannerFeedback = .accepted
                    try? await engine.resetQRDecoder()
                    isShowingScanner = false
                    return
                }

                let progress = try await engine.decoderProgress()
                scannerFeedback = .accepted
                scannerProgressText = "\(progress.count) of \(progress.total) frames received"
            } else {
                guard value.hasPrefix("kpub") else {
                    throw KpubQRPayloadError.invalidKpub
                }
                let imported = try await engine.importKpub(value)
                kpub = imported.kpub
                errorMessage = nil
                scannerFeedback = .accepted
                isShowingScanner = false
            }
        } catch {
            scannerFeedback = .rejected
            scannerProgressText = error.localizedDescription
            lastScannedFrame = ""
            try? await engine.resetQRDecoder()
        }
    }

    private func resetKpubScanner() {
        scannerFeedback = .idle
        scannerProgressText = nil
        lastScannedFrame = ""
        isProcessingScan = false
        Task { try? await engine.resetQRDecoder() }
    }

    private func importWallet() {
        isImporting = true
        errorMessage = nil
        discoveryPresentation.start()

        let cleanedName = walletName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedKpub = kpub.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                let imported = try await engine.importKpub(cleanedKpub)

                if let existingProfile = walletStore.profiles.first(where: {
                    $0.network == "mainnet" && $0.kpub == imported.kpub
                }) {
                    discoveryPresentation.cancel()
                    duplicateProfile = existingProfile
                    isImporting = false
                    return
                }

                walletStore.beginPendingImport(
                    WalletProfile(
                        name: cleanedName,
                        kpub: imported.kpub,
                        receiveAddresses: imported.receiveAddresses,
                        changeAddresses: imported.changeAddresses,
                        requiresInitialDiscovery: true,
                        requiresInitialHistorySync: true
                    )
                )
                dismiss()
            } catch {
                discoveryPresentation.cancel()
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }
}
