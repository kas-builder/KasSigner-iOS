import Foundation
import Combine
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
