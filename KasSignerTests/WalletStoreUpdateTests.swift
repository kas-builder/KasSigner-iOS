import Foundation
import XCTest
@testable import KasSigner

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
