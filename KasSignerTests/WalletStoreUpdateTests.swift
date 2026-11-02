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

