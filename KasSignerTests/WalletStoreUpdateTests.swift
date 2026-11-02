import Foundation
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
        coins.activate(profileID: profile.id)
        coins.setLabel("UTXO label", for: output)
        coins.setLabel("Transaction label", forTransactionID: output.txID)
        coins.setKYCStatus(.nonKYC, for: output)
        let preferences = makePreferences()
        preferences.migrateExistingWallets([profile])
        preferences.activate(profile)
        preferences.utxoCardDefault = .kyc
        let restored = UTXOCoinControlStore(protectedStorage: storage, defaults: defaults)
        restored.activate(profileID: profile.id)
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
        coins.activate(profileID: main.id)
        coins.applyDefaultKYCStatus(to: [], defaultStatus: preferences.utxoCardDefault.badgeStatus)
        coins.applyDefaultKYCStatus(to: [existing], defaultStatus: preferences.utxoCardDefault.badgeStatus)
        XCTAssertNil(coins.kycStatus(for: existing))
        coins.setKYCStatus(.nonKYC, for: existing)
        preferences.utxoCardDefault = .kyc
        coins.applyDefaultKYCStatus(to: [existing, incoming], defaultStatus: preferences.utxoCardDefault.badgeStatus)
        XCTAssertEqual(coins.kycStatus(for: existing), .nonKYC)
        XCTAssertEqual(coins.kycStatus(for: incoming), .kyc)
        preferences.activate(test)
        coins.activate(profileID: test.id)
        coins.applyDefaultKYCStatus(to: [], defaultStatus: preferences.utxoCardDefault.badgeStatus)
        coins.applyDefaultKYCStatus(to: [existing, incoming], defaultStatus: preferences.utxoCardDefault.badgeStatus)
        XCTAssertNil(coins.kycStatus(for: existing))
        XCTAssertNil(coins.kycStatus(for: incoming))
        coins.activate(profileID: main.id)
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

