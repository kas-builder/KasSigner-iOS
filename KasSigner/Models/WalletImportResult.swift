import Foundation
import Combine
import Security

struct WalletImportResult: Codable, Equatable {
    let kpub: String
    let receiveAddresses: [String]
    let changeAddresses: [String]

    enum CodingKeys: String, CodingKey {
        case kpub
        case receiveAddresses = "receive_addresses"
        case changeAddresses = "change_addresses"
    }
}

struct TestnetHotWalletImportResult: Decodable {
    let mnemonic: String
    let wallet: WalletImportResult
}

@MainActor
final class TestnetAccountImportCoordinator: ObservableObject {
    enum Stage: Equatable {
        case idle, savingAccount, restoringVaults, checkingOlderVaults, complete

        var title: String {
            switch self {
            case .idle: ""
            case .savingAccount: "Saving account…"
            case .restoringVaults: "Restoring vault records…"
            case .checkingOlderVaults: "Checking older vault records…"
            case .complete: "Account added"
            }
        }
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var savedProfileID: UUID?
    private var candidate: WalletProfile?
    private var candidateSeedStored = false

    var hasSavedAccount: Bool { savedProfileID != nil }
    var needsSeedCleanup: Bool { candidateSeedStored }

    func finish(
        result: TestnetHotWalletImportResult,
        name: String,
        isRestoring: Bool = false,
        walletStore: WalletStore,
        saveSeed: (String, UUID) throws -> Void,
        removeSeed: (UUID) throws -> Void,
        reassociateVaults: (WalletProfile) -> Bool,
        recoverLegacyVaults: (WalletProfile) async throws -> Void
    ) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        errorMessage = nil
        savedProfileID = nil
        stage = .savingAccount
        defer { isRunning = false }
        await Task.yield()

        let profile: WalletProfile
        if let existing = walletStore.profiles.first(where: {
            $0.network == KaspaNetwork.testnet10.rawValue && $0.kpub == result.wallet.kpub
        }) {
            guard !walletStore.pendingAccountDeletionIDs.contains(existing.id) else {
                return fail("Account cleanup is still pending. Reopen the app before importing this account again.")
            }
            if candidateSeedStored, let candidate {
                if candidate.id != existing.id {
                    do { try removeSeed(candidate.id) }
                    catch { return fail("An account already exists, but the unsaved attempt could not be cleaned up. Retry or cancel: \(error.localizedDescription)") }
                }
                candidateSeedStored = false
            }
            var resumed = existing
            if isRestoring, existing.requiresTestnetVaultRecovery || existing.requiresInitialDiscovery {
                resumed.requiresInitialDiscovery = existing.requiresInitialDiscovery || existing.lastHistoricalDiscoveryAt == nil
                resumed.requiresInitialHistorySync = true
                guard walletStore.update(resumed) else {
                    savedProfileID = existing.id
                    return fail("The account was saved, but its discovery state could not be saved. Check device storage and retry.")
                }
            }
            profile = resumed
            savedProfileID = existing.id
            walletStore.selectedProfileID = existing.id
            if !existing.requiresTestnetVaultRecovery {
                stage = .complete
                return true
            }
        } else {
            if candidate == nil {
                candidate = WalletProfile(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    kpub: result.wallet.kpub, network: KaspaNetwork.testnet10.rawValue,
                    receiveAddresses: result.wallet.receiveAddresses,
                    changeAddresses: result.wallet.changeAddresses,
                    requiresInitialDiscovery: isRestoring,
                    requiresInitialHistorySync: isRestoring,
                    requiresTestnetVaultRecovery: true
                )
            }
            guard let proposed = candidate, proposed.kpub == result.wallet.kpub else {
                return fail("Cancel this import before choosing another account.")
            }
            if !candidateSeedStored {
                do {
                    try saveSeed(result.mnemonic, proposed.id)
                    candidateSeedStored = true
                } catch {
                    return fail("The account was not saved. Could not securely store the recovery words: \(error.localizedDescription)")
                }
            }
            guard walletStore.add(proposed) else {
                do {
                    try removeSeed(proposed.id)
                    candidateSeedStored = false
                    return fail("The account was not saved. Check device storage and retry.")
                } catch {
                    return fail("The account was not saved, and its recovery words could not be cleared from secure storage. Retry or cancel to try cleanup again: \(error.localizedDescription)")
                }
            }
            candidateSeedStored = false // The seed now belongs to the saved account.
            savedProfileID = proposed.id
            profile = proposed
        }

        stage = .restoringVaults
        await Task.yield()
        guard reassociateVaults(profile) else {
            return fail("The account was saved, but its vault records could not be restored. Retry, or close to keep the saved account.")
        }
        stage = .checkingOlderVaults
        do {
            try await recoverLegacyVaults(profile)
        } catch {
            return fail("The account was saved, but older vault records could not be checked. Retry, or close to keep the saved account: \(error.localizedDescription)")
        }
        guard var completed = walletStore.profiles.first(where: { $0.id == profile.id }),
              !walletStore.pendingAccountDeletionIDs.contains(profile.id) else {
            return fail("The account is no longer available. Close this import and check the account list.")
        }
        completed.requiresTestnetVaultRecovery = false
        guard walletStore.update(completed, completingTestnetVaultRecovery: true) else {
            return fail("The account was saved, but its recovery completion could not be saved. Check device storage and retry.")
        }
        stage = .complete
        return true
    }

    /// Before save, cancellation cleans up any seed left by a failed account
    /// write. After save, closing keeps the account and its recovery checkpoint.
    func close(removeSeed: (UUID) throws -> Void) -> Bool {
        guard !isRunning else { return false }
        if needsSeedCleanup, let candidate {
            do {
                try removeSeed(candidate.id)
                candidateSeedStored = false
            } catch {
                return fail("The unsaved account's recovery words could not be cleared. Check device storage and retry cancellation: \(error.localizedDescription)")
            }
        }
        return true
    }

    func reset() {
        guard !isRunning, !needsSeedCleanup else { return }
        candidate = nil
        candidateSeedStored = false
        savedProfileID = nil
        stage = .idle
        errorMessage = nil
    }

    private func fail(_ message: String) -> Bool {
        errorMessage = message
        stage = .idle
        return false
    }
}

enum TestnetSeedStore {
    private static let service = "org.kassigner.testnet10.seed.v1"

    static func save(_ mnemonic: String, for profileID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        let data = Data(mnemonic.utf8)
        let status: OSStatus
        if existing == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load(for profileID: UUID) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let mnemonic = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return mnemonic
    }

    static func remove(for profileID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func verifyAbsent(for profileID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
