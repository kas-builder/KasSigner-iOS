import Foundation
import Combine
import SwiftUI
import XCTest
@testable import KasSigner

final class WalletStableIdentityTests: XCTestCase {
    func testReimportAndDiscoveryKeepIdentityOnBothNetworks() throws {
        for network in ["mainnet", "testnet-10"] {
            let original = WalletProfile(name: "Original", kpub: "kpub-identity-test", network: network)
            var reimported = WalletProfile(name: "Renamed", kpub: original.kpub, network: network,
                                           importedAt: .distantPast,
                                           receiveAddresses: ["receive"], changeAddresses: ["change"],
                                           nextReceiveIndex: 4, nextChangeIndex: 7)
            reimported.requiresInitialDiscovery = true
            reimported.requiresInitialHistorySync = true
            XCTAssertNotEqual(original.id, reimported.id)
            XCTAssertEqual(original.stableIdentity, reimported.stableIdentity)
            let restored = try JSONDecoder().decode(WalletProfile.self, from: JSONEncoder().encode(reimported))
            XCTAssertEqual(original.stableIdentity, restored.stableIdentity)
        }
    }

    func testDifferentWalletsAndNetworksHaveSeparateIdentities() {
        let mainnet = WalletProfile(name: "Same name", kpub: "kpub-identity-test")
        let testnet = WalletProfile(name: mainnet.name, kpub: mainnet.kpub, network: "testnet-10")
        let other = WalletProfile(name: mainnet.name, kpub: "kpub-other")
        let differentCase = WalletProfile(name: mainnet.name, kpub: "KPUB-identity-test")
        XCTAssertEqual(Set([mainnet, testnet, other, differentCase].map(\.stableIdentity)).count, 4)
    }

    func testIdentityPreservesExistingVaultFingerprintEncoding() {
        let profile = WalletProfile(name: "Wallet", kpub: "kpub-identity-test")
        XCTAssertEqual(profile.stableIdentity,
                       "49ddd103273c4aae1ddaa420778cbf1ae74bd4af74cee8d31801f520f9019e44")
        let uppercaseNetwork = WalletProfile(name: "Wallet", kpub: profile.kpub, network: "MAINNET")
        XCTAssertEqual(profile.stableIdentity, uppercaseNetwork.stableIdentity)
    }
}

final class WalletStoreUpdateTests: XCTestCase {
    @MainActor
    func testUpdateRestoresInMemoryProfileWhenProtectedSaveFails() throws {
        let invalidDirectory = FileManager.default.temporaryDirectory
            .appending(path: "WalletUpdateFailure-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: invalidDirectory)

        let suiteName = "WalletUpdateFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: invalidDirectory)
        }
        let original = WalletProfile(name: "Original", kpub: "kpub-update-failure")
        defaults.set(
            try JSONEncoder().encode([original]),
            forKey: "kassigner.walletProfiles.v1"
        )
        defaults.set(
            original.id.uuidString,
            forKey: "kassigner.selectedWalletProfile.v1"
        )

        let store = WalletStore(
            protectedStorage: ProtectedWalletStorage(directoryURL: invalidDirectory),
            defaults: defaults
        )
        var updated = original
        updated.earliestFreshReceiveIndex = 3

        XCTAssertFalse(store.update(updated))
        XCTAssertEqual(store.profiles.first, original)
        XCTAssertEqual(store.selectedProfile, original)
    }

    @MainActor
    func testUpdateRetainsProfileWhenProtectedSaveSucceeds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WalletUpdateSuccess-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suiteName = "WalletUpdateSuccess.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = WalletStore(
            protectedStorage: ProtectedWalletStorage(directoryURL: directory),
            defaults: defaults
        )
        let original = WalletProfile(name: "Original", kpub: "kpub-update-success")
        XCTAssertTrue(store.add(original))

        var updated = original
        updated.earliestFreshReceiveIndex = 2

        XCTAssertTrue(store.update(updated))
        XCTAssertEqual(store.profiles.first, updated)
    }
}

@MainActor
final class WalletPreferencesPersistenceTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appending(path: "WalletPreferences-\(UUID().uuidString)")
        suite = "WalletPreferences.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    private func makePreferences() -> AppPreferences {
        AppPreferences(defaults: defaults, storage: ProtectedWalletStorage(directoryURL: root))
    }

    private func assertDefaults(_ value: AppPreferences, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value.appearanceTheme, .dark, file: file, line: line)
        XCTAssertEqual(value.kasBalanceDecimalPlaces, .three, file: file, line: line)
        XCTAssertEqual(value.addressStatusDisplayMode, .iconAndText, file: file, line: line)
        XCTAssertEqual(value.utxoCardDefault, .off, file: file, line: line)
        XCTAssertTrue(value.showsGraphColors, file: file, line: line)
        XCTAssertEqual(value.explorer, .kaspaStream, file: file, line: line)
        XCTAssertEqual(value.secondaryCurrency, .usd, file: file, line: line)
        XCTAssertEqual(value.priceProvider, .automatic, file: file, line: line)
        XCTAssertFalse(value.showsCurrencyConverterInWallet, file: file, line: line)
        XCTAssertTrue(value.opensToFreshAddress, file: file, line: line)
        XCTAssertTrue(value.hideAppSwitcherPreview, file: file, line: line)
    }

    func testFirstImportsReceiveDefaultsAndGlobalDefaultsRemainShared() {
        let value = makePreferences()
        value.migrateExistingWallets([])
        for network in ["mainnet", "testnet-10"] {
            value.activate(WalletProfile(name: network, kpub: "kpub-one", network: network))
            assertDefaults(value)
        }
        XCTAssertEqual(value.network, .mainnet)
        XCTAssertEqual(value.nodeMode, .automatic)
        XCTAssertEqual(value.customNodeURL, "")
        let security = AppLockService(defaults: defaults)
        XCTAssertFalse(security.isEnabled)
        XCTAssertEqual(security.lockDelay, .immediately)
    }

    func testEveryWalletPreferenceSurvivesSwitchRelaunchAndReimportOnBothNetworks() {
        for network in ["mainnet", "testnet-10"] {
            let first = WalletProfile(name: "First", kpub: "kpub-first", network: network)
            let other = WalletProfile(name: "Other", kpub: "kpub-other", network: network)
            let value = makePreferences()
            value.migrateExistingWallets([])
            value.activate(first)
            value.appearanceTheme = .light
            value.kasBalanceDecimalPlaces = .one
            value.addressStatusDisplayMode = .iconOnly
            value.utxoCardDefault = .nonKYC
            value.showsGraphColors = false
            value.explorer = .kaspaExplorer
            value.secondaryCurrency = .btc
            value.priceProvider = .coinPaprika
            value.showsCurrencyConverterInWallet = true
            value.opensToFreshAddress = false
            value.hideAppSwitcherPreview = false
            value.activate(other)
            assertDefaults(value)
            value.utxoCardDefault = .kyc
            value.activate(nil) // Simulates account removal without erasing its preferences.
            let reloaded = makePreferences()
            let reimport = WalletProfile(name: "Renamed", kpub: first.kpub, network: network)
            reloaded.activate(reimport)
            XCTAssertEqual(reloaded.appearanceTheme, .light)
            XCTAssertEqual(reloaded.kasBalanceDecimalPlaces, .one)
            XCTAssertEqual(reloaded.addressStatusDisplayMode, .iconOnly)
            XCTAssertEqual(reloaded.utxoCardDefault, .nonKYC)
            XCTAssertFalse(reloaded.showsGraphColors)
            XCTAssertEqual(reloaded.explorer, .kaspaExplorer)
            XCTAssertEqual(reloaded.secondaryCurrency, .btc)
            XCTAssertEqual(reloaded.priceProvider, .coinPaprika)
            XCTAssertTrue(reloaded.showsCurrencyConverterInWallet)
            XCTAssertFalse(reloaded.opensToFreshAddress)
            XCTAssertFalse(reloaded.hideAppSwitcherPreview)
            XCTAssertEqual(reloaded.savedWallets.first { $0.id == first.stableIdentity }?.name, "Renamed")
            reloaded.activate(other)
            XCTAssertEqual(reloaded.utxoCardDefault, .kyc)
            XCTAssertNil(reloaded.persistenceAlert)
        }
    }

    func testSameKpubOnDifferentNetworksDoesNotShareSettings() {
        let value = makePreferences()
        value.migrateExistingWallets([])
        let main = WalletProfile(name: "Main", kpub: "same")
        let test = WalletProfile(name: "Test", kpub: "same", network: "testnet-10")
        value.activate(main)
        value.utxoCardDefault = .kyc
        value.activate(test)
        assertDefaults(value)
        value.network = .testnet10
        value.nodeMode = .custom
        value.customNodeURL = "wss://example.invalid"
        XCTAssertEqual(value.activeNodeMode, .automatic)
        XCTAssertEqual(value.activeCustomNodeURL, "")
        value.activate(main)
        XCTAssertEqual(value.utxoCardDefault, .kyc)
        let reloaded = makePreferences()
        XCTAssertEqual(reloaded.network, .testnet10)
        XCTAssertEqual(reloaded.nodeMode, .custom)
        XCTAssertEqual(reloaded.customNodeURL, "wss://example.invalid")
    }

    func testMigrationPreservesLegacyChoicesOnlyForExistingWallets() {
        defaults.set("light", forKey: "kassigner.appearanceTheme.v1")
        defaults.set(2, forKey: "kassigner.kasBalanceDecimalPlaces.v1")
        defaults.set(false, forKey: "kassigner.addressStatusEnabled.v1")
        defaults.set("kyc", forKey: "kassigner.utxoCardDefault.v1")
        defaults.set(false, forKey: "kassigner.receive.openToFreshAddress.v1")
        let profiles = [WalletProfile(name: "Main", kpub: "main"),
                        WalletProfile(name: "Test", kpub: "test", network: "testnet-10")]
        let value = makePreferences()
        value.migrateExistingWallets(profiles)
        for profile in profiles {
            value.activate(profile)
            XCTAssertEqual(value.appearanceTheme, .light)
            XCTAssertEqual(value.kasBalanceDecimalPlaces, .two)
            XCTAssertEqual(value.addressStatusDisplayMode, .off)
            XCTAssertEqual(value.utxoCardDefault, .kyc)
            XCTAssertFalse(value.opensToFreshAddress)
        }
        value.appearanceTheme = .dark
        let reloaded = makePreferences()
        reloaded.migrateExistingWallets(profiles)
        reloaded.activate(profiles[1])
        XCTAssertEqual(reloaded.appearanceTheme, .dark)
        reloaded.activate(WalletProfile(name: "New", kpub: "new"))
        assertDefaults(reloaded)
    }

    func testForgetResetsNextImportWithoutErasingOtherWallet() {
        let value = makePreferences()
        value.migrateExistingWallets([])
        let first = WalletProfile(name: "First", kpub: "first")
        let other = WalletProfile(name: "Other", kpub: "other")
        value.activate(first)
        value.utxoCardDefault = .kyc
        value.activate(other)
        value.appearanceTheme = .light
        XCTAssertTrue(value.forgetSavedSettings(identity: first.stableIdentity))
        XCTAssertEqual(value.appearanceTheme, .light)
        let reloaded = makePreferences()
        reloaded.activate(WalletProfile(name: "Reimport", kpub: first.kpub))
        assertDefaults(reloaded)
        reloaded.activate(other)
        XCTAssertEqual(reloaded.appearanceTheme, .light)
    }

    func testUnreadableRecordsAreNotOverwritten() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "wallet-preferences-v1.json")
        let bytes = Data("invalid JSON".utf8)
        try bytes.write(to: file)
        let value = makePreferences()
        XCTAssertNotNil(value.persistenceAlert)
        value.migrateExistingWallets([])
        value.activate(WalletProfile(name: "Wallet", kpub: "one"))
        value.utxoCardDefault = .kyc
        XCTAssertFalse(value.forgetSavedSettings(identity: "anything"))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testPreviewPrivacyMigrationPreservesOldRecordsAndAppWideAuthentication() throws {
        defaults.set(false, forKey: "kassigner.security.hideAppSwitcherPreview")
        defaults.set(true, forKey: "kassigner.security.appLockEnabled")
        defaults.set("fiveMinutes", forKey: "kassigner.security.lockDelay")
        let first = WalletProfile(name: "First", kpub: "first")
        let second = WalletProfile(name: "Second", kpub: "second", network: "testnet-10")
        let original = makePreferences()
        original.migrateExistingWallets([first, second])
        let file = root.appending(path: "wallet-preferences-v1.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var wallets = try XCTUnwrap(json["wallets"] as? [String: [String: Any]])
        for id in wallets.keys {
            var record = try XCTUnwrap(wallets[id])
            var settings = try XCTUnwrap(record["preferences"] as? [String: Any])
            settings.removeValue(forKey: "hideAppSwitcherPreview")
            record["preferences"] = settings
            wallets[id] = record
        }
        json["wallets"] = wallets
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let value = makePreferences()
        XCTAssertNil(value.persistenceAlert)
        value.activate(first)
        XCTAssertFalse(value.hideAppSwitcherPreview)
        value.hideAppSwitcherPreview = true
        value.activate(second)
        XCTAssertFalse(value.hideAppSwitcherPreview)
        let reloaded = makePreferences()
        reloaded.activate(first)
        XCTAssertTrue(reloaded.hideAppSwitcherPreview)
        reloaded.activate(second)
        XCTAssertFalse(reloaded.hideAppSwitcherPreview)
        reloaded.activate(WalletProfile(name: "New", kpub: "new"))
        XCTAssertTrue(reloaded.hideAppSwitcherPreview)
        let security = AppLockService(defaults: defaults)
        XCTAssertTrue(security.isEnabled)
        XCTAssertEqual(security.lockDelay, .fiveMinutes)
    }

    func testMigrationLeavesExistingLabelsAndBadgesUntouched() {
        let profile = WalletProfile(name: "Existing", kpub: "existing")
        let storage = ProtectedWalletStorage(directoryURL: root)
        let output = WalletUTXO(txID: "saved", index: 2, amount: 1, scriptPublicKey: [], blockDAAScore: 1, covenantID: nil)
        let coins = UTXOCoinControlStore(protectedStorage: storage, defaults: defaults)
        coins.activate(profile: profile)
        coins.setLabel("UTXO label", for: output)
        coins.setLabel("Transaction label", forTransactionID: output.txID)
        coins.setKYCStatus(.nonKYC, for: output)
        let preferences = makePreferences()
        preferences.migrateExistingWallets([profile])
        preferences.activate(profile)
        preferences.utxoCardDefault = .kyc
        let restored = UTXOCoinControlStore(protectedStorage: storage, defaults: defaults)
        restored.activate(profile: profile)
        XCTAssertEqual(restored.label(for: output), "UTXO label")
        XCTAssertEqual(restored.label(forTransactionID: output.txID), "Transaction label")
        XCTAssertEqual(restored.kycStatus(for: output), .nonKYC)
    }

    func testKYCDefaultsStayLocalAndDoNotReplaceExistingBadges() {
        let preferences = makePreferences()
        preferences.migrateExistingWallets([])
        let main = WalletProfile(name: "Main", kpub: "same")
        let test = WalletProfile(name: "Test", kpub: "same", network: "testnet-10")
        let coins = UTXOCoinControlStore(protectedStorage: ProtectedWalletStorage(directoryURL: root), defaults: defaults)
        let existing = WalletUTXO(txID: "existing", index: 0, amount: 1, scriptPublicKey: [], blockDAAScore: 1, covenantID: nil)
        let incoming = WalletUTXO(txID: "incoming", index: 0, amount: 1, scriptPublicKey: [], blockDAAScore: 2, covenantID: nil)
        preferences.activate(main)
        coins.activate(profile: main)
        coins.applyDefaultKYCStatus(to: [], defaultStatus: preferences.utxoCardDefault.badgeStatus)
        coins.applyDefaultKYCStatus(to: [existing], defaultStatus: preferences.utxoCardDefault.badgeStatus)
        XCTAssertNil(coins.kycStatus(for: existing))
        coins.setKYCStatus(.nonKYC, for: existing)
        preferences.utxoCardDefault = .kyc
        coins.applyDefaultKYCStatus(to: [existing, incoming], defaultStatus: preferences.utxoCardDefault.badgeStatus)
        XCTAssertEqual(coins.kycStatus(for: existing), .nonKYC)
        XCTAssertEqual(coins.kycStatus(for: incoming), .kyc)
        preferences.activate(test)
        coins.activate(profile: test)
        coins.applyDefaultKYCStatus(to: [], defaultStatus: preferences.utxoCardDefault.badgeStatus)
        coins.applyDefaultKYCStatus(to: [existing, incoming], defaultStatus: preferences.utxoCardDefault.badgeStatus)
        XCTAssertNil(coins.kycStatus(for: existing))
        XCTAssertNil(coins.kycStatus(for: incoming))
        coins.activate(profile: main)
        XCTAssertEqual(coins.kycStatus(for: existing), .nonKYC)
        XCTAssertEqual(coins.kycStatus(for: incoming), .kyc)
    }

    func testFailedSaveRollsBackAndKeepsPreviousRecord() throws {
        let value = makePreferences()
        value.migrateExistingWallets([])
        let profile = WalletProfile(name: "Wallet", kpub: "one")
        value.activate(profile)
        value.utxoCardDefault = .nonKYC
        let backup = root.appending(path: "saved-record.json")
        let file = root.appending(path: "wallet-preferences-v1.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        value.utxoCardDefault = .kyc
        XCTAssertEqual(value.utxoCardDefault, .nonKYC)
        XCTAssertNotNil(value.persistenceAlert)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        let reloaded = makePreferences()
        reloaded.activate(profile)
        XCTAssertEqual(reloaded.utxoCardDefault, .nonKYC)
    }
}

@MainActor
final class InitialDiscoveryRetryTests: XCTestCase {
    func testManualRetryReachesDiscoveryDespiteOfflineMonitorAndClearsOldError() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DiscoveryRetry-\(UUID().uuidString)")
        let suite = "DiscoveryRetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let storage = ProtectedWalletStorage(directoryURL: root)
        let wallet = WalletStore(protectedStorage: storage, defaults: defaults,
                                 transactionCacheDirectoryURL: root.appending(path: "history"))
        let preferences = AppPreferences(defaults: defaults, storage: storage)
        // This configuration rejects initial discovery before any engine/network
        // work. Reaching that validation proves retry passed the offline gate.
        preferences.nodeMode = .custom
        let engine = KasSignerEngine()
        let sync = WalletSyncService(defaults: defaults, networkAvailability: { false })
        let profile = WalletProfile(name: "Pending", kpub: "retry-test",
                                    requiresInitialDiscovery: true, requiresInitialHistorySync: true)
        wallet.beginPendingImport(profile)
        await sync.refresh(profile: profile, walletStore: wallet, engine: engine,
                           preferences: preferences, force: true, includeTransactionHistory: false,
                           addressDiscoveryPolicy: .comprehensive)
        XCTAssertEqual(sync.initialDiscoveryError,
                       "Connect to the internet and retry discovery. The wallet has not been opened.")
        var errors: [String?] = []
        var states: [WalletSyncService.State] = []
        let errorSubscription = sync.$initialDiscoveryError.sink { errors.append($0) }
        let stateSubscription = sync.$state.sink { states.append($0) }
        defer {
            errorSubscription.cancel()
            stateSubscription.cancel()
        }
        await sync.refresh(profile: profile, walletStore: wallet, engine: engine,
                           preferences: preferences, force: true, retryInitialDiscoveryWhenOffline: true,
                           includeTransactionHistory: false, addressDiscoveryPolicy: .comprehensive)
        XCTAssertEqual(sync.state, .failed("Complete discovery requires Automatic Nodes."))
        XCTAssertTrue(sync.initialDiscoveryError?.contains("select Automatic Nodes") == true)
        XCTAssertTrue(errors.contains(where: { $0 == nil }))
        XCTAssertTrue(states.contains(.syncing))
        XCTAssertNotNil(wallet.pendingImportedProfile)
        XCTAssertTrue(wallet.profiles.isEmpty)
        XCTAssertNil(sync.snapshot)

        // The exception is scoped to this explicit retry, not future refreshes.
        await sync.refresh(profile: profile, walletStore: wallet, engine: engine,
                           preferences: preferences, force: true, includeTransactionHistory: false)
        XCTAssertEqual(sync.state, .failed("No internet connection."))

        // A completed account cannot use the initial-import exception.
        let completed = WalletProfile(name: "Existing", kpub: "existing")
        await sync.refresh(profile: completed, walletStore: wallet, engine: engine,
                           preferences: preferences, force: true, retryInitialDiscoveryWhenOffline: true,
                           includeTransactionHistory: false)
        XCTAssertEqual(sync.state, .failed("No internet connection."))
    }
}

@MainActor
final class WalletCardMetadataPersistenceTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appending(path: "CardMetadata-\(UUID().uuidString)")
        suite = "CardMetadata.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    private var storage: ProtectedWalletStorage { ProtectedWalletStorage(directoryURL: root) }
    private func makeStore() -> UTXOCoinControlStore {
        UTXOCoinControlStore(protectedStorage: storage, defaults: defaults)
    }
    private func utxo(_ id: String = "transaction", index: UInt32 = 0) -> WalletUTXO {
        WalletUTXO(txID: id, index: index, amount: 100_000_000, scriptPublicKey: [], blockDAAScore: 1, covenantID: nil)
    }
    private func metadataFile(_ profile: WalletProfile) -> URL {
        root.appending(path: "wallet-card-metadata-\(profile.stableIdentity).json")
    }

    func testLatestLabelsAndBadgesSurviveActualRemovalAndReimportOnBothNetworks() throws {
        let coins = makeStore()
        let wallet = WalletStore(protectedStorage: storage, defaults: defaults,
                                 transactionCacheDirectoryURL: root.appending(path: "history"),
                                 removeTestnetSeed: { _ in })
        let output = utxo()
        for network in ["mainnet", "testnet-10"] {
            let profile = WalletProfile(name: "Original", kpub: "same-kpub", network: network)
            XCTAssertTrue(wallet.add(profile))
            coins.activate(profile: profile)
            coins.setLabel("Old UTXO", for: output)
            coins.setLabel("Latest UTXO", for: output)
            coins.setLabel("Old transaction", forTransactionID: output.txID)
            coins.setLabel("Latest transaction", forTransactionID: output.txID)
            coins.setKYCStatus(.kyc, for: output)
            coins.setKYCStatus(.nonKYC, for: output)
            XCTAssertTrue(coins.toggle(output))
            XCTAssertTrue(coins.prepareForRemoval(profile))
            XCTAssertEqual(wallet.deleteAccount(profileID: profile.id) { id in
                coins.removeProfileSession(profileID: id)
            }, .deleted)
            XCTAssertTrue(coins.selectedOutpoints.isEmpty)
            XCTAssertNil(wallet.selectedProfile)
            let reimport = WalletProfile(name: "Renamed", kpub: profile.kpub, network: network)
            XCTAssertNotEqual(profile.id, reimport.id)
            XCTAssertTrue(wallet.add(reimport))
            let restarted = makeStore()
            restarted.activate(profile: reimport)
            XCTAssertEqual(restarted.label(for: output), "Latest UTXO")
            XCTAssertEqual(restarted.label(forTransactionID: output.txID), "Latest transaction")
            XCTAssertEqual(restarted.kycStatus(for: output), .nonKYC)
            XCTAssertTrue(restarted.selectedOutpoints.isEmpty)
            XCTAssertNil(restarted.persistenceAlert)
            XCTAssertEqual(wallet.deleteAccount(profileID: reimport.id), .deleted)
        }
    }

    func testDifferentWalletsNetworksAndOutputIndexesStaySeparate() {
        let coins = makeStore()
        let main = WalletProfile(name: "Same name", kpub: "same")
        let test = WalletProfile(name: "Same name", kpub: "same", network: "testnet-10")
        let other = WalletProfile(name: "Same name", kpub: "other")
        let first = utxo(index: 0)
        let second = utxo(index: 1)
        coins.activate(profile: main)
        coins.setLabel("First output", for: first)
        coins.setLabel("Second output", for: second)
        coins.setLabel("Transaction", forTransactionID: first.txID)
        coins.setKYCStatus(.kyc, for: first)
        coins.setKYCStatus(.nonKYC, for: second)
        for profile in [test, other] {
            coins.activate(profile: profile)
            XCTAssertEqual(coins.label(for: first), "")
            XCTAssertEqual(coins.label(forTransactionID: first.txID), "")
            XCTAssertNil(coins.kycStatus(for: first))
        }
        coins.activate(profile: main)
        XCTAssertEqual(coins.label(for: first), "First output")
        XCTAssertEqual(coins.label(for: second), "Second output")
        XCTAssertEqual(coins.kycStatus(for: second), .nonKYC)
    }

    func testProtectedLegacyMigrationAndClearsDoNotResurrectOlderValues() throws {
        let profile = WalletProfile(name: "Legacy", kpub: "legacy")
        let output = utxo("ABCD")
        let suffix = profile.id.uuidString.lowercased()
        XCTAssertTrue(storage.save(["ABCD:0": "Legacy UTXO", "transaction:abcd": "Legacy transaction"],
                                   fileName: "utxo-labels-\(suffix).json"))
        XCTAssertTrue(storage.save(["ABCD:0": UTXOKYCStatus.kyc], fileName: "utxo-kyc-statuses-\(suffix).json"))
        XCTAssertTrue(storage.save(Set(["ABCD:0"]), fileName: "utxo-known-ids-\(suffix).json"))
        let coins = makeStore()
        coins.migrateExistingWallets([profile])
        coins.activate(profile: profile)
        XCTAssertEqual(coins.label(for: output), "Legacy UTXO")
        XCTAssertEqual(coins.label(forTransactionID: " ABCD "), "Legacy transaction")
        XCTAssertEqual(coins.kycStatus(for: output), .kyc)
        coins.setLabel(" ", for: output)
        coins.setLabel("", forTransactionID: output.txID)
        coins.setKYCStatus(nil, for: output)
        for restoredProfile in [profile, WalletProfile(name: "Reimport", kpub: profile.kpub)] {
            let restored = makeStore()
            restored.activate(profile: restoredProfile)
            restored.applyDefaultKYCStatus(to: [output, utxo("new")], defaultStatus: .kyc)
            XCTAssertEqual(restored.label(for: output), "")
            XCTAssertEqual(restored.label(forTransactionID: output.txID), "")
            XCTAssertNil(restored.kycStatus(for: output))
            XCTAssertEqual(restored.kycStatus(for: utxo("new")), .kyc)
            XCTAssertNil(restored.persistenceAlert)
        }
    }

    func testUserDefaultsLegacyMigrationPreservesLabelsAndBadges() throws {
        let profile = WalletProfile(name: "Legacy", kpub: "defaults", network: "testnet-10")
        let output = utxo()
        defaults.set(try JSONEncoder().encode([output.id: "UTXO", "transaction:transaction": "Transaction"]),
                     forKey: "kassigner.utxoLabels.v1." + profile.id.uuidString)
        defaults.set(try JSONEncoder().encode([output.id: UTXOKYCStatus.nonKYC]),
                     forKey: "kassigner.utxoKYCStatuses.v1." + profile.id.uuidString)
        defaults.set(try JSONEncoder().encode(Set([output.id])),
                     forKey: "kassigner.knownUTXOs.v1." + profile.id.uuidString)
        let coins = makeStore()
        XCTAssertTrue(coins.prepareForRemoval(profile)) // Includes an unopened wallet.
        XCTAssertNil(defaults.data(forKey: "kassigner.utxoLabels.v1." + profile.id.uuidString))
        XCTAssertNil(defaults.data(forKey: "kassigner.utxoKYCStatuses.v1." + profile.id.uuidString))
        XCTAssertNil(defaults.data(forKey: "kassigner.knownUTXOs.v1." + profile.id.uuidString))
        coins.removeProfileSession(profileID: profile.id)
        coins.activate(profile: WalletProfile(name: "New name", kpub: profile.kpub, network: profile.network))
        XCTAssertEqual(coins.label(for: output), "UTXO")
        XCTAssertEqual(coins.label(forTransactionID: output.txID), "Transaction")
        XCTAssertEqual(coins.kycStatus(for: output), .nonKYC)
    }

    func testUnreadableStableMetadataBlocksEditsAndRemovalWithoutOverwriting() throws {
        let profile = WalletProfile(name: "Broken", kpub: "broken")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data("invalid JSON".utf8)
        try bytes.write(to: metadataFile(profile))
        let coins = makeStore()
        coins.activate(profile: profile)
        coins.setLabel("Overwrite", for: utxo())
        coins.setKYCStatus(.kyc, for: utxo())
        XCTAssertFalse(coins.prepareForRemoval(profile))
        XCTAssertEqual(coins.label(for: utxo()), "")
        XCTAssertNil(coins.kycStatus(for: utxo()))
        XCTAssertNotNil(coins.persistenceAlert)
        XCTAssertEqual(try Data(contentsOf: metadataFile(profile)), bytes)
    }

    func testCorruptLegacyComponentDoesNotPartiallyMigrateOrEraseLabels() throws {
        let profile = WalletProfile(name: "Broken", kpub: "legacy-broken")
        let suffix = profile.id.uuidString.lowercased()
        XCTAssertTrue(storage.save([utxo().id: "Keep me"], fileName: "utxo-labels-\(suffix).json"))
        let badgeFile = root.appending(path: "utxo-kyc-statuses-\(suffix).json")
        try Data("invalid".utf8).write(to: badgeFile)
        let coins = makeStore()
        XCTAssertFalse(coins.prepareForRemoval(profile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataFile(profile).path))
        let original: [String: String]? = storage.load([String: String].self, fileName: "utxo-labels-\(suffix).json")
        XCTAssertEqual(original?[utxo().id], "Keep me")
    }

    func testFailedSavesKeepPriorLabelsBadgesAndKnownOutputState() throws {
        let profile = WalletProfile(name: "Wallet", kpub: "save-failure")
        let coins = makeStore()
        let output = utxo()
        coins.activate(profile: profile)
        coins.applyDefaultKYCStatus(to: [], defaultStatus: .kyc)
        coins.setLabel("Original", for: output)
        coins.setLabel("Original transaction", forTransactionID: output.txID)
        coins.setKYCStatus(.nonKYC, for: output)
        let file = metadataFile(profile)
        let backup = root.appending(path: "backup.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        coins.setLabel("New", for: output)
        coins.setLabel("New transaction", forTransactionID: output.txID)
        coins.setKYCStatus(.kyc, for: output)
        coins.applyDefaultKYCStatus(to: [output, utxo("incoming")], defaultStatus: .kyc)
        XCTAssertEqual(coins.label(for: output), "Original")
        XCTAssertEqual(coins.label(forTransactionID: output.txID), "Original transaction")
        XCTAssertEqual(coins.kycStatus(for: output), .nonKYC)
        XCTAssertNil(coins.kycStatus(for: utxo("incoming")))
        XCTAssertNotNil(coins.persistenceAlert)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        let restored = makeStore()
        restored.activate(profile: WalletProfile(name: "Reimport", kpub: profile.kpub))
        restored.applyDefaultKYCStatus(to: [output, utxo("incoming")], defaultStatus: .kyc)
        XCTAssertEqual(restored.label(for: output), "Original")
        XCTAssertEqual(restored.kycStatus(for: output), .nonKYC)
        XCTAssertEqual(restored.kycStatus(for: utxo("incoming")), .kyc)
    }
}

@MainActor
final class SendLabelPersistenceTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var storage: ProtectedWalletStorage { ProtectedWalletStorage(directoryURL: root) }

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appending(path: "SendLabels-\(UUID().uuidString)")
        suite = "SendLabels.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    private func profile(_ network: String = "mainnet") -> WalletProfile {
        WalletProfile(name: "Wallet", kpub: "send-labels", network: network,
                      receiveAddresses: ["owned-receive"], changeAddresses: ["owned-change", "owned-change-2"])
    }
    private func output(_ address: String?, amount: UInt64 = 100) -> PSKTSummaryOutput {
        PSKTSummaryOutput(address: address, amountSompi: amount)
    }
    private func change(_ address: String = "owned-change", amount: UInt64 = 100, index: Int = 0) -> PlannedChangeOutput {
        PlannedChangeOutput(addressIndex: index, address: address, amountSompi: amount)
    }
    private func utxo(_ id: String, _ index: UInt32 = 0) -> WalletUTXO {
        WalletUTXO(txID: id, index: index, amount: 100, scriptPublicKey: [], blockDAAScore: 1, covenantID: nil)
    }
    private func makeStore() -> UTXOCoinControlStore {
        UTXOCoinControlStore(protectedStorage: storage, defaults: defaults)
    }

    func testAllCheckboxCombinationsPersistOnlySelectedCardsOnBothNetworks() throws {
        for network in ["mainnet", "testnet-10"] {
            let wallet = profile(network)
            let coins = makeStore()
            coins.activate(profile: wallet)
            coins.setLabel("Input stays", for: utxo("input"))
            coins.setKYCStatus(.nonKYC, for: utxo("input"))
            for transactionCard in [false, true] {
                for utxoCard in [false, true] {
                    let id = "tx-\(transactionCard)-\(utxoCard)"
                    let draft = SendLabelDraft(text: "  Payment label  ", includeInTransactionCard: transactionCard,
                                              includeInChangeUTXOCards: utxoCard)
                    let assignment = BroadcastLabelAssignment.make(profile: wallet, draft: draft,
                        changeOutputs: [change()], outputs: [output("owned-change"), output("external"), output("owned-receive"), output(nil)])
                    XCTAssertTrue(coins.saveBroadcastLabels(assignment, transactionID: " \(id.uppercased()) "))
                    coins.removeProfileSession(profileID: wallet.id)
                    let restored = makeStore()
                    restored.activate(profile: WalletProfile(name: "Reimport", kpub: wallet.kpub, network: network))
                    XCTAssertEqual(restored.label(forTransactionID: id), transactionCard ? "Payment label" : "")
                    XCTAssertEqual(restored.label(for: utxo(id, 0)), utxoCard ? "Payment label" : "")
                    XCTAssertEqual(restored.label(for: utxo(id, 2)), "")
                    XCTAssertEqual(restored.label(for: utxo(id, 1)), "")
                    XCTAssertEqual(restored.label(for: utxo(id, 3)), "")
                    XCTAssertEqual(restored.label(for: utxo("input")), "Input stays")
                    XCTAssertEqual(restored.kycStatus(for: utxo("input")), .nonKYC)
                }
            }
        }
    }

    func testDraftCreationBlankLabelsAndUncheckedBoxesDoNotWriteOrEraseExistingLabels() throws {
        let wallet = profile()
        let coins = makeStore()
        coins.activate(profile: wallet)
        coins.setLabel("Keep transaction", forTransactionID: "broadcast")
        coins.setLabel("Keep UTXO", for: utxo("broadcast"))
        let file = root.appending(path: "wallet-card-metadata-\(wallet.stableIdentity).json")
        let before = try Data(contentsOf: file)
        let unusedDraft = BroadcastLabelAssignment.make(profile: wallet,
            draft: SendLabelDraft(text: "Draft only", includeInTransactionCard: true, includeInChangeUTXOCards: true),
            changeOutputs: [change()], outputs: [output("owned-change")])
        XCTAssertNotNil(unusedDraft)
        XCTAssertEqual(try Data(contentsOf: file), before) // Not saved before broadcast.
        for draft in [SendLabelDraft(), SendLabelDraft(text: "Unchecked", includeInTransactionCard: false),
                      SendLabelDraft(text: " \n ", includeInTransactionCard: true, includeInChangeUTXOCards: true)] {
            let assignment = BroadcastLabelAssignment.make(profile: wallet, draft: draft, changeOutputs: [change()], outputs: [output("owned-change")])
            XCTAssertNil(assignment)
            XCTAssertTrue(coins.saveBroadcastLabels(assignment, transactionID: "broadcast"))
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }

    func testActualOutputIndexesMatchOnlyVerifiedChangeIncludingMultipleAddresses() throws {
        let wallet = profile()
        let draft = SendLabelDraft(text: "Change label", includeInTransactionCard: false, includeInChangeUTXOCards: true)
        let plan = [change(), change("owned-change-2", amount: 200, index: 1)]
        let original = try XCTUnwrap(BroadcastLabelAssignment.make(profile: wallet, draft: draft,
            changeOutputs: plan,
            outputs: [output("owned-change"), output("external"), output("owned-receive"),
                      output("owned-change-2", amount: 200), output("owned-change", amount: 999)]))
        XCTAssertEqual(original.changeOutputIndices, [0, 3])
        let signedOrder = try XCTUnwrap(BroadcastLabelAssignment.make(profile: wallet, draft: draft,
            changeOutputs: plan,
            outputs: [output("external"), output(" OWNED-RECEIVE "), output("owned-change-2", amount: 200),
                      output(" OWNED-CHANGE "), output("owned-change", amount: 999)]))
        XCTAssertEqual(signedOrder.changeOutputIndices, [2, 3])
        let coins = makeStore()
        coins.activate(profile: wallet)
        XCTAssertTrue(coins.saveBroadcastLabels(signedOrder, transactionID: "broadcast"))
        XCTAssertEqual(coins.label(for: utxo("broadcast", 2)), "Change label")
        XCTAssertEqual(coins.label(for: utxo("broadcast", 3)), "Change label")
        XCTAssertEqual(coins.label(for: utxo("broadcast", 1)), "")
        XCTAssertEqual(coins.label(for: utxo("broadcast", 4)), "")
        XCTAssertEqual(coins.label(forTransactionID: "broadcast"), "")
    }

    func testNoChangeIgnoresStaleCheckboxAndStillLabelsTransactionByDefault() throws {
        let wallet = profile()
        let draft = SendLabelDraft(text: "Send Max", includeInChangeUTXOCards: true)
        // Even a payment to a known change address is not a change output when
        // the verified change plan is empty, as with Send Max.
        let assignment = try XCTUnwrap(BroadcastLabelAssignment.make(profile: wallet, draft: draft,
            changeOutputs: [], outputs: [output("owned-change")]))
        XCTAssertTrue(assignment.draft.includeInTransactionCard)
        XCTAssertFalse(assignment.draft.includeInChangeUTXOCards)
        XCTAssertTrue(assignment.changeOutputIndices.isEmpty)
        let coins = makeStore()
        coins.activate(profile: wallet)
        XCTAssertTrue(coins.saveBroadcastLabels(assignment, transactionID: "send-max"))
        XCTAssertEqual(coins.label(forTransactionID: "send-max"), "Send Max")
        XCTAssertEqual(coins.label(for: utxo("send-max")), "")
        let changeOnly = SendLabelDraft(text: "Unused", includeInTransactionCard: false, includeInChangeUTXOCards: true)
        XCTAssertNil(BroadcastLabelAssignment.make(profile: wallet, draft: changeOnly,
                                                  changeOutputs: [], outputs: [output("external")]))
    }

    func testBroadcastSaveTargetsOriginatingWalletAfterSelectionChangesOrRemoval() throws {
        let origin = profile()
        let current = profile("testnet-10") // Same kpub, different network.
        let assignment = try XCTUnwrap(BroadcastLabelAssignment.make(profile: origin,
            draft: SendLabelDraft(text: "Origin label", includeInTransactionCard: true, includeInChangeUTXOCards: true),
            changeOutputs: [change()], outputs: [output("owned-change")]))
        let coins = makeStore()
        coins.activate(profile: origin)
        coins.removeProfileSession(profileID: origin.id)
        coins.activate(profile: current)
        coins.setLabel("Current wallet", forTransactionID: "broadcast")
        XCTAssertTrue(coins.saveBroadcastLabels(assignment, transactionID: "broadcast"))
        XCTAssertEqual(coins.label(forTransactionID: "broadcast"), "Current wallet")
        XCTAssertEqual(coins.label(for: utxo("broadcast")), "")
        let restored = makeStore()
        restored.activate(profile: WalletProfile(name: "Reimport", kpub: origin.kpub))
        XCTAssertEqual(restored.label(forTransactionID: "broadcast"), "Origin label")
        XCTAssertEqual(restored.label(for: utxo("broadcast")), "Origin label")
    }

    func testSaveFailurePreservesExistingLabelsAndReportsBroadcastSucceeded() throws {
        let wallet = profile()
        let coins = makeStore()
        coins.activate(profile: wallet)
        coins.setLabel("Previous transaction", forTransactionID: "broadcast")
        coins.setLabel("Previous output", for: utxo("broadcast"))
        let assignment = try XCTUnwrap(BroadcastLabelAssignment.make(profile: wallet,
            draft: SendLabelDraft(text: "Replacement", includeInTransactionCard: true, includeInChangeUTXOCards: true),
            changeOutputs: [change()], outputs: [output("owned-change")]))
        let file = root.appending(path: "wallet-card-metadata-\(wallet.stableIdentity).json")
        let bytes = try Data(contentsOf: file)
        let backup = root.appending(path: "backup.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertFalse(coins.saveBroadcastLabels(assignment, transactionID: "broadcast"))
        XCTAssertEqual(coins.label(forTransactionID: "broadcast"), "Previous transaction")
        XCTAssertEqual(coins.label(for: utxo("broadcast")), "Previous output")
        XCTAssertTrue(coins.persistenceAlert?.contains("transaction was broadcast") == true)
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
    }

    func testSendSessionKeepsLabelChoicesInMemoryAndNewSessionsUseAgreedDefaults() throws {
        let wallet = WalletStore(protectedStorage: storage, defaults: defaults,
                                 transactionCacheDirectoryURL: root.appending(path: "history"))
        let profile = profile()
        XCTAssertTrue(wallet.add(profile))
        var session = try XCTUnwrap(wallet.beginSendSession(profileID: profile.id, selectedUTXOs: [utxo("input")]))
        XCTAssertEqual(session.labelDraft, SendLabelDraft())
        XCTAssertTrue(session.labelDraft.includeInTransactionCard)
        XCTAssertFalse(session.labelDraft.includeInChangeUTXOCards)
        let draft = SendLabelDraft(text: "Session label", includeInTransactionCard: true, includeInChangeUTXOCards: true)
        session.labelDraft = draft
        wallet.updateSendSession(session)
        XCTAssertEqual(wallet.sendSession(id: session.id, profileID: profile.id)?.labelDraft, draft)
        wallet.cancelSendSession(id: session.id, profileID: profile.id)
        let fresh = try XCTUnwrap(wallet.beginSendSession(profileID: profile.id, selectedUTXOs: [utxo("input")]))
        XCTAssertEqual(fresh.labelDraft, SendLabelDraft())
        XCTAssertTrue(fresh.labelDraft.includeInTransactionCard)
        XCTAssertFalse(fresh.labelDraft.includeInChangeUTXOCards)
        let restarted = WalletStore(protectedStorage: storage, defaults: defaults,
                                    transactionCacheDirectoryURL: root.appending(path: "history"))
        XCTAssertTrue(restarted.sendSessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            root.appending(path: "wallet-card-metadata-\(profile.stableIdentity).json").path))
    }
}

@MainActor
final class TestnetAccountImportCoordinatorTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var storage: ProtectedWalletStorage { ProtectedWalletStorage(directoryURL: root.appending(path: "accounts")) }
    private var result: TestnetHotWalletImportResult {
        TestnetHotWalletImportResult(mnemonic: "synthetic import fixture", wallet:
            WalletImportResult(kpub: "testnet-import-fixture", receiveAddresses: ["receive"], changeAddresses: ["change"]))
    }
    private var failure: NSError { NSError(domain: "ImportFixture", code: 1) }

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appending(path: "TestnetImport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "TestnetImport.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }
    private func makeWallet() -> WalletStore {
        let wallet = WalletStore(protectedStorage: storage, defaults: defaults,
                                 transactionCacheDirectoryURL: root.appending(path: "history"), removeTestnetSeed: { _ in })
        wallet.activateNetwork(.testnet10)
        return wallet
    }

    func testSuccessfulImportPublishesProgressAndSavesExactlyOneAccountAndSeed() async throws {
        let wallet = makeWallet()
        let coordinator = TestnetAccountImportCoordinator()
        var stages: [TestnetAccountImportCoordinator.Stage] = []
        let subscription = coordinator.$stage.sink { stages.append($0) }
        defer { subscription.cancel() }
        var seedIDs: [UUID] = []
        var recovered: [UUID] = []
        let success = await coordinator.finish(result: result, name: "Imported", walletStore: wallet,
            saveSeed: { _, id in seedIDs.append(id) }, removeSeed: { _ in XCTFail("Saved seed must be retained") },
            reassociateVaults: { _ in true }, recoverLegacyVaults: { recovered.append($0.id) })
        XCTAssertTrue(success)
        let profile = try XCTUnwrap(wallet.profiles.first)
        XCTAssertEqual(wallet.profiles.count, 1)
        XCTAssertEqual(seedIDs, [profile.id])
        XCTAssertEqual(recovered, [profile.id])
        XCTAssertFalse(profile.requiresTestnetVaultRecovery)
        XCTAssertFalse(profile.requiresInitialDiscovery)
        XCTAssertFalse(profile.requiresInitialHistorySync)
        XCTAssertEqual(profile.network, "testnet-10")
        XCTAssertEqual(coordinator.savedProfileID, profile.id)
        XCTAssertTrue(stages.contains(.savingAccount))
        XCTAssertTrue(stages.contains(.restoringVaults))
        XCTAssertTrue(stages.contains(.checkingOlderVaults))
        XCTAssertEqual(coordinator.stage, .complete)
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertTrue(coordinator.close(removeSeed: { _ in XCTFail("Close keeps saved account") }))
        coordinator.reset()
        XCTAssertEqual(wallet.profiles.count, 1)
    }

    func testRetryAfterReassociationFailureReusesAccountAndSeed() async throws {
        let wallet = makeWallet()
        let coordinator = TestnetAccountImportCoordinator()
        var seeds: [UUID] = []
        let first = await coordinator.finish(result: result, name: "Imported", walletStore: wallet,
            saveSeed: { _, id in seeds.append(id) }, removeSeed: { _ in XCTFail() },
            reassociateVaults: { _ in false }, recoverLegacyVaults: { _ in XCTFail() })
        XCTAssertFalse(first)
        let saved = try XCTUnwrap(wallet.profiles.first)
        XCTAssertTrue(saved.requiresTestnetVaultRecovery)
        var premature = saved
        premature.requiresTestnetVaultRecovery = false
        XCTAssertTrue(wallet.update(premature))
        XCTAssertTrue(wallet.profiles[0].requiresTestnetVaultRecovery)
        XCTAssertTrue(coordinator.hasSavedAccount)
        XCTAssertTrue(coordinator.errorMessage?.contains("account was saved") == true)
        let retry = await coordinator.finish(result: result, name: "Retry name", walletStore: wallet,
            saveSeed: { _, _ in XCTFail("Must not save another seed") }, removeSeed: { _ in XCTFail() },
            reassociateVaults: { profile in XCTAssertEqual(profile.id, saved.id); return true },
            recoverLegacyVaults: { profile in XCTAssertEqual(profile.id, saved.id) })
        XCTAssertTrue(retry)
        XCTAssertEqual(seeds, [saved.id])
        XCTAssertEqual(wallet.profiles.count, 1)
        XCTAssertEqual(wallet.profiles.first?.id, saved.id)
        XCTAssertEqual(wallet.profiles.first?.name, "Imported")
        XCTAssertFalse(wallet.profiles[0].requiresTestnetVaultRecovery)
        XCTAssertTrue(wallet.update(saved)) // A late balance sync must not revive the checkpoint.
        XCTAssertFalse(wallet.profiles[0].requiresTestnetVaultRecovery)
    }

    func testLegacyRecoveryFailureCanCloseAndRetryAfterRelaunchWithoutCreatingAnotherAccount() async throws {
        let wallet = makeWallet()
        let coordinator = TestnetAccountImportCoordinator()
        let failed = await coordinator.finish(result: result, name: "Imported", walletStore: wallet,
            saveSeed: { _, _ in }, removeSeed: { _ in XCTFail() }, reassociateVaults: { _ in true },
            recoverLegacyVaults: { _ in throw self.failure })
        XCTAssertFalse(failed)
        let id = try XCTUnwrap(coordinator.savedProfileID)
        XCTAssertTrue(coordinator.errorMessage?.contains("older vault records") == true)
        XCTAssertTrue(coordinator.close(removeSeed: { _ in XCTFail("Closing a saved account must keep its seed") }))
        coordinator.reset()
        let relaunchedWallet = makeWallet()
        XCTAssertTrue(relaunchedWallet.profiles[0].requiresTestnetVaultRecovery)
        let retry = TestnetAccountImportCoordinator()
        let finished = await retry.finish(result: result, name: "Retry", walletStore: relaunchedWallet,
            saveSeed: { _, _ in XCTFail() }, removeSeed: { _ in XCTFail() }, reassociateVaults: { _ in true },
            recoverLegacyVaults: { profile in XCTAssertEqual(profile.id, id) })
        XCTAssertTrue(finished)
        XCTAssertEqual(relaunchedWallet.profiles.map(\.id), [id])
        XCTAssertFalse(relaunchedWallet.profiles[0].requiresTestnetVaultRecovery)
    }

    func testDuplicateAddedBeforeFinalSubmissionIsReusedWithoutSeedWrites() async throws {
        let wallet = makeWallet()
        let existing = WalletProfile(name: "Existing", kpub: result.wallet.kpub, network: "testnet-10")
        XCTAssertTrue(wallet.add(existing))
        let coordinator = TestnetAccountImportCoordinator()
        let finished = await coordinator.finish(result: result, name: "Duplicate", walletStore: wallet,
            saveSeed: { _, _ in XCTFail() }, removeSeed: { _ in XCTFail() },
            reassociateVaults: { _ in XCTFail(); return false }, recoverLegacyVaults: { _ in XCTFail() })
        XCTAssertTrue(finished)
        XCTAssertEqual(coordinator.savedProfileID, existing.id)
        XCTAssertEqual(wallet.profiles, [existing])
    }

    func testMainnetAccountDoesNotBlockTestnetImportWithSamePublicKey() async throws {
        let wallet = makeWallet()
        XCTAssertTrue(wallet.add(WalletProfile(name: "Main", kpub: result.wallet.kpub)))
        let coordinator = TestnetAccountImportCoordinator()
        let finished = await coordinator.finish(result: result, name: "Test", walletStore: wallet,
            saveSeed: { _, _ in }, removeSeed: { _ in XCTFail() },
            reassociateVaults: { _ in true }, recoverLegacyVaults: { _ in })
        XCTAssertTrue(finished)
        XCTAssertEqual(wallet.profiles.count, 2)
        XCTAssertEqual(Set(wallet.profiles.map(\.network)), ["mainnet", "testnet-10"])
    }

    func testSecureStorageFailureLeavesNoAccountAndRetriesSameCandidateID() async throws {
        let wallet = makeWallet()
        let coordinator = TestnetAccountImportCoordinator()
        var attemptedIDs: [UUID] = []
        let failed = await coordinator.finish(result: result, name: "Imported", walletStore: wallet,
            saveSeed: { _, id in attemptedIDs.append(id); throw self.failure }, removeSeed: { _ in XCTFail() },
            reassociateVaults: { _ in XCTFail(); return true }, recoverLegacyVaults: { _ in XCTFail() })
        XCTAssertFalse(failed)
        XCTAssertTrue(wallet.profiles.isEmpty)
        XCTAssertFalse(coordinator.hasSavedAccount)
        XCTAssertFalse(coordinator.needsSeedCleanup)
        XCTAssertTrue(coordinator.errorMessage?.contains("account was not saved") == true)
        let retried = await coordinator.finish(result: result, name: "Imported", walletStore: wallet,
            saveSeed: { _, id in attemptedIDs.append(id) }, removeSeed: { _ in XCTFail() },
            reassociateVaults: { _ in true }, recoverLegacyVaults: { _ in })
        XCTAssertTrue(retried)
        XCTAssertEqual(attemptedIDs.count, 2)
        XCTAssertEqual(attemptedIDs[0], attemptedIDs[1])
        XCTAssertEqual(wallet.profiles.count, 1)
    }

    func testFailedAccountSaveRollsBackSeedAndCancelLeavesNoAccount() async throws {
        let wallet = makeWallet()
        // Obstruct protected account storage after initialization.
        try FileManager.default.removeItem(at: storage.directoryURL)
        try Data("blocked".utf8).write(to: storage.directoryURL)
        let coordinator = TestnetAccountImportCoordinator()
        var seedID: UUID?
        var removedIDs: [UUID] = []
        let failed = await coordinator.finish(result: result, name: "Imported", walletStore: wallet,
            saveSeed: { _, id in seedID = id }, removeSeed: { removedIDs.append($0) },
            reassociateVaults: { _ in XCTFail(); return false }, recoverLegacyVaults: { _ in XCTFail() })
        XCTAssertFalse(failed)
        XCTAssertEqual(removedIDs, [try XCTUnwrap(seedID)])
        XCTAssertTrue(wallet.profiles.isEmpty)
        XCTAssertFalse(coordinator.needsSeedCleanup)
        XCTAssertTrue(coordinator.close(removeSeed: { _ in XCTFail() }))
        coordinator.reset()
        XCTAssertNil(coordinator.errorMessage)
    }

    func testCleanupFailureBlocksDiscardAndRetryDoesNotWriteAnotherSeed() async throws {
        let wallet = makeWallet()
        try FileManager.default.removeItem(at: storage.directoryURL)
        try Data("blocked".utf8).write(to: storage.directoryURL)
        let coordinator = TestnetAccountImportCoordinator()
        var writtenID: UUID?
        let failed = await coordinator.finish(result: result, name: "Imported", walletStore: wallet,
            saveSeed: { _, id in writtenID = id }, removeSeed: { _ in throw self.failure },
            reassociateVaults: { _ in true }, recoverLegacyVaults: { _ in })
        XCTAssertFalse(failed)
        XCTAssertTrue(coordinator.needsSeedCleanup)
        XCTAssertFalse(coordinator.close(removeSeed: { _ in throw self.failure }))
        coordinator.reset()
        XCTAssertTrue(coordinator.needsSeedCleanup)
        try FileManager.default.removeItem(at: storage.directoryURL)
        try FileManager.default.createDirectory(at: storage.directoryURL, withIntermediateDirectories: true)
        let retried = await coordinator.finish(result: result, name: "Imported", walletStore: wallet,
            saveSeed: { _, _ in XCTFail("Reuse the seed already stored for this candidate") }, removeSeed: { _ in XCTFail() },
            reassociateVaults: { _ in true }, recoverLegacyVaults: { _ in })
        XCTAssertTrue(retried)
        XCTAssertEqual(wallet.profiles.first?.id, writtenID)
        XCTAssertFalse(coordinator.needsSeedCleanup)
    }

    func testBusySubmissionAndDismissalCannotRunTwice() async throws {
        let wallet = makeWallet()
        let coordinator = TestnetAccountImportCoordinator()
        var gate: CheckedContinuation<Void, Never>?
        var finishedRunning = false
        let task = Task { @MainActor in
            defer { finishedRunning = true }
            return await coordinator.finish(result: self.result, name: "Imported", walletStore: wallet,
                saveSeed: { _, _ in }, removeSeed: { _ in XCTFail() }, reassociateVaults: { _ in true },
                recoverLegacyVaults: { _ in await withCheckedContinuation { gate = $0 } })
        }
        while gate == nil && !finishedRunning { await Task.yield() }
        guard let gate else {
            XCTFail("Import did not reach the expected recovery stage")
            _ = await task.value
            return
        }
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertEqual(coordinator.stage, .checkingOlderVaults)
        let repeated = await coordinator.finish(result: result, name: "Duplicate", walletStore: wallet,
            saveSeed: { _, _ in XCTFail() }, removeSeed: { _ in XCTFail() },
            reassociateVaults: { _ in XCTFail(); return true }, recoverLegacyVaults: { _ in XCTFail() })
        XCTAssertFalse(repeated)
        XCTAssertFalse(coordinator.close(removeSeed: { _ in XCTFail() }))
        coordinator.reset()
        XCTAssertTrue(coordinator.isRunning)
        gate.resume()
        let finished = await task.value
        XCTAssertTrue(finished)
        XCTAssertEqual(wallet.profiles.count, 1)
    }

    func testCompletionSaveFailureKeepsDurableRecoveryCheckpoint() async throws {
        let wallet = makeWallet()
        let coordinator = TestnetAccountImportCoordinator()
        let stateFile = storage.directoryURL.appending(path: "wallet-state.json")
        let backup = root.appending(path: "saved-state.json")
        let finished = await coordinator.finish(result: result, name: "Imported", walletStore: wallet,
            saveSeed: { _, _ in }, removeSeed: { _ in XCTFail() }, reassociateVaults: { _ in true },
            recoverLegacyVaults: { _ in
                try FileManager.default.moveItem(at: stateFile, to: backup)
                try FileManager.default.createDirectory(at: stateFile, withIntermediateDirectories: false)
            })
        XCTAssertFalse(finished)
        XCTAssertTrue(coordinator.hasSavedAccount)
        XCTAssertTrue(wallet.profiles[0].requiresTestnetVaultRecovery)
        XCTAssertTrue(coordinator.errorMessage?.contains("completion could not be saved") == true)
        try FileManager.default.removeItem(at: stateFile)
        try FileManager.default.moveItem(at: backup, to: stateFile)
        XCTAssertTrue(makeWallet().profiles[0].requiresTestnetVaultRecovery)
        let retried = await coordinator.finish(result: result, name: "Retry", walletStore: wallet,
            saveSeed: { _, _ in XCTFail() }, removeSeed: { _ in XCTFail() },
            reassociateVaults: { _ in true }, recoverLegacyVaults: { _ in })
        XCTAssertTrue(retried)
        XCTAssertEqual(wallet.profiles.count, 1)
    }

    func testOlderProfilesDecodeWithoutRecoveryCheckpoint() throws {
        let profile = WalletProfile(name: "Older", kpub: "older", network: "testnet-10")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        object.removeValue(forKey: "requiresTestnetVaultRecovery")
        let decoded = try JSONDecoder().decode(WalletProfile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.requiresTestnetVaultRecovery)
        XCTAssertEqual(decoded.stableIdentity, profile.stableIdentity)
    }
}

private final class TestnetActivityFixtureProtocol: URLProtocol {
    private static let fixtureLock = NSLock()
    private static var fixture: (@Sendable (URLRequest) throws -> (Int, Data))?
    private static var responseHeaders: @Sendable (URLRequest) -> [String: String] = { _ in [:] }

    static func install(_ handler: (@Sendable (URLRequest) throws -> (Int, Data))?,
                        headers: @escaping @Sendable (URLRequest) -> [String: String] = { _ in [:] }) {
        fixtureLock.withLock { fixture = handler; responseHeaders = headers }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (handler, headerProvider) = Self.fixtureLock.withLock { (Self.fixture, Self.responseHeaders) }
            guard let handler else { throw URLError(.badServerResponse) }
            let (status, bytes) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: headerProvider(request).merging(["Content-Type": "application/json"]) { _, json in json })!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

@MainActor
final class TestnetDiscoveryAndIndexerTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestnetActivityFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func candidates(_ network: KaspaNetwork) -> WalletImportResult {
        WalletImportResult(kpub: "discovery-fixture",
            receiveAddresses: (0..<512).map { "\(network.addressPrefix)receive-\($0)" },
            changeAddresses: (0..<512).map { "\(network.addressPrefix)change-\($0)" })
    }
    private func profile(_ network: KaspaNetwork) -> WalletProfile {
        let derived = candidates(network)
        return WalletProfile(name: "Restore", kpub: derived.kpub, network: network.rawValue,
            receiveAddresses: Array(derived.receiveAddresses.prefix(20)),
            changeAddresses: Array(derived.changeAddresses.prefix(20)), requiresInitialDiscovery: true)
    }

    func testIndexerRequestContractsKeepNetworksSeparateAndPreservePagination() throws {
        for network in KaspaNetwork.allCases {
            let address = network.addressPrefix + "address"
            let expectedHost = network == .testnet10 ? "api-tn10.kaspa.org" : "api.kaspa.org"
            let page = KaspaIndexerAPI.historyPage(address: address, network: network, before: "123456")
            XCTAssertEqual(page.url?.host, expectedHost)
            XCTAssertEqual(page.url?.path, "/addresses/\(address)/full-transactions-page")
            let query = URLComponents(url: page.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(query.contains(URLQueryItem(name: "before", value: "123456")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "limit", value: "500")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "resolve_previous_outpoints", value: "light")))
            let single = KaspaIndexerAPI.transaction(id: "ABC", network: network)
            XCTAssertEqual(single.url?.host, expectedHost)
            XCTAssertEqual(single.url?.path, "/transactions/abc")
            let batch = try KaspaIndexerAPI.transactionSearch(ids: ["ABC"], network: network)
            XCTAssertEqual(batch.url?.host, expectedHost)
            XCTAssertEqual(batch.httpMethod, "POST")
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: batch.httpBody!) as? [String: [String]])
            XCTAssertEqual(payload["transactionIds"], ["abc"])
            let activity = try KaspaIndexerAPI.activityRequests(addresses: [address], network: network)
            XCTAssertEqual(activity.first?.url?.host, expectedHost)
        }
        XCTAssertThrowsError(try Testnet10AddressActivityClient.requests(for: ["kaspa:wrong-network"]))
    }

    func testHistoricalActivityChecksAllBatchesAndIncludesSpentOnlyAddresses() async throws {
        let session = session()
        defer { session.invalidateAndCancel(); TestnetActivityFixtureProtocol.install(nil) }
        let addresses = candidates(.testnet10).receiveAddresses + candidates(.testnet10).changeAddresses
        let used: Set<String> = [addresses[301], addresses[512 + 187]]
        TestnetActivityFixtureProtocol.install { request in
            XCTAssertEqual(request.url?.host, "api-tn10.kaspa.org")
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: TestnetActivityFixtureProtocol.body(request)) as? [String: [String]])
            let batch = try XCTUnwrap(payload["addresses"])
            XCTAssertLessThanOrEqual(batch.count, 250)
            let rows = batch.map { ["address": $0, "active": used.contains($0), "lastTxBlockTime": 1] as [String: Any] }
            return (200, try JSONSerialization.data(withJSONObject: rows))
        }
        let found = try await Testnet10AddressActivityClient(session: session).activeAddresses(in: addresses)
        XCTAssertEqual(found, used)
    }

    func testIncompleteDuplicateAndServerResponsesAreRejectedInsteadOfResettingIndexes() async throws {
        let session = session()
        defer { session.invalidateAndCancel(); TestnetActivityFixtureProtocol.install(nil) }
        let addresses = ["kaspatest:first", "kaspatest:second"]
        let cases: [(Int, [[String: Any]])] = [
            (200, []), (200, [["address": addresses[0], "active": false]]),
            (200, [["address": addresses[0], "active": true], ["address": addresses[0], "active": true]]),
            (403, []), (429, []), (503, [])
        ]
        for (status, rows) in cases {
            let bytes = try JSONSerialization.data(withJSONObject: rows)
            TestnetActivityFixtureProtocol.install { _ in (status, bytes) }
            do {
                _ = try await Testnet10AddressActivityClient(session: session).activeAddresses(in: addresses)
                XCTFail("Incomplete or unavailable activity must not be treated as an unused wallet")
            } catch {
                if status != 200 { XCTAssertTrue(error.localizedDescription.contains("HTTP \(status)")) }
            }
        }
    }

    func testRestorationDiscoversHistoricalActivityBeyondInitialRangeOnBothChainsAndNetworks() async throws {
        for network in KaspaNetwork.allCases {
            let source = profile(network)
            let derived = candidates(network)
            let timestamp = Date(timeIntervalSince1970: 123456)
            var progress: [Double] = []
            let discovered = try await WalletSyncService.discoverHistoricalAddresses(profile: source,
                extendAddresses: { wallet, receive, change in
                    XCTAssertEqual(wallet.id, source.id)
                    XCTAssertEqual(receive, 492)
                    XCTAssertEqual(change, 492)
                    return derived
                }, activityLookup: { selectedNetwork, addresses in
                    XCTAssertEqual(selectedNetwork, network)
                    XCTAssertEqual(addresses.count, 1024)
                    // Historical activity remains active even if every output was spent.
                    return [derived.receiveAddresses[301], derived.changeAddresses[187]]
                }, now: timestamp, progress: { progress.append($0.fraction) })
            XCTAssertEqual(discovered.profile.nextReceiveIndex, 302)
            XCTAssertEqual(discovered.profile.nextChangeIndex, 188)
            XCTAssertEqual(discovered.profile.receiveAddresses.count, 352)
            XCTAssertEqual(discovered.profile.changeAddresses.count, 238)
            XCTAssertEqual(discovered.profile.lastHistoricalDiscoveryAt, timestamp)
            XCTAssertEqual(discovered.profile.earliestFreshReceiveIndex, 0)
            XCTAssertFalse(discovered.plan.reachedSafetyLimit)
            XCTAssertEqual(progress, [0.12, 0.42])
            XCTAssertEqual(source.receiveAddresses.count, 20)
        }
    }

    func testEmptyHistoryKeepsFreshGapAndSafetyBoundaryIsExplicit() async throws {
        let source = profile(.testnet10)
        let derived = candidates(.testnet10)
        let empty = try await WalletSyncService.discoverHistoricalAddresses(profile: source,
            extendAddresses: { _, _, _ in derived }, activityLookup: { _, _ in [] })
        XCTAssertEqual(empty.profile.receiveAddresses.count, 50)
        XCTAssertEqual(empty.profile.changeAddresses.count, 50)
        XCTAssertEqual(empty.profile.nextReceiveIndex, 0)
        let boundary = try await WalletSyncService.discoverHistoricalAddresses(profile: source,
            extendAddresses: { _, _, _ in derived }, activityLookup: { _, _ in [derived.receiveAddresses[511]] })
        XCTAssertEqual(boundary.profile.nextReceiveIndex, 512)
        XCTAssertEqual(boundary.profile.receiveAddresses.count, 512)
        XCTAssertTrue(boundary.plan.reachedSafetyLimit)
    }

    func testDiscoveryFailureCancellationAndWrongNetworkDoNotReturnAPartialProfile() async throws {
        let source = profile(.testnet10)
        let derived = candidates(.testnet10)
        for mode in 0..<3 {
            do {
                _ = try await WalletSyncService.discoverHistoricalAddresses(profile: source,
                    extendAddresses: { _, _, _ in
                        mode == 2 ? self.candidates(.mainnet) : derived
                    }, activityLookup: { _, _ in
                        if mode == 0 { throw URLError(.notConnectedToInternet) }
                        if mode == 1 { throw CancellationError() }
                        XCTFail("Wrong-network derivation must fail before HTTP activity lookup")
                        return []
                    })
                XCTFail("Discovery should not return partially validated addresses")
            } catch {}
        }
        XCTAssertEqual(source.nextReceiveIndex, 0)
        XCTAssertEqual(source.receiveAddresses.count, 20)
        XCTAssertNil(source.lastHistoricalDiscoveryAt)
    }

    func testRestoredAccountsRequireDiscoveryWhileGeneratedWalletsKeepLightweightSync() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "RestoreDiscovery-\(UUID().uuidString)")
        let suite = "RestoreDiscovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let storage = ProtectedWalletStorage(directoryURL: root)
        let wallet = WalletStore(protectedStorage: storage, defaults: defaults,
                                 transactionCacheDirectoryURL: root.appending(path: "history"), removeTestnetSeed: { _ in })
        for restoring in [false, true] {
            let derived = candidates(.testnet10)
            let result = TestnetHotWalletImportResult(mnemonic: "synthetic fixture", wallet:
                WalletImportResult(kpub: "fixture-\(restoring)", receiveAddresses: Array(derived.receiveAddresses.prefix(20)),
                                   changeAddresses: Array(derived.changeAddresses.prefix(20))))
            let coordinator = TestnetAccountImportCoordinator()
            let saved = await coordinator.finish(result: result, name: "Wallet", isRestoring: restoring, walletStore: wallet,
                saveSeed: { _, _ in }, removeSeed: { _ in XCTFail() }, reassociateVaults: { _ in true }, recoverLegacyVaults: { _ in })
            XCTAssertTrue(saved)
            let profile = try XCTUnwrap(wallet.profiles.first { $0.kpub == result.wallet.kpub })
            XCTAssertEqual(profile.requiresInitialDiscovery, restoring)
            XCTAssertEqual(profile.requiresInitialHistorySync, restoring)
        }
    }
}

private final class HistoryRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    func increment(_ key: String) -> Int {
        lock.withLock { values[key, default: 0] += 1; return values[key]! }
    }
}

@MainActor
final class TestnetFullHistoryTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestnetActivityFixtureProtocol.self]
        return URLSession(configuration: config)
    }
    private func profile(_ network: KaspaNetwork, kpub: String = "history-fixture") -> WalletProfile {
        WalletProfile(name: "Restored", kpub: kpub, network: network.rawValue,
            receiveAddresses: [network.addressPrefix + "receive"], changeAddresses: [network.addressPrefix + "change"],
            requiresInitialHistorySync: true)
    }
    private func rows(_ network: KaspaNetwork) -> [[String: Any]] {
        let receive = network.addressPrefix + "receive"
        let change = network.addressPrefix + "change"
        let outside = network.addressPrefix + "external"
        return [
            ["transaction_id": "incoming", "block_time": 1000, "is_accepted": true,
             "accepting_block_blue_score": 42, "accepting_block_time": 1000,
             "inputs": [["previous_outpoint_hash": "outside", "previous_outpoint_index": 0,
                         "previous_outpoint_address": outside, "previous_outpoint_amount": 1000]],
             "outputs": [["amount": 1000, "script_public_key_address": receive]]],
            ["transaction_id": "outgoing", "block_time": 2000, "is_accepted": true,
             "accepting_block_blue_score": 43, "accepting_block_time": 2000,
             "inputs": [["previous_outpoint_hash": "source", "previous_outpoint_index": 0,
                         "previous_outpoint_address": receive, "previous_outpoint_amount": 1000]],
             "outputs": [["amount": 600, "script_public_key_address": outside],
                         ["amount": 390, "script_public_key_address": change]]],
            ["transaction_id": "internal", "block_time": 3000, "is_accepted": true,
             "accepting_block_blue_score": 44, "accepting_block_time": 3000,
             "inputs": [["previous_outpoint_hash": "outgoing", "previous_outpoint_index": 1,
                         "previous_outpoint_address": change, "previous_outpoint_amount": 390]],
             "outputs": [["amount": 380, "script_public_key_address": receive]]]
        ]
    }
    nonisolated private static func activity(_ request: URLRequest) throws -> Data {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: TestnetActivityFixtureProtocol.body(request)) as? [String: [String]])
        return try JSONSerialization.data(withJSONObject: (object["addresses"] ?? []).map {
            ["address": $0, "active": true] as [String: Any]
        })
    }

    func testPagedHistoryMapsIncomingOutgoingAndInternalTransfersOnBothNetworks() async throws {
        let session = session()
        defer { session.invalidateAndCancel(); TestnetActivityFixtureProtocol.install(nil) }
        for network in KaspaNetwork.allCases {
            let row = rows(network)
            let first = try JSONSerialization.data(withJSONObject: Array(row.prefix(2)))
            let second = try JSONSerialization.data(withJSONObject: Array(row.suffix(2)))
            let all = try JSONSerialization.data(withJSONObject: row)
            let one = try JSONSerialization.data(withJSONObject: row[0])
            let host = network == .testnet10 ? "api-tn10.kaspa.org" : "api.kaspa.org"
            TestnetActivityFixtureProtocol.install({ request in
                XCTAssertEqual(request.url?.host, host)
                let path = request.url!.path
                if path == "/addresses/active" { return (200, try Self.activity(request)) }
                if path == "/transactions/search" { return (200, all) }
                if path.hasPrefix("/transactions/") { return (200, one) }
                let before = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "before" } == true
                return (200, before ? second : first)
            }, headers: { request in
                let before = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "before" } == true
                return request.url!.path.contains("full-transactions-page") && !before ? ["X-Next-Page-Before": "123"] : [:]
            })
            let client = TransactionHistoryClient(session: session, pause: { _ in })
            let wallet = profile(network)
            let result = try await client.transactions(for: wallet)
            XCTAssertEqual(result.transactions.count, 3)
            XCTAssertEqual(result.graphs.count, 3)
            XCTAssertEqual(result.transactions.first { $0.transactionID == "outgoing" }?.amountSompi, 600)
            XCTAssertEqual(result.transactions.first { $0.transactionID == "outgoing" }?.feeSompi, 10)
            XCTAssertEqual(result.transactions.first { $0.transactionID == "internal" }?.kind, .internalTransfer)
            let single = try await client.transaction(id: "incoming", for: wallet)
            XCTAssertEqual(single?.kind, .received)
            let graph = try await client.transactionGraph(id: "incoming", for: wallet)
            XCTAssertEqual(graph?.outputs.count, 1)
            let batch = try await client.transactions(ids: ["incoming", "outgoing", "internal"], for: wallet)
            XCTAssertEqual(batch.count, 3)
            let spend = try await client.recentTransactions(for: wallet.receiveAddresses, spending: ["source:0"], profile: wallet)
            XCTAssertEqual(spend.map(\.transactionID), ["outgoing"])
        }
    }

    func testPaginationCyclesMalformedHistoryAndServerFailureNeverReturnPartialSuccess() async throws {
        let session = session()
        defer { session.invalidateAndCancel(); TestnetActivityFixtureProtocol.install(nil) }
        let data = try JSONSerialization.data(withJSONObject: rows(.testnet10))
        let malformed = try JSONSerialization.data(withJSONObject: [["transaction_id": "incomplete"]])
        for mode in 0..<3 {
            TestnetActivityFixtureProtocol.install({ request in
                if request.url!.path == "/addresses/active" { return (200, try Self.activity(request)) }
                return (mode == 2 ? 503 : 200, mode == 1 ? malformed : data)
            }, headers: { request in
                request.url!.path.contains("full-transactions-page") && mode == 0 ? ["X-Next-Page-Before": "repeated"] : [:]
            })
            do {
                _ = try await TransactionHistoryClient(session: session, pause: { _ in }).transactions(for: profile(.testnet10))
                XCTFail("Partial or malformed history must not be reported complete")
            } catch {
                if mode == 0 { XCTAssertTrue(error.localizedDescription.contains("incomplete pagination")) }
                if mode == 2 { XCTAssertTrue(error.localizedDescription.contains("HTTP 503")) }
            }
        }
    }

    func testThrottledRequestsRetryWithoutLosingTransactionsAndCancellationStopsFetching() async throws {
        let session = session()
        defer { session.invalidateAndCancel(); TestnetActivityFixtureProtocol.install(nil) }
        let data = try JSONSerialization.data(withJSONObject: rows(.testnet10))
        let counter = HistoryRequestCounter()
        TestnetActivityFixtureProtocol.install({ request in
            if counter.increment(request.url!.path) == 1 { return (429, Data()) }
            if request.url!.path == "/addresses/active" { return (200, try Self.activity(request)) }
            return (200, data)
        }, headers: { _ in ["Retry-After": "0"] })
        let client = TransactionHistoryClient(session: session, pause: { _ in })
        let result = try await client.transactions(for: profile(.testnet10))
        XCTAssertEqual(result.transactions.count, 3)
        let source = profile(.testnet10)
        let canceled = Task { @MainActor in try await client.transactions(for: source) }
        canceled.cancel()
        do { _ = try await canceled.value; XCTFail("Canceled history must not complete") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }

    func testPreviouslyImportedTestnetWalletsUpgradeOnceWithoutChangingMainnetOrNewWalletDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "HistoryUpgrade-\(UUID().uuidString)")
        let suite = "HistoryUpgrade.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let storage = ProtectedWalletStorage(directoryURL: root)
        let wallet = WalletStore(protectedStorage: storage, defaults: defaults,
                                 transactionCacheDirectoryURL: root.appending(path: "history"), removeTestnetSeed: { _ in })
        let main = WalletProfile(name: "Main", kpub: "main")
        let old = WalletProfile(name: "Test", kpub: "old-test", network: "testnet-10")
        XCTAssertTrue(wallet.add(main))
        XCTAssertTrue(wallet.add(old))
        XCTAssertTrue(wallet.prepareTestnetHistoryUpgrade())
        XCTAssertEqual(wallet.profiles.first { $0.id == main.id }, main)
        XCTAssertTrue(wallet.profiles.first { $0.id == old.id }!.requiresInitialDiscovery)
        XCTAssertTrue(wallet.profiles.first { $0.id == old.id }!.requiresInitialHistorySync)
        let fresh = WalletProfile(name: "Fresh", kpub: "fresh", network: "testnet-10")
        XCTAssertTrue(wallet.add(fresh))
        XCTAssertTrue(wallet.prepareTestnetHistoryUpgrade())
        XCTAssertEqual(wallet.profiles.first { $0.id == fresh.id }, fresh)
        let restarted = WalletStore(protectedStorage: storage, defaults: defaults,
                                    transactionCacheDirectoryURL: root.appending(path: "history"), removeTestnetSeed: { _ in })
        XCTAssertTrue(restarted.profiles.first { $0.id == old.id }!.requiresInitialHistorySync)
        XCTAssertEqual(restarted.profiles.first { $0.id == fresh.id }, fresh)
    }

    func testHistoryRestoresAfterRemovalAndMetadataSurvivesInitialSyncFailureAndRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "FullTestnetHistory-\(UUID().uuidString)")
        let suite = "FullTestnetHistory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let storage = ProtectedWalletStorage(directoryURL: root)
        let original = profile(.testnet10)
        let restored = profile(.testnet10)
        let session = session()
        defer {
            session.invalidateAndCancel()
            TestnetActivityFixtureProtocol.install(nil)
            TransactionGraphCache.shared.remove(profileID: original.id)
            TransactionGraphCache.shared.remove(profileID: restored.id)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let wallet = WalletStore(protectedStorage: storage, defaults: defaults,
            transactionCacheDirectoryURL: root.appending(path: "history"), removeTestnetSeed: { _ in })
        wallet.activateNetwork(.testnet10)
        XCTAssertTrue(wallet.add(original))
        let coins = UTXOCoinControlStore(protectedStorage: storage, defaults: defaults)
        coins.activate(profile: original)
        let output = WalletUTXO(txID: "incoming", index: 0, amount: 1000, scriptPublicKey: [], blockDAAScore: 1, covenantID: nil)
        coins.setLabel("Transaction label", forTransactionID: "incoming")
        coins.setLabel("Output label", for: output)
        coins.setKYCStatus(.nonKYC, for: output)
        XCTAssertTrue(coins.prepareForRemoval(original))
        XCTAssertEqual(wallet.deleteAccount(profileID: original.id) { coins.removeProfileSession(profileID: $0) }, .deleted)
        XCTAssertTrue(wallet.add(restored))
        XCTAssertTrue(wallet.recordBroadcastedTransaction(profileID: restored.id, transactionID: "pending",
            destination: "kaspatest:external", amountSompi: 5, feeSompi: 1, committedChangeIndices: []))
        let client = TransactionHistoryClient(session: session, pause: { _ in })
        let sync = WalletSyncService(defaults: defaults, networkAvailability: { true }, historyClient: client)
        sync.preload(profile: restored)
        TestnetActivityFixtureProtocol.install { request in
            if request.url!.path == "/addresses/active" { return (200, try Self.activity(request)) }
            return (403, Data())
        }
        await sync.runOrJoinInitialHistory(profile: restored, walletStore: wallet)
        XCTAssertTrue(wallet.profiles[0].requiresInitialHistorySync)
        XCTAssertTrue(sync.transactionHistoryError?.contains("HTTP 403") == true)
        XCTAssertTrue(wallet.transactions.contains { $0.transactionID == "pending" })
        let data = try JSONSerialization.data(withJSONObject: rows(.testnet10))
        TestnetActivityFixtureProtocol.install { request in
            if request.url!.path == "/addresses/active" { return (200, try Self.activity(request)) }
            return (200, data)
        }
        await sync.runOrJoinInitialHistory(profile: restored, walletStore: wallet)
        sync.completeTransactionHistoryReconciliation(profileID: restored.id, walletStore: wallet)
        XCTAssertFalse(wallet.profiles[0].requiresInitialHistorySync)
        XCTAssertNil(sync.transactionHistoryError)
        XCTAssertTrue(wallet.transactions.contains { $0.transactionID == "pending" })
        XCTAssertTrue(wallet.transactions.contains { $0.transactionID == "incoming" })
        let reloaded = UTXOCoinControlStore(protectedStorage: storage, defaults: defaults)
        reloaded.activate(profile: restored)
        XCTAssertEqual(reloaded.label(forTransactionID: "incoming"), "Transaction label")
        XCTAssertEqual(reloaded.label(for: output), "Output label")
        XCTAssertEqual(reloaded.kycStatus(for: output), .nonKYC)
    }
}

final class TransactionAcceptanceTests: XCTestCase {
    private func row(_ profileID: UUID, status: WalletTransactionStatus, score: UInt64? = nil,
                     local: Bool = false) -> WalletTransaction {
        WalletTransaction(profileID: profileID, transactionID: "acceptance-test", destination: "recipient",
            amountSompi: 100, feeSompi: 1, broadcastAt: .distantPast, direction: .sent,
            status: status, acceptingBlockBlueScore: score, isLocallyBroadcast: local)
    }

    func testBroadcastRemainsInternallyPendingWhileDisplayChecksConfirmations() throws {
        let id = UUID()
        XCTAssertEqual(row(id, status: .pending).confirmationPresentation(currentBlueScore: nil), .checking)
        let local = row(id, status: .pending, local: true)
        XCTAssertEqual(local.confirmationPresentation(currentBlueScore: nil), .checking)
        let decoded = try JSONDecoder().decode(WalletTransaction.self, from: JSONEncoder().encode(local))
        XCTAssertEqual(decoded.confirmationPresentation(currentBlueScore: nil), .checking)
        XCTAssertEqual(decoded.status, .pending)
        XCTAssertTrue(decoded.isLocallyBroadcast)
        XCTAssertTrue(decoded.requiresAcceptanceResolution)
        XCTAssertEqual(row(id, status: .pending, score: 100, local: true)
            .confirmationPresentation(currentBlueScore: 102), .count(2))
    }

    func testWeakResponsesCannotEraseAcceptanceOrChangeIdentity() {
        let id = UUID()
        let accepted = row(id, status: .confirmed, score: 100, local: true)
        let merged = row(id, status: .checking).preservingAcceptance(from: accepted)
        XCTAssertEqual(merged.id, accepted.id)
        XCTAssertEqual(merged.acceptingBlockBlueScore, 100)
        XCTAssertEqual(merged.confirmationPresentation(currentBlueScore: 350), .confirmed)
        let local = row(id, status: .pending, local: true)
        XCTAssertEqual(row(id, status: .checking).preservingAcceptance(from: local)
            .confirmationPresentation(currentBlueScore: nil), .checking)
    }

    @MainActor
    func testCacheWriteFailureKeepsAcceptanceVisibleAndRetryPersistsIt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "AcceptanceFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = root.appending(path: "history")
        try Data("blocked cache directory".utf8).write(to: cache)
        let storage = ProtectedWalletStorage(directoryURL: root.appending(path: "wallet"))
        let store = WalletStore(protectedStorage: storage, defaults: defaults, transactionCacheDirectoryURL: cache,
                                removeTestnetSeed: { _ in })
        let profile = WalletProfile(name: "Test", kpub: "public")
        XCTAssertTrue(store.add(profile))
        store.mergeResolvedTransactions([row(profile.id, status: .confirmed, score: 100)], profileID: profile.id)
        XCTAssertNotNil(store.transactionPersistenceErrors[profile.id])
        store.reloadCachedTransactions(profileID: profile.id)
        XCTAssertEqual(store.transactions.first?.acceptingBlockBlueScore, 100)
        try FileManager.default.removeItem(at: cache)
        store.mergeResolvedTransactions([row(profile.id, status: .checking)], profileID: profile.id)
        XCTAssertNil(store.transactionPersistenceErrors[profile.id])
        let relaunched = WalletStore(protectedStorage: storage, defaults: defaults, transactionCacheDirectoryURL: cache,
                                     removeTestnetSeed: { _ in })
        XCTAssertEqual(relaunched.transactions.first?.acceptingBlockBlueScore, 100)
    }

    @MainActor
    func testStaleHistoryCacheAndRelaunchPreserveAcceptanceOnBothNetworks() throws {
        for network in ["mainnet", "testnet-10"] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let suite = "Acceptance.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
            let storage = ProtectedWalletStorage(directoryURL: root.appending(path: "wallet"))
            let cache = root.appending(path: "history")
            let store = WalletStore(protectedStorage: storage, defaults: defaults, transactionCacheDirectoryURL: cache,
                                    removeTestnetSeed: { _ in })
            let profile = WalletProfile(name: "Test", kpub: "public", network: network)
            XCTAssertTrue(store.add(profile))
            let accepted = row(profile.id, status: .confirmed, score: 100)
            store.mergeResolvedTransactions([accepted], profileID: profile.id)
            XCTAssertTrue(store.mergeSyncedTransactions([row(profile.id, status: .checking)], profileID: profile.id))
            XCTAssertEqual(store.transactions.first?.acceptingBlockBlueScore, 100)
            let weak = row(profile.id, status: .checking)
            try JSONEncoder().encode([weak]).write(to: cache.appending(path: profile.id.uuidString.lowercased() + ".json"))
            store.reloadCachedTransactions(profileID: profile.id)
            XCTAssertEqual(store.transactions.first?.acceptingBlockBlueScore, 100)
            let relaunched = WalletStore(protectedStorage: storage, defaults: defaults, transactionCacheDirectoryURL: cache,
                                         removeTestnetSeed: { _ in })
            XCTAssertEqual(relaunched.transactions.first?.acceptingBlockBlueScore, 100)
            XCTAssertTrue(relaunched.pendingTransactions.isEmpty)
        }
    }
}

final class ConfirmationResolutionTests: XCTestCase {
    @MainActor
    func testMissingFirstEightDoNotBlockLaterTransactionsOnEitherNetwork() async throws {
        for network in [KaspaNetwork.mainnet, .testnet10] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let suite = "Resolution.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [TestnetActivityFixtureProtocol.self]
            let session = URLSession(configuration: config)
            defer {
                session.invalidateAndCancel(); TestnetActivityFixtureProtocol.install(nil)
                defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
            }
            let store = WalletStore(protectedStorage: ProtectedWalletStorage(directoryURL: root.appending(path: "wallet")),
                defaults: defaults, transactionCacheDirectoryURL: root.appending(path: "history"), removeTestnetSeed: { _ in })
            let address = network.addressPrefix + "receive"
            let profile = WalletProfile(name: "Test", kpub: "public", network: network.rawValue, receiveAddresses: [address])
            XCTAssertTrue(store.add(profile))
            store.activateNetwork(network)
            let transactions = (0..<19).map { index in
                WalletTransaction(profileID: profile.id, transactionID: String(format: "%02d", index),
                    destination: "recipient", amountSompi: 100, feeSompi: 1, broadcastAt: .distantPast,
                    direction: .received, status: .checking)
            }
            XCTAssertTrue(store.mergeSyncedTransactions(transactions, profileID: profile.id))
            let host = network == .mainnet ? "api.kaspa.org" : "api-tn10.kaspa.org"
            TestnetActivityFixtureProtocol.install { request in
                XCTAssertEqual(request.url?.host, host)
                let id = request.url!.lastPathComponent
                if Int(id)! < 8 { return (404, Data("{}".utf8)) }
                let json: [String: Any] = ["transaction_id": id, "is_accepted": true,
                    "accepting_block_blue_score": 100, "block_time": 1000,
                    "inputs": [], "outputs": [["amount": 100, "script_public_key_address": address]]]
                return (200, try JSONSerialization.data(withJSONObject: json))
            }
            let service = WalletSyncService(defaults: defaults, networkAvailability: { true },
                historyClient: TransactionHistoryClient(session: session, pause: { _ in }))
            service.preload(profile: profile)
            for _ in 0..<6 { await service.reconcilePendingTransactions(profile: profile, walletStore: store) }
            XCTAssertEqual(store.transactions.filter { $0.acceptingBlockBlueScore == 100 }.count, 11)
            XCTAssertEqual(store.pendingTransactions.count, 8)
            XCTAssertTrue(store.pendingTransactions.allSatisfy { $0.confirmationPresentation(currentBlueScore: 350) == .checking })
            let cancelled = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                await service.reconcilePendingTransactions(profile: profile, walletStore: store)
            }
            await cancelled.value
            XCTAssertEqual(store.transactions.filter { $0.acceptingBlockBlueScore == 100 }.count, 11)
        }
    }
}

@MainActor
final class AppSecurityPresentationTests: XCTestCase {
    func testPreviewAndForegroundProtectionAreIndependent() {
        for locked in [false, true] {
            for hide in [false, true] {
                for phase in [ScenePhase.active, .inactive, .background] {
                    let covered = AppLockService.shouldCoverContent(needsAuthentication: locked, hidePreview: hide, phase: phase)
                    switch phase {
                    case .active: XCTAssertEqual(covered, locked)
                    case .inactive: XCTAssertEqual(covered, locked || hide)
                    case .background: XCTAssertEqual(covered, hide)
                    @unknown default: XCTFail("Unexpected scene phase")
                    }
                }
            }
        }
    }

    func testEveryDelayProtectsReturnBeforeLifecycleCallbackAndRequiresSuccessfulAuthentication() async throws {
        for delay in AppLockService.LockDelay.allCases {
            let suite = "AppSecurity.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: "kassigner.security.appLockEnabled")
            defaults.set(delay.rawValue, forKey: "kassigner.security.lockDelay")
            var now = Date(timeIntervalSince1970: 1000)
            var succeed = false
            let service = AppLockService(defaults: defaults, now: { now }, authenticationEvaluator: { _ in succeed })
            XCTAssertTrue(service.requiresForegroundAuthentication)
            await service.unlock()
            XCTAssertTrue(service.isLocked)
            succeed = true
            await service.unlock()
            XCTAssertFalse(service.isLocked)
            service.sceneDidEnterBackground()
            if delay != .immediately {
                now += delay.interval - 1
                XCTAssertFalse(service.requiresForegroundAuthentication)
                now += 1
            }
            XCTAssertTrue(service.requiresForegroundAuthentication)
            service.sceneDidBecomeActive()
            XCTAssertTrue(service.isLocked)
            succeed = false
            await service.unlock()
            XCTAssertTrue(service.requiresForegroundAuthentication)
            succeed = true
            await service.unlock()
            XCTAssertFalse(service.requiresForegroundAuthentication)
        }
    }

    func testAuthenticationResultFromBeforeBackgroundCannotUnlockNewSession() async throws {
        let suite = "AppSecurityGeneration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "kassigner.security.appLockEnabled")
        var service: AppLockService!
        service = AppLockService(defaults: defaults, authenticationEvaluator: { _ in
            service.sceneDidEnterBackground()
            return true
        })
        await service.unlock()
        XCTAssertTrue(service.isLocked)
        XCTAssertTrue(service.requiresForegroundAuthentication)
    }
}

@MainActor
final class AccountSwitchReadinessTests: XCTestCase {
    func testFastSwitchWaitsOneSecondWithoutReadyText() async throws {
        let model = AccountSwitchPresentationModel()
        model.start()
        model.complete()
        XCTAssertEqual(model.detail, "Preparing address discovery…")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(model.isVisible)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(model.progress, 1)
        XCTAssertNotEqual(model.detail, "Account ready")
    }

    func testSlowSwitchWaitsForRealCompletionAndFailureCanFinish() async throws {
        let model = AccountSwitchPresentationModel()
        model.start()
        model.update(WalletSyncService.DiscoveryProgress(title: "Synchronizing wallet", detail: "Checking UTXOs…", fraction: 0.68))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(model.isVisible)
        XCTAssertLessThan(model.progress, 1)
        XCTAssertEqual(model.detail, "Checking UTXOs…")
        model.complete()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(model.detail, "Checking UTXOs…")
        model.start()
        model.fail("Connection failed")
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(model.isVisible)
    }
}

@MainActor
final class DiscoveryLoadingTimingTests: XCTestCase {
    func testFastDiscoveryKeepsTwoSecondMinimumAndLastDetail() async throws {
        let model = AccountDiscoveryPresentationModel()
        model.start()
        model.updateDetail("Checking historical activity…")
        model.complete()
        model.updateDetail("Account ready")
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertTrue(model.isVisible)
        XCTAssertEqual(model.detail, "Checking historical activity…")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(model.progress, 1)
        XCTAssertEqual(model.detail, "Checking historical activity…")
    }

    func testSlowDiscoveryWaitsForWorkWithoutExtraFinishingDelayAndCanCancel() async throws {
        let model = AccountDiscoveryPresentationModel()
        model.start()
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertTrue(model.isVisible)
        XCTAssertLessThan(model.progress, 1)
        model.updateDetail("Loading current UTXOs…")
        model.complete()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(model.detail, "Loading current UTXOs…")
        model.start()
        model.cancel()
        XCTAssertFalse(model.isVisible)
    }
}

@MainActor
final class FinalCompatibilityFixTests: XCTestCase {
    private func row(_ profile: UUID, amount: UInt64 = 900, score: UInt64? = 100,
                     accepted: Bool? = true, destination: String = "new recipient") -> WalletTransaction {
        WalletTransaction(profileID: profile, transactionID: "compatibility", destination: destination,
            amountSompi: amount, feeSompi: amount / 10, broadcastAt: Date(timeIntervalSince1970: Double(amount)),
            direction: .sent, status: accepted == true ? .confirmed : .checking,
            acceptingBlockBlueScore: score, isLocallyBroadcast: true, reportedAcceptance: accepted)
    }

    func testStaleCacheCannotReplaceAnyLiveDetailsButCanFillMissingAcceptance() {
        let profile = UUID()
        let live = row(profile, score: 200)
        let stale = row(profile, amount: 100, score: 100, destination: "old recipient")
        XCTAssertEqual(live.mergingCachedRecord(stale), live)
        let unresolved = row(profile, score: nil, accepted: nil)
        let filled = unresolved.mergingCachedRecord(stale)
        XCTAssertEqual(filled.amountSompi, unresolved.amountSompi)
        XCTAssertEqual(filled.destination, unresolved.destination)
        XCTAssertEqual(filled.feeSompi, unresolved.feeSompi)
        XCTAssertEqual(filled.broadcastAt, unresolved.broadcastAt)
        XCTAssertEqual(filled.acceptingBlockBlueScore, 100)
    }

    func testFailureThenStaleCacheReloadAndRelaunchKeepAllLiveFieldsOnBothNetworks() throws {
        for network in [KaspaNetwork.mainnet, .testnet10] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let suite = "CompatibilityCache.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let cache = root.appending(path: "history")
            try Data("blocked".utf8).write(to: cache)
            let storage = ProtectedWalletStorage(directoryURL: root.appending(path: "wallet"))
            let store = WalletStore(protectedStorage: storage, defaults: defaults, transactionCacheDirectoryURL: cache, removeTestnetSeed: { _ in })
            let profile = WalletProfile(name: "Test", kpub: "public", network: network.rawValue)
            XCTAssertTrue(store.add(profile))
            store.activateNetwork(network)
            let live = row(profile.id, score: 200)
            store.mergeResolvedTransactions([live], profileID: profile.id)
            XCTAssertNotNil(store.transactionPersistenceErrors[profile.id])
            try FileManager.default.removeItem(at: cache)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let stale = row(profile.id, amount: 100, destination: "old recipient")
            try JSONEncoder().encode([stale]).write(to: cache.appending(path: profile.id.uuidString.lowercased() + ".json"))
            store.reloadCachedTransactions(profileID: profile.id)
            XCTAssertEqual(store.transactions.first, live)
            XCTAssertNil(store.transactionPersistenceErrors[profile.id])
            let restarted = WalletStore(protectedStorage: storage, defaults: defaults, transactionCacheDirectoryURL: cache, removeTestnetSeed: { _ in })
            XCTAssertEqual(restarted.transactions.first, live)
            let other = WalletProfile(name: "Other", kpub: "different", network: network.rawValue)
            XCTAssertTrue(restarted.add(other))
            restarted.selectedProfileID = profile.id
            restarted.reloadCachedTransactions(profileID: profile.id)
            XCTAssertEqual(restarted.transactions.first, live)
        }
    }

    func testDelayedInvalidationCannotReplaceNewAcceptanceArrivingDuringVerification() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "CompatibilityRace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = WalletStore(protectedStorage: ProtectedWalletStorage(directoryURL: root), defaults: defaults,
                                transactionCacheDirectoryURL: root.appending(path: "history"), removeTestnetSeed: { _ in })
        let profile = WalletProfile(name: "Test", kpub: "public")
        XCTAssertTrue(store.add(profile))
        let baseline = row(profile.id)
        store.mergeResolvedTransactions([baseline], profileID: profile.id)
        let newer = row(profile.id, amount: 1000, score: 200)
        store.mergeResolvedTransactions([newer], profileID: profile.id)
        let invalidated = baseline.verifyingAcceptance(false)
        store.mergeResolvedTransactions([invalidated], profileID: profile.id,
                                        acceptanceInvalidationBaselines: ["compatibility": baseline])
        XCTAssertEqual(store.transactions.first?.acceptingBlockBlueScore, 200)
        XCTAssertEqual(store.transactions.first?.amountSompi, 1000)
    }

    func testNegativeReportNeedsVerificationAndInvalidationSurvivesStaleRecordsAndCoding() throws {
        let profile = UUID()
        let previous = row(profile)
        let negative = row(profile, score: nil, accepted: false)
        let unresolved = negative.preservingAcceptance(from: previous)
        XCTAssertEqual(unresolved.acceptingBlockBlueScore, 100)
        XCTAssertTrue(unresolved.requiresAcceptanceResolution)
        let invalidated = negative.verifyingAcceptance(false).preservingAcceptance(from: unresolved)
        XCTAssertNil(invalidated.acceptingBlockBlueScore)
        XCTAssertEqual(invalidated.confirmationPresentation(currentBlueScore: 1000), .checking)
        XCTAssertEqual(previous.preservingAcceptance(from: invalidated), invalidated)
        XCTAssertEqual(invalidated.mergingCachedRecord(previous), invalidated)
        let decoded = try JSONDecoder().decode(WalletTransaction.self, from: JSONEncoder().encode(invalidated))
        XCTAssertEqual(decoded, invalidated)
        let acceptedAgain = row(profile, score: 200).verifyingAcceptance(true, at: Date().addingTimeInterval(1))
            .preservingAcceptance(from: invalidated)
        XCTAssertEqual(acceptedAgain.confirmationPresentation(currentBlueScore: 210), .count(10))
    }

    func testFreshVerificationHandlesStaleNegativeRealNegativeErrorsAndReacceptanceOnBothNetworks() async throws {
        for network in [KaspaNetwork.mainnet, .testnet10] {
            for mode in ["stale-negative", "verified-negative", "missing", "error", "not-found", "wrong-id"] {
                let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                let suite = "CompatibilityVerification.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [TestnetActivityFixtureProtocol.self]
                let session = URLSession(configuration: config)
                defer {
                    session.invalidateAndCancel(); TestnetActivityFixtureProtocol.install(nil)
                    defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
                }
                let storage = ProtectedWalletStorage(directoryURL: root.appending(path: "wallet"))
                let cache = root.appending(path: "history")
                let store = WalletStore(protectedStorage: storage, defaults: defaults, transactionCacheDirectoryURL: cache, removeTestnetSeed: { _ in })
                let address = network.addressPrefix + "receive"
                let profile = WalletProfile(name: "Test", kpub: "public", network: network.rawValue, receiveAddresses: [address])
                XCTAssertTrue(store.add(profile)); store.activateNetwork(network)
                store.mergeResolvedTransactions([row(profile.id)], profileID: profile.id)
                XCTAssertTrue(store.mergeSyncedTransactions([row(profile.id, score: nil, accepted: false)], profileID: profile.id))
                let counter = HistoryRequestCounter()
                let host = network == .mainnet ? "api.kaspa.org" : "api-tn10.kaspa.org"
                TestnetActivityFixtureProtocol.install { request in
                    XCTAssertEqual(request.url?.host, host)
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache, no-store")
                    let attempt = counter.increment(mode)
                    if attempt > 1 && mode == "error" { return (503, Data("{}".utf8)) }
                    if attempt > 1 && mode == "not-found" { return (404, Data("{}".utf8)) }
                    let accepted: Bool? = attempt == 1 || mode == "verified-negative" ? false
                        : (mode == "missing" ? nil : true)
                    var json: [String: Any] = ["transaction_id": "compatibility", "inputs": [],
                        "outputs": [["amount": 900, "script_public_key_address": address]]]
                    if attempt > 1 && mode == "wrong-id" { json["transaction_id"] = "different-transaction" }
                    if let accepted { json["is_accepted"] = accepted }
                    if accepted == true { json["accepting_block_blue_score"] = 100 }
                    return (200, try JSONSerialization.data(withJSONObject: json))
                }
                let service = WalletSyncService(defaults: defaults, networkAvailability: { true },
                    historyClient: TransactionHistoryClient(session: session, pause: { _ in }))
                service.preload(profile: profile)
                await service.reconcilePendingTransactions(profile: profile, walletStore: store)
                let result = try XCTUnwrap(store.transactions.first)
                if mode == "verified-negative" {
                    XCTAssertNil(result.acceptingBlockBlueScore)
                    XCTAssertEqual(result.acceptanceVerification?.accepted, false)
                    let restarted = WalletStore(protectedStorage: storage, defaults: defaults, transactionCacheDirectoryURL: cache, removeTestnetSeed: { _ in })
                    restarted.activateNetwork(network)
                    XCTAssertNil(restarted.transactions.first?.acceptingBlockBlueScore)
                    TestnetActivityFixtureProtocol.install { _ in
                        let json: [String: Any] = ["transaction_id": "compatibility", "is_accepted": true,
                            "accepting_block_blue_score": 200, "inputs": [],
                            "outputs": [["amount": 900, "script_public_key_address": address]]]
                        return (200, try JSONSerialization.data(withJSONObject: json))
                    }
                    await service.reconcilePendingTransactions(profile: profile, walletStore: restarted)
                    XCTAssertEqual(restarted.transactions.first?.acceptingBlockBlueScore, 200)
                } else {
                    XCTAssertEqual(result.acceptingBlockBlueScore, 100)
                    XCTAssertEqual(result.confirmationPresentation(currentBlueScore: 1000), .confirmed)
                }
            }
        }
    }
}
