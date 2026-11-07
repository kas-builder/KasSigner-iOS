import CryptoKit
import Foundation
import XCTest
@testable import KasSigner

final class StandardSendFeeTests: XCTestCase {
    func testFeeScalesWithOneThroughEightInputsAndActualOutputCount() throws {
        for inputs in 1...8 {
            for outputs in [1, 2, 3, 5, 8] {
                let mass = 94 + 1_118 * inputs + 412 * outputs
                XCTAssertEqual(StandardSendFee.estimate(inputCount: inputs,
                    outputScriptLengths: Array(repeating: 34, count: outputs), rate: 100), UInt64(mass * 100))
            }
        }
        // Exact node rejection from the two-input Send Max regression.
        XCTAssertEqual(StandardSendFee.estimate(inputCount: 2, outputScriptLengths: [34], rate: 100), 274_200)
        XCTAssertEqual(StandardSendFee.estimate(inputCount: 2, outputScriptLengths: [35], rate: 100), 275_300)
    }

    func testRelayFloorRateChangesAndInvalidQuotes() {
        XCTAssertEqual(StandardSendFee.estimate(inputCount: 2, outputScriptLengths: [34], rate: 0), 274_200)
        XCTAssertEqual(StandardSendFee.estimate(inputCount: 2, outputScriptLengths: [34], rate: 150), 411_300)
        XCTAssertNil(StandardSendFee.estimate(inputCount: 0, outputScriptLengths: [34], rate: 100))
        XCTAssertNil(StandardSendFee.estimate(inputCount: 2, outputScriptLengths: [34], rate: .nan))
    }

    func testDecodedTransactionIncludesStorageMassAndFeeErrorIsConcise() throws {
        let summary = PSKTSummary(totalInputSompi: 200_000_000, totalOutputSompi: 100_000,
            feeSompi: 199_900_000, inputCount: 2, outputCount: 1,
            inputs: (0..<2).map { PSKTSummaryInput(txID: "tx\($0)", index: 0,
                amountSompi: 100_000_000, scriptHex: String(repeating: "00", count: 34)) },
            outputs: [PSKTSummaryOutput(address: "destination", amountSompi: 100_000,
                scriptHex: String(repeating: "00", count: 34))])
        XCTAssertEqual(StandardSendFee.requiredFee(summary: summary, rate: 100), 998_000_000)
        XCTAssertEqual(StandardSendFee.errorMessage("Node rejected: transaction has 230000 fees which is under the required amount of 274200 for compute mass 2742"),
            "Fee too low. Required: 274200 sompi. Go back to update the transaction.")
    }
}

@MainActor
private final class IsolatedWalletStoreFixture {
    let rootURL: URL
    let suiteName: String
    let defaults: UserDefaults
    let storage: ProtectedWalletStorage
    let store: WalletStore

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "KasSignerWalletTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        suiteName = "KasSignerWalletTest.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        storage = ProtectedWalletStorage(directoryURL: rootURL)
        store = WalletStore(
            protectedStorage: storage,
            defaults: defaults,
            transactionCacheDirectoryURL: rootURL.appending(
                path: "history",
                directoryHint: .isDirectory
            ),
            removeTestnetSeed: { _ in }
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootURL)
    }
}

final class IsolatedWalletStoreFixtureTests: XCTestCase {
    @MainActor
    func testFixtureWritesOnlyToItsTemporaryStorage() throws {
        let fixture = try IsolatedWalletStoreFixture()
        defer { fixture.cleanUp() }

        XCTAssertNotEqual(
            fixture.storage.directoryURL,
            ProtectedWalletStorage.shared.directoryURL
        )
        XCTAssertNotEqual(fixture.suiteName, Bundle.main.bundleIdentifier)

        XCTAssertTrue(fixture.store.add(WalletProfile(
            name: "Isolated Fixture Test",
            kpub: "kpub-isolated-fixture-test"
        )))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.rootURL.appending(path: "wallet-state.json").path
        ))
    }
}

final class Testnet10AddressActivityClientTests: XCTestCase {
    func testBatchRequestsUseTestnet10EndpointAndChunkAt250Addresses() throws {
        let addresses = (0..<251).map { "kaspatest:address-\($0)" }
        let requests = try Testnet10AddressActivityClient.requests(for: addresses)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST"])
        XCTAssertEqual(requests.compactMap(\.url?.host), [
            "api-tn10.kaspa.org",
            "api-tn10.kaspa.org"
        ])
        XCTAssertEqual(requests.compactMap(\.url?.path), [
            "/addresses/active",
            "/addresses/active"
        ])
        let payloads = try requests.compactMap(\.httpBody).map {
            try JSONDecoder().decode(TestnetAddressActivityRequestBody.self, from: $0)
        }
        XCTAssertEqual(payloads.map { $0.addresses.count }, [250, 1])
        XCTAssertEqual(payloads[0].addresses, Array(addresses.prefix(250)))
        XCTAssertEqual(payloads[1].addresses, [addresses[250]])
    }

    func testEmptyAddressListProducesNoRequests() throws {
        XCTAssertTrue(try Testnet10AddressActivityClient.requests(for: []).isEmpty)
    }

    func testResponseParserReturnsActiveAddressesCaseInsensitively() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            ["address": "KASPATEST:USED", "active": true],
            ["address": "kaspatest:fresh", "active": false]
        ])

        XCTAssertEqual(
            try Testnet10AddressActivityClient.activeAddresses(from: data),
            ["kaspatest:used"]
        )
    }

    func testNonSuccessResponseThrows() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://api-tn10.kaspa.org/addresses/active")!,
            statusCode: 503,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!

        XCTAssertThrowsError(try Testnet10AddressActivityClient.validate(response))
    }
}

private struct TestnetAddressActivityRequestBody: Decodable {
    let addresses: [String]
}

final class ProtectedVaultFundingPlanTests: XCTestCase {
    private let profileID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    func testApprovedAddressListPersistsAndLegacyDraftsRemainReadable() throws {
        let original = ProtectedVault(
            profileID: profileID,
            amount: 1,
            approvedAddresses: ["kaspa:first", "kaspa:second"],
            delayDays: 1,
            delayHours: 0,
            delayMinutes: 0
        )
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ProtectedVault.self, from: encoded).approvedAddresses,
                       ["kaspa:first", "kaspa:second"])

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "approvedAddresses")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertEqual(try JSONDecoder().decode(ProtectedVault.self, from: legacyData).approvedAddresses,
                       ["kaspa:first"])
    }

    func testFundingSelectionSessionClearsOnlyOnceForSameProfile() {
        var session = ProtectedVaultFundingSelectionSession()

        XCTAssertTrue(session.begin(profileID: profileID))
        XCTAssertFalse(session.begin(profileID: profileID))
        XCTAssertTrue(session.begin(profileID: UUID()))
    }

    func testVaultStageKeepsCovenantOutputSpendableBesideUnsupportedDeposit() {
        let original = WalletUTXO(
            txID: String(repeating: "a", count: 64),
            index: 0,
            amount: 250_000_000,
            scriptPublicKey: [0],
            blockDAAScore: 42,
            covenantID: String(repeating: "b", count: 64)
        )
        let unsupportedDeposit = WalletUTXO(
            txID: String(repeating: "c", count: 64),
            index: 1,
            amount: 10_000_000,
            scriptPublicKey: [0],
            blockDAAScore: 43,
            covenantID: nil
        )

        let outputs = ProtectedVaultStageOutput.classify([original, unsupportedDeposit])
        let spendable = outputs.filter { $0.canCoverFee(1_000_000) }
        let unsupported = outputs.filter { !$0.isCovenantTagged }

        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(spendable.map(\.id), [original.id.lowercased()])
        XCTAssertEqual(spendable.first?.utxo, original)
        XCTAssertEqual(unsupported.map(\.id), [unsupportedDeposit.id.lowercased()])
        XCTAssertFalse(unsupported.first?.canCoverFee(1_000_000) ?? true)
    }

    func testMultipleInputsProduceRequestedFeeAndWalletChange() throws {
        let plan = try ProtectedVaultFundingPlan(
            vault: vault(amount: Decimal(string: "1.25")!),
            inputs: [
                utxo(amount: 100_000_000, index: 0),
                utxo(amount: 50_000_000, index: 1)
            ],
            feeSompi: 1_000
        )

        XCTAssertEqual(plan.depositSompi, 125_000_000)
        XCTAssertEqual(plan.feeSompi, 1_000)
        XCTAssertEqual(plan.inputTotalSompi, 150_000_000)
        XCTAssertEqual(plan.changeSompi, 24_999_000)
    }

    func testCustomFeeMustFitSelectedInputs() {
        XCTAssertThrowsError(
            try ProtectedVaultFundingPlan(
                vault: vault(amount: 1),
                inputs: [utxo(amount: 100_000_500)],
                feeSompi: 1_000
            )
        ) { error in
            XCTAssertEqual(error as? ProtectedVaultFundingPlanError, .insufficientInput)
        }
    }

    func testZeroFeeIsRejected() {
        XCTAssertThrowsError(
            try ProtectedVaultFundingPlan(
                vault: vault(amount: 1),
                inputs: [utxo(amount: 200_000_000)],
                feeSompi: 0
            )
        ) { error in
            XCTAssertEqual(error as? ProtectedVaultFundingPlanError, .invalidFee)
        }
    }

    func testSubSompiDepositIsRejected() {
        XCTAssertThrowsError(
            try ProtectedVaultFundingPlan(
                vault: vault(amount: Decimal(string: "1.000000001")!),
                inputs: [utxo(amount: 200_000_000)],
                feeSompi: 1_000
            )
        ) { error in
            XCTAssertEqual(error as? ProtectedVaultFundingPlanError, .invalidDepositAmount)
        }
    }

    func testFundingSummaryVerifiesExactInputsDepositChangeAndFee() throws {
        let inputs = [
            utxo(amount: 100_000_000, index: 0),
            utxo(amount: 50_000_000, index: 1)
        ]
        let plan = try ProtectedVaultFundingPlan(
            vault: vault(amount: Decimal(string: "1.25")!),
            inputs: inputs,
            feeSompi: 1_000
        )

        let verified = try ProtectedVaultFundingVerifier.verify(
            summary: summary(
                inputs: inputs,
                outputs: [
                    ("kaspa:vault", 125_000_000),
                    ("kaspa:change", 24_999_000)
                ],
                fee: 1_000
            ),
            plan: plan,
            vaultAddress: "kaspa:vault",
            expectedChangeAddress: "kaspa:change",
            requiresExactFee: true
        )

        XCTAssertEqual(verified.depositSompi, 125_000_000)
        XCTAssertEqual(verified.feeSompi, 1_000)
        XCTAssertEqual(verified.changeSompi, 24_999_000)
        XCTAssertEqual(verified.inputCount, 2)
    }

    func testFundingSummaryRejectsUnknownOutput() throws {
        let inputs = [utxo(amount: 150_000_000)]
        let plan = try ProtectedVaultFundingPlan(
            vault: vault(amount: 1),
            inputs: inputs,
            feeSompi: 1_000
        )

        XCTAssertThrowsError(
            try ProtectedVaultFundingVerifier.verify(
                summary: summary(
                    inputs: inputs,
                    outputs: [
                        ("kaspa:vault", 100_000_000),
                        ("kaspa:attacker", 49_999_000)
                    ],
                    fee: 1_000
                ),
                plan: plan,
                vaultAddress: "kaspa:vault",
                expectedChangeAddress: "kaspa:change",
                requiresExactFee: true
            )
        ) { error in
            XCTAssertEqual(
                error as? ProtectedVaultFundingVerificationError,
                .unknownOutput
            )
        }
    }

    func testFundingSummaryRejectsDifferentSelectedOutpoint() throws {
        let inputs = [utxo(amount: 150_000_000)]
        let plan = try ProtectedVaultFundingPlan(
            vault: vault(amount: 1),
            inputs: inputs,
            feeSompi: 1_000
        )
        let differentInput = WalletUTXO(
            txID: String(repeating: "b", count: 64),
            index: 0,
            amount: 150_000_000,
            scriptPublicKey: [0],
            blockDAAScore: 42,
            covenantID: nil
        )

        XCTAssertThrowsError(
            try ProtectedVaultFundingVerifier.verify(
                summary: summary(
                    inputs: [differentInput],
                    outputs: [
                        ("kaspa:vault", 100_000_000),
                        ("kaspa:change", 49_999_000)
                    ],
                    fee: 1_000,
                    totalInput: 150_000_000
                ),
                plan: plan,
                vaultAddress: "kaspa:vault",
                expectedChangeAddress: "kaspa:change",
                requiresExactFee: true
            )
        ) { error in
            XCTAssertEqual(
                error as? ProtectedVaultFundingVerificationError,
                .inputOutpointMismatch
            )
        }
    }

    func testSignedFundingRequiresUnchangedTransactionAndAllSignatures() throws {
        let input = utxo(amount: 150_000_000)
        let unsigned = signedSummary(input: input, signatureCount: 0, ready: false)
        let signed = signedSummary(input: input, signatureCount: 1, ready: true)

        XCTAssertNoThrow(
            try SignedProtectedVaultFundingVerifier.verify(
                unsigned: unsigned,
                signed: signed
            )
        )
    }

    func testSignedFundingRejectsMissingSignature() {
        let input = utxo(amount: 150_000_000)
        let unsigned = signedSummary(input: input, signatureCount: 0, ready: false)

        XCTAssertThrowsError(
            try SignedProtectedVaultFundingVerifier.verify(
                unsigned: unsigned,
                signed: unsigned
            )
        ) { error in
            XCTAssertEqual(
                error as? SignedProtectedVaultFundingVerificationError,
                .missingSignatures
            )
        }
    }

    func testSignedFundingRejectsChangedOutput() {
        let input = utxo(amount: 150_000_000)
        let unsigned = signedSummary(input: input, signatureCount: 0, ready: false)
        var changed = signedSummary(input: input, signatureCount: 1, ready: true)
        changed = PSKTSummary(
            totalInputSompi: changed.totalInputSompi,
            totalOutputSompi: 149_998_999,
            feeSompi: 1_001,
            inputCount: changed.inputCount,
            outputCount: changed.outputCount,
            inputs: changed.inputs,
            outputs: [PSKTSummaryOutput(
                address: "kaspa:vault",
                amountSompi: 149_998_999,
                scriptHex: "bb"
            )],
            finalizeReady: true
        )

        XCTAssertThrowsError(
            try SignedProtectedVaultFundingVerifier.verify(
                unsigned: unsigned,
                signed: changed
            )
        ) { error in
            XCTAssertEqual(
                error as? SignedProtectedVaultFundingVerificationError,
                .transactionChanged
            )
        }
    }

    private func vault(amount: Decimal) -> ProtectedVault {
        ProtectedVault(
            profileID: profileID,
            amount: amount,
            approvedAddresses: ["kaspa:test"],
            delayDays: 1,
            delayHours: 0,
            delayMinutes: 0,
            covenantIDs: []
        )
    }

    private func utxo(amount: UInt64, index: UInt32 = 0) -> WalletUTXO {
        WalletUTXO(
            txID: String(repeating: "a", count: 64),
            index: index,
            amount: amount,
            scriptPublicKey: [0],
            blockDAAScore: 42,
            covenantID: nil
        )
    }

    private func summary(
        inputs: [WalletUTXO],
        outputs: [(String, UInt64)],
        fee: UInt64,
        totalInput: UInt64? = nil
    ) -> PSKTSummary {
        let inputTotal = totalInput ?? inputs.reduce(0) { $0 + $1.amount }
        let outputTotal = outputs.reduce(0) { $0 + $1.1 }
        return PSKTSummary(
            totalInputSompi: inputTotal,
            totalOutputSompi: outputTotal,
            feeSompi: fee,
            inputCount: inputs.count,
            outputCount: outputs.count,
            inputs: inputs.map {
                PSKTSummaryInput(txID: $0.txID, index: $0.index)
            },
            outputs: outputs.map {
                PSKTSummaryOutput(
                    address: $0.0,
                    amountSompi: $0.1,
                    covenantAuthorizingInput: $0.0 == "kaspa:vault" ? 0 : nil,
                    covenantID: $0.0 == "kaspa:vault"
                        ? String(repeating: "c", count: 64)
                        : nil
                )
            },
            transactionVersion: 1
        )
    }

    private func signedSummary(
        input: WalletUTXO,
        signatureCount: Int,
        ready: Bool
    ) -> PSKTSummary {
        PSKTSummary(
            totalInputSompi: input.amount,
            totalOutputSompi: 149_999_000,
            feeSompi: 1_000,
            inputCount: 1,
            outputCount: 1,
            inputs: [PSKTSummaryInput(
                txID: input.txID,
                index: input.index,
                amountSompi: input.amount,
                scriptHex: "aa",
                signaturesPresent: signatureCount
            )],
            outputs: [PSKTSummaryOutput(
                address: "kaspa:vault",
                amountSompi: 149_999_000,
                scriptHex: "bb"
            )],
            finalizeReady: ready
        )
    }
}

@MainActor
final class ProtectedVaultRecoveryPersistenceTests: XCTestCase {
    func testRecoveryExportAndImportPreserveVaultSnapshotFieldsAndDeduplicate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "VaultRecoveryRoundTrip-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sourceSuite = "VaultRecoveryRoundTrip.Source.\(UUID().uuidString)"
        let destinationSuite = "VaultRecoveryRoundTrip.Destination.\(UUID().uuidString)"
        let sourceDefaults = try XCTUnwrap(UserDefaults(suiteName: sourceSuite))
        let destinationDefaults = try XCTUnwrap(UserDefaults(suiteName: destinationSuite))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceSuite)
            destinationDefaults.removePersistentDomain(forName: destinationSuite)
            try? FileManager.default.removeItem(at: root)
        }

        let sourceProfile = WalletProfile(name: "Source", kpub: "round-trip-same-wallet",
                                          network: KaspaNetwork.testnet10.rawValue)
        let restoredProfile = WalletProfile(name: "Restored", kpub: "round-trip-same-wallet",
                                            network: KaspaNetwork.testnet10.rawValue)
        let sourceStore = ProtectedVaultStore(
            defaults: sourceDefaults,
            protectedStorage: ProtectedWalletStorage(directoryURL: root.appending(path: "source", directoryHint: .isDirectory))
        )
        let destinationStore = ProtectedVaultStore(
            defaults: destinationDefaults,
            protectedStorage: ProtectedWalletStorage(directoryURL: root.appending(path: "destination", directoryHint: .isDirectory))
        )
        let createdAt = Date(timeIntervalSince1970: 1_800_000_100)
        let fundedAt = Date(timeIntervalSince1970: 1_800_000_200)
        let archivedAt = Date(timeIntervalSince1970: 1_800_000_300)
        let protectedVault = ProtectedVault(
            profileID: sourceProfile.id,
            name: "Archived Protected",
            amount: 42,
            approvedAddresses: ["kaspatest:destination"],
            recoveryAddress: "kaspatest:recovery",
            recoveryPath: .emergencyAnytime,
            delayDays: 2,
            delayHours: 3,
            delayMinutes: 4,
            createdAt: createdAt,
            status: .spent,
            fundingTransactionID: String(repeating: "a", count: 64),
            approvedWithdrawalTransactionID: String(repeating: "b", count: 64),
            fundedAt: fundedAt,
            lockedSompi: 0,
            fundingOutpoints: ["funding-outpoint"],
            covenantIDs: ["covenant-id"],
            archivedAt: archivedAt
        )
        let timeLockedVault = TimeLockedVaultSetupDraft(
            profileID: sourceProfile.id,
            createdAt: createdAt,
            unlockDate: Date(timeIntervalSince1970: 1_900_000_000),
            selectedUTXOIDs: ["selected-outpoint"],
            destination: "kaspatest:timelock-destination",
            amountText: "9.5",
            changeAddressIndex: 7,
            usesCustomFee: true,
            customFeeText: "0.02",
            archivedAt: archivedAt,
            step: .fundingDetails
        )
        var namedTimeLockedVault = timeLockedVault
        namedTimeLockedVault.name = "Archived Time-Locked"
        XCTAssertTrue(sourceStore.add(protectedVault))
        XCTAssertTrue(sourceStore.saveTimeLockedSetupDraft(namedTimeLockedVault))

        let document = try sourceStore.recoveryDocument(for: sourceProfile)
        let backup = try XCTUnwrap(JSONSerialization.jsonObject(with: document.data) as? [String: Any])
        let decoder = JSONDecoder()
        let exportedProtectedVaults = try decoder.decode(
            [ProtectedVault].self,
            from: JSONSerialization.data(withJSONObject: try XCTUnwrap(backup["vaults"] as? [[String: Any]]))
        )
        let exportedTimeLockedVaults = try decoder.decode(
            [TimeLockedVaultSetupDraft].self,
            from: JSONSerialization.data(withJSONObject: try XCTUnwrap(backup["timeLockedSetupDrafts"] as? [[String: Any]]))
        )
        XCTAssertEqual(exportedProtectedVaults, [protectedVault])
        XCTAssertEqual(exportedTimeLockedVaults, [namedTimeLockedVault])
        let reassociatedProtectedVault = protectedVault.reassociated(to: restoredProfile.id)
        XCTAssertEqual(reassociatedProtectedVault.profileID, restoredProfile.id)
        XCTAssertEqual(reassociatedProtectedVault.name, protectedVault.name)
        XCTAssertEqual(reassociatedProtectedVault.archivedAt, archivedAt)
        XCTAssertEqual(reassociatedProtectedVault.fundingTransactionID, protectedVault.fundingTransactionID)
        XCTAssertEqual(reassociatedProtectedVault.approvedWithdrawalTransactionID,
                       protectedVault.approvedWithdrawalTransactionID)
        XCTAssertEqual(reassociatedProtectedVault.createdAt, createdAt)
        XCTAssertEqual(reassociatedProtectedVault.fundedAt, fundedAt)

        var timeLockedOnlyBackup = backup
        timeLockedOnlyBackup["vaults"] = []
        timeLockedOnlyBackup["setupDrafts"] = []
        let timeLockedOnlyDocument = ProtectedVaultRecoveryDocument(
            data: try JSONSerialization.data(withJSONObject: timeLockedOnlyBackup)
        )

        let importedCount = try await destinationStore.restoreRecoveryDocument(
            timeLockedOnlyDocument,
            for: restoredProfile,
            engine: KasSignerEngine()
        )
        XCTAssertEqual(importedCount.totalImported, 1)
        XCTAssertEqual(importedCount.timeLockedSetupDrafts, 1)
        XCTAssertEqual(destinationStore.timeLockedSetupDrafts(for: restoredProfile.id), [namedTimeLockedVault.reassociated(to: restoredProfile.id)])

        let repeatedImportCount = try await destinationStore.restoreRecoveryDocument(
            timeLockedOnlyDocument,
            for: restoredProfile,
            engine: KasSignerEngine()
        )
        XCTAssertEqual(repeatedImportCount.totalImported, 0)
        XCTAssertEqual(destinationStore.timeLockedSetupDrafts(for: restoredProfile.id).count, 1)
    }

    func testLegacyRecoveryFileWithoutTimeLockedDraftsStillImports() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LegacyVaultRecovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suiteName = "LegacyVaultRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let profile = WalletProfile(name: "Legacy Recovery", kpub: "legacy-recovery-wallet",
                                    network: KaspaNetwork.testnet10.rawValue)
        let store = ProtectedVaultStore(defaults: defaults,
                                        protectedStorage: ProtectedWalletStorage(directoryURL: root))
        let currentDocument = try store.recoveryDocument(for: profile)
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: currentDocument.data) as? [String: Any])
        legacyJSON.removeValue(forKey: "timeLockedSetupDrafts")
        let legacyDocument = ProtectedVaultRecoveryDocument(
            data: try JSONSerialization.data(withJSONObject: legacyJSON)
        )

        let importedCount = try await store.restoreRecoveryDocument(
            legacyDocument,
            for: profile,
            engine: KasSignerEngine()
        )
        XCTAssertEqual(importedCount.totalImported, 0)
        XCTAssertTrue(store.timeLockedSetupDrafts(for: profile.id).isEmpty)
    }

    func testRecoveryExportContainsOnlyRequestedProfilesVaults() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "VaultExportScope-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suiteName = "VaultExportScope.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let storage = ProtectedWalletStorage(directoryURL: root)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let requestedProfile = WalletProfile(name: "Requested", kpub: "export-scope-one",
                                             network: KaspaNetwork.testnet10.rawValue)
        let otherProfile = WalletProfile(name: "Other", kpub: "export-scope-two",
                                         network: KaspaNetwork.testnet10.rawValue)
        let store = ProtectedVaultStore(defaults: defaults, protectedStorage: storage)
        let requestedProtectedVault = ProtectedVault(
            profileID: requestedProfile.id,
            amount: 2,
            approvedAddresses: ["kaspatest:requested"],
            delayDays: 1,
            delayHours: 0,
            delayMinutes: 0,
            status: .active
        )
        let otherProtectedVault = ProtectedVault(
            profileID: otherProfile.id,
            amount: 3,
            approvedAddresses: ["kaspatest:other"],
            delayDays: 1,
            delayHours: 0,
            delayMinutes: 0,
            status: .active
        )
        let requestedTimeLockedVault = TimeLockedVaultSetupDraft(
            profileID: requestedProfile.id,
            unlockDate: Date(timeIntervalSince1970: 1_900_000_000),
            selectedUTXOIDs: []
        )
        let otherTimeLockedVault = TimeLockedVaultSetupDraft(
            profileID: otherProfile.id,
            unlockDate: Date(timeIntervalSince1970: 1_900_000_100),
            selectedUTXOIDs: []
        )
        let requestedSetupDraft = ProtectedVaultSetupDraft(
            profileID: requestedProfile.id,
            approvedAddressCount: 1,
            approvedAddresses: ["kaspatest:requested"],
            recoveryAddress: "kaspatest:recovery",
            recoveryPath: .emergencyAnytime,
            delayDays: 1,
            delayHours: 0,
            delayMinutes: 0,
            selectedUTXOIDs: []
        )
        let otherSetupDraft = ProtectedVaultSetupDraft(
            profileID: otherProfile.id,
            approvedAddressCount: 1,
            approvedAddresses: ["kaspatest:other"],
            recoveryAddress: "kaspatest:other-recovery",
            recoveryPath: .emergencyAnytime,
            delayDays: 1,
            delayHours: 0,
            delayMinutes: 0,
            selectedUTXOIDs: []
        )
        XCTAssertTrue(store.add(requestedProtectedVault))
        XCTAssertTrue(store.add(otherProtectedVault))
        XCTAssertTrue(store.saveSetupDraft(requestedSetupDraft))
        XCTAssertTrue(store.saveSetupDraft(otherSetupDraft))
        XCTAssertTrue(store.saveTimeLockedSetupDraft(requestedTimeLockedVault))
        XCTAssertTrue(store.saveTimeLockedSetupDraft(otherTimeLockedVault))

        let document = try store.recoveryDocument(for: requestedProfile)
        let backup = try XCTUnwrap(JSONSerialization.jsonObject(with: document.data) as? [String: Any])
        let protectedVaults = try XCTUnwrap(backup["vaults"] as? [[String: Any]])
        let setupDrafts = try XCTUnwrap(backup["setupDrafts"] as? [[String: Any]])
        let timeLockedVaults = try XCTUnwrap(backup["timeLockedSetupDrafts"] as? [[String: Any]])
        XCTAssertEqual(protectedVaults.compactMap { $0["id"] as? String }, [requestedProtectedVault.id.uuidString])
        XCTAssertEqual(setupDrafts.compactMap { $0["id"] as? String }, [requestedSetupDraft.id.uuidString])
        XCTAssertEqual(timeLockedVaults.compactMap { $0["id"] as? String }, [requestedTimeLockedVault.id.uuidString])
    }

    func testRecoveryImportAssociatesTimeLockedVaultsOnlyWithRequestedProfile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "VaultImportScope-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suiteName = "VaultImportScope.\(UUID().uuidString)"
        let destinationSuiteName = "VaultImportDestination.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let storage = ProtectedWalletStorage(directoryURL: root)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            UserDefaults.standard.removePersistentDomain(forName: destinationSuiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let sourceProfile = WalletProfile(name: "Source", kpub: "import-scope-same-wallet",
                                          network: KaspaNetwork.testnet10.rawValue)
        let requestedProfile = WalletProfile(name: "Restored", kpub: "import-scope-same-wallet",
                                             network: KaspaNetwork.testnet10.rawValue)
        let otherProfile = WalletProfile(name: "Other", kpub: "import-scope-other-wallet",
                                         network: KaspaNetwork.testnet10.rawValue)
        let sourceStore = ProtectedVaultStore(defaults: defaults, protectedStorage: storage)
        let timeLockedVault = TimeLockedVaultSetupDraft(
            profileID: sourceProfile.id,
            unlockDate: Date(timeIntervalSince1970: 1_900_000_000),
            selectedUTXOIDs: [],
            step: .fundingDetails
        )
        XCTAssertTrue(sourceStore.saveTimeLockedSetupDraft(timeLockedVault))
        let document = try sourceStore.recoveryDocument(for: sourceProfile)

        let destinationDefaults = try XCTUnwrap(UserDefaults(suiteName: destinationSuiteName))
        let destinationStore = ProtectedVaultStore(defaults: destinationDefaults,
                                                   protectedStorage: ProtectedWalletStorage(
                                                       directoryURL: root.appending(path: "destination", directoryHint: .isDirectory)
                                                   ))
        let importedCount = try await destinationStore.restoreRecoveryDocument(
            document,
            for: requestedProfile,
            engine: KasSignerEngine()
        )

        XCTAssertEqual(importedCount.totalImported, 1)
        XCTAssertEqual(destinationStore.timeLockedSetupDrafts(for: requestedProfile.id).map(\.id), [timeLockedVault.id])
        XCTAssertTrue(destinationStore.timeLockedSetupDrafts(for: otherProfile.id).isEmpty)
    }

    func testRecoveryImportReportsVaultAndDraftCountsSeparately() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "VaultRecoveryCounts-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sourceSuite = "VaultRecoveryCounts.Source.\(UUID().uuidString)"
        let destinationSuite = "VaultRecoveryCounts.Destination.\(UUID().uuidString)"
        let sourceDefaults = try XCTUnwrap(UserDefaults(suiteName: sourceSuite))
        let destinationDefaults = try XCTUnwrap(UserDefaults(suiteName: destinationSuite))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceSuite)
            destinationDefaults.removePersistentDomain(forName: destinationSuite)
            try? FileManager.default.removeItem(at: root)
        }

        // Public BIP39 test vector, used only to derive valid recovery descriptors.
        let engine = KasSignerEngine()
        let wallet = try await engine.testnetHotWallet(
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        )
        let source = WalletProfile(name: "Source", kpub: wallet.wallet.kpub,
                                  network: KaspaNetwork.testnet10.rawValue)
        let target = WalletProfile(name: "Target", kpub: source.kpub,
                                   network: KaspaNetwork.testnet10.rawValue)
        let destination = try XCTUnwrap(wallet.wallet.receiveAddresses.first)
        let recovery = try XCTUnwrap(wallet.wallet.receiveAddresses.dropFirst().first)
        let descriptor = try await engine.deriveProtectedVault(
            profile: source, receiveIndex: 0, approvedAddresses: [destination],
            recoveryAddress: recovery, emergencyAnytime: true, delayDAA: 864_000
        )
        let sourceStore = ProtectedVaultStore(defaults: sourceDefaults,
                                              protectedStorage: ProtectedWalletStorage(directoryURL: root.appending(path: "source")))
        let destinationStore = ProtectedVaultStore(defaults: destinationDefaults,
                                                   protectedStorage: ProtectedWalletStorage(directoryURL: root.appending(path: "destination")))
        let protectedDraft = ProtectedVaultSetupDraft(
            profileID: source.id, approvedAddressCount: 1,
            approvedAddresses: [destination], recoveryAddress: recovery,
            recoveryPath: .emergencyAnytime, delayDays: 1, delayHours: 0, delayMinutes: 0,
            selectedUTXOIDs: []
        )
        let timeLockedDraft = TimeLockedVaultSetupDraft(
            profileID: source.id, unlockDate: Date(timeIntervalSince1970: 1_900_000_000),
            selectedUTXOIDs: [], step: .fundingDetails
        )
        let protectedVaultDraft = ProtectedVault(
            profileID: source.id, amount: 0, approvedAddresses: [destination],
            recoveryAddress: recovery, recoveryPath: .emergencyAnytime,
            delayDays: 1, delayHours: 0, delayMinutes: 0,
            ownerDerivationIndex: 0, ownerPublicKey: descriptor.ownerPublicKey,
            redeemScriptHex: descriptor.redeemScriptHex, vaultAddress: descriptor.vaultAddress,
            status: .localDraft
        )
        XCTAssertTrue(sourceStore.saveSetupDraft(protectedDraft))
        XCTAssertTrue(sourceStore.saveTimeLockedSetupDraft(timeLockedDraft))
        XCTAssertTrue(sourceStore.add(protectedVaultDraft))

        let imported = try await destinationStore.restoreRecoveryDocument(
            sourceStore.recoveryDocument(for: source), for: target, engine: engine
        )
        XCTAssertEqual(imported.totalImported, 3)
        XCTAssertEqual(imported.recordsInFile, 3)
        XCTAssertEqual(imported.protectedVaults, 0)
        XCTAssertEqual(imported.timeLockedVaults, 0)
        XCTAssertEqual(imported.protectedSetupDrafts, 2)
        XCTAssertEqual(imported.timeLockedSetupDrafts, 1)

        let repeated = try await destinationStore.restoreRecoveryDocument(
            sourceStore.recoveryDocument(for: source), for: target, engine: engine
        )
        XCTAssertEqual(repeated.totalImported, 0)
        XCTAssertEqual(repeated.recordsInFile, 3)
    }

    func testStaleTimeLockedSetupSavesPreserveFundedAndSpentRecords() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "TimeLockSetupGuard-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suite = "TimeLockSetupGuard.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let storage = ProtectedWalletStorage(directoryURL: root)
        let store = ProtectedVaultStore(defaults: defaults, protectedStorage: storage)
        var setup = TimeLockedVaultSetupDraft(
            profileID: UUID(), unlockDate: Date(timeIntervalSince1970: 1_900_000_000),
            selectedUTXOIDs: ["selected-input"], step: .fundingDetails
        )
        XCTAssertTrue(store.saveTimeLockedSetupDraft(setup))
        setup.step = .rules
        XCTAssertTrue(store.saveTimeLockedSetupDraft(setup))
        XCTAssertEqual(store.timeLockedSetupDraft(id: setup.id)?.step, .rules)

        let descriptor = TimeLockedDestinationDescriptor(
            ownerDerivationIndex: 2, ownerPublicKey: "owner", destinationAddress: "destination",
            locktimeDAA: 700_000_000, maximumClaimFeeSompi: 10_000_000,
            nonceHex: "0102030405060708", redeemScriptHex: "script", vaultAddress: "vault"
        )
        XCTAssertTrue(store.recordTimeLockedFunding(
            id: setup.id, transactionID: String(repeating: "a", count: 64),
            descriptor: descriptor, amountSompi: 100_000_000,
            covenantID: String(repeating: "b", count: 64), outputIndex: 3
        ))
        let funded = try XCTUnwrap(store.timeLockedSetupDraft(id: setup.id))
        for step in [TimeLockedVaultSetupDraft.Step.rules, .fundingDetails] {
            // Both a captured pre-funding draft and a callback using the latest
            // record must be unable to downgrade or overwrite funding metadata.
            setup.step = step
            XCTAssertTrue(store.saveTimeLockedSetupDraft(setup))
            var rewritten = funded
            rewritten.step = step
            rewritten.fundingOutputIndex = nil
            rewritten.destination = "stale destination"
            XCTAssertTrue(store.saveTimeLockedSetupDraft(rewritten))
            XCTAssertEqual(store.timeLockedSetupDraft(id: setup.id), funded)
        }
        XCTAssertTrue(store.recordTimeLockedClaim(
            id: setup.id, transactionID: String(repeating: "c", count: 64)
        ))
        let spent = try XCTUnwrap(store.timeLockedSetupDraft(id: setup.id))
        XCTAssertTrue(store.saveTimeLockedSetupDraft(setup))
        XCTAssertEqual(store.timeLockedSetupDraft(id: setup.id), spent)
        let relaunched = ProtectedVaultStore(defaults: defaults, protectedStorage: storage)
        XCTAssertEqual(relaunched.timeLockedSetupDraft(id: setup.id), spent)
    }

    func testLegacyFundedTimeLockedRecordWithoutOutputIndexImportsAndDescriptorIsVerified() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LegacyFundedTimeLockRecovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sourceSuite = "LegacyFundedTimeLockRecovery.Source.\(UUID().uuidString)"
        let targetSuite = "LegacyFundedTimeLockRecovery.Target.\(UUID().uuidString)"
        let tamperedSuite = "LegacyFundedTimeLockRecovery.Tampered.\(UUID().uuidString)"
        let sourceDefaults = try XCTUnwrap(UserDefaults(suiteName: sourceSuite))
        let targetDefaults = try XCTUnwrap(UserDefaults(suiteName: targetSuite))
        let tamperedDefaults = try XCTUnwrap(UserDefaults(suiteName: tamperedSuite))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceSuite)
            targetDefaults.removePersistentDomain(forName: targetSuite)
            tamperedDefaults.removePersistentDomain(forName: tamperedSuite)
            try? FileManager.default.removeItem(at: root)
        }

        // Public BIP39 test vector; no wallet secret is used or stored.
        let engine = KasSignerEngine()
        let wallet = try await engine.testnetHotWallet(
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        )
        let sourceProfile = WalletProfile(name: "Legacy source", kpub: wallet.wallet.kpub,
                                          network: KaspaNetwork.testnet10.rawValue)
        let restoredProfile = WalletProfile(name: "Legacy restored", kpub: wallet.wallet.kpub,
                                            network: KaspaNetwork.testnet10.rawValue)
        let destination = try XCTUnwrap(wallet.wallet.receiveAddresses.first)
        let locktime: UInt64 = 700_000_000
        let descriptor = try await engine.deriveTimeLockedDestination(
            profile: sourceProfile, receiveIndex: 0, destination: destination,
            locktimeDAA: locktime, nonceHex: "0102030405060708"
        )
        let legacyFundedRecord = TimeLockedVaultSetupDraft(
            profileID: sourceProfile.id,
            unlockDate: Date(timeIntervalSince1970: 1_900_000_000),
            selectedUTXOIDs: [],
            destination: descriptor.destinationAddress,
            amountText: "1",
            nonceHex: descriptor.nonceHex,
            locktimeDAA: descriptor.locktimeDAA,
            ownerDerivationIndex: descriptor.ownerDerivationIndex,
            ownerPublicKey: descriptor.ownerPublicKey,
            redeemScriptHex: descriptor.redeemScriptHex,
            vaultAddress: descriptor.vaultAddress,
            amountSompi: 100_000_000,
            covenantID: String(repeating: "c", count: 64),
            fundingTransactionID: String(repeating: "d", count: 64),
            fundingOutputIndex: nil,
            step: .funded
        )
        let sourceStore = ProtectedVaultStore(
            defaults: sourceDefaults,
            protectedStorage: ProtectedWalletStorage(directoryURL: root.appending(path: "source"))
        )
        XCTAssertTrue(sourceStore.saveTimeLockedSetupDraft(legacyFundedRecord))
        let document = try sourceStore.recoveryDocument(for: sourceProfile)

        let targetStore = ProtectedVaultStore(
            defaults: targetDefaults,
            protectedStorage: ProtectedWalletStorage(directoryURL: root.appending(path: "target"))
        )
        let imported = try await targetStore.restoreRecoveryDocument(
            document, for: restoredProfile, engine: engine
        )
        XCTAssertEqual(imported.timeLockedVaults, 1)
        XCTAssertEqual(targetStore.timeLockedSetupDrafts(for: restoredProfile.id).first?.fundingOutputIndex, nil)

        var tamperedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: document.data) as? [String: Any])
        var records = try XCTUnwrap(tamperedJSON["timeLockedSetupDrafts"] as? [[String: Any]])
        records[0]["ownerPublicKey"] = String(repeating: "0", count: descriptor.ownerPublicKey.count)
        tamperedJSON["timeLockedSetupDrafts"] = records
        let tamperedDocument = ProtectedVaultRecoveryDocument(
            data: try JSONSerialization.data(withJSONObject: tamperedJSON)
        )
        let tamperedStore = ProtectedVaultStore(
            defaults: tamperedDefaults,
            protectedStorage: ProtectedWalletStorage(directoryURL: root.appending(path: "tampered"))
        )
        do {
            _ = try await tamperedStore.restoreRecoveryDocument(
                tamperedDocument, for: restoredProfile, engine: engine
            )
            XCTFail("A funded record with a modified owner key must not be imported.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not match this wallet"))
        }
        XCTAssertTrue(tamperedStore.timeLockedSetupDrafts(for: restoredProfile.id).isEmpty)
    }

    func testRecoveryRejectsIncompleteFundedTimeLockedRecordWithoutPartialImport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "VaultRecoveryAtomic-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suiteName = "VaultRecoveryAtomic.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let profile = WalletProfile(name: "Recovery", kpub: "atomic-import-wallet",
                                    network: KaspaNetwork.testnet10.rawValue)
        let store = ProtectedVaultStore(defaults: defaults,
                                        protectedStorage: ProtectedWalletStorage(directoryURL: root))
        let incomplete = TimeLockedVaultSetupDraft(
            profileID: profile.id, unlockDate: Date(timeIntervalSince1970: 1_900_000_000),
            selectedUTXOIDs: [], fundingTransactionID: String(repeating: "a", count: 64),
            step: .funded
        )
        let setupDraft = ProtectedVaultSetupDraft(
            profileID: profile.id, approvedAddressCount: 1,
            approvedAddresses: ["kaspatest:approved"], recoveryAddress: "kaspatest:recovery",
            recoveryPath: .emergencyAnytime, delayDays: 1, delayHours: 0, delayMinutes: 0,
            selectedUTXOIDs: []
        )
        // Build the payload through a same-profile export, then insert the invalid record.
        let emptyDocument = try store.recoveryDocument(for: profile)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: emptyDocument.data) as? [String: Any])
        let encoder = JSONEncoder()
        json["setupDrafts"] = try JSONSerialization.jsonObject(with: encoder.encode([setupDraft]))
        json["timeLockedSetupDrafts"] = try JSONSerialization.jsonObject(with: encoder.encode([incomplete]))
        let document = ProtectedVaultRecoveryDocument(data: try JSONSerialization.data(withJSONObject: json))

        do {
            _ = try await store.restoreRecoveryDocument(document, for: profile, engine: KasSignerEngine())
            XCTFail("An incomplete funded Time-Locked Vault must be rejected.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("incomplete funded"))
        }
        XCTAssertTrue(store.setupDrafts(for: profile.id).isEmpty, "Import must be atomic when validation fails.")
        XCTAssertTrue(store.timeLockedSetupDrafts(for: profile.id).isEmpty)
    }

    func testArchivedVaultStatePersistsForBothVaultTypesAndRemainsAccountScoped() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ArchivedVaults-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suiteName = "ArchivedVaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let storage = ProtectedWalletStorage(directoryURL: root)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let profileID = UUID()
        let otherProfileID = UUID()
        let archivedAt = Date(timeIntervalSince1970: 1_800_000_789)
        let protectedVault = ProtectedVault(
            profileID: profileID,
            name: "Archive Protected",
            amount: 2,
            approvedAddresses: ["kaspatest:destination"],
            delayDays: 1,
            delayHours: 0,
            delayMinutes: 0,
            vaultAddress: "kaspatest:protected-vault",
            status: .active,
            fundingTransactionID: String(repeating: "a", count: 64)
        )
        let timeLockedVault = TimeLockedVaultSetupDraft(
            profileID: profileID,
            unlockDate: Date(timeIntervalSince1970: 1_900_000_000),
            selectedUTXOIDs: [],
            destination: "kaspatest:claim-destination",
            amountSompi: 500_000_000,
            covenantID: String(repeating: "c", count: 64),
            fundingTransactionID: String(repeating: "b", count: 64),
            claimTransactionID: String(repeating: "d", count: 64),
            step: .spent
        )
        let protectedDraft = ProtectedVault(
            profileID: profileID,
            amount: 1,
            approvedAddresses: ["kaspatest:draft"],
            delayDays: 1,
            delayHours: 0,
            delayMinutes: 0,
            status: .localDraft
        )
        let protectedSetupDraft = ProtectedVaultSetupDraft(
            profileID: profileID,
            approvedAddressCount: 1,
            approvedAddresses: ["kaspatest:setup-draft"],
            recoveryAddress: "kaspatest:recovery",
            recoveryPath: .emergencyAnytime,
            delayDays: 1,
            delayHours: 0,
            delayMinutes: 0,
            selectedUTXOIDs: []
        )
        let timeLockedDraft = TimeLockedVaultSetupDraft(
            profileID: profileID,
            unlockDate: Date(timeIntervalSince1970: 1_900_000_100),
            selectedUTXOIDs: []
        )
        let store = ProtectedVaultStore(defaults: defaults, protectedStorage: storage)
        XCTAssertTrue(store.add(protectedVault))
        XCTAssertTrue(store.saveTimeLockedSetupDraft(timeLockedVault))
        XCTAssertTrue(store.add(protectedDraft))
        XCTAssertTrue(store.saveSetupDraft(protectedSetupDraft))
        XCTAssertTrue(store.saveTimeLockedSetupDraft(timeLockedDraft))
        XCTAssertFalse(store.setArchived(true, for: protectedDraft.id, type: .protected, at: archivedAt))
        XCTAssertFalse(store.setArchived(true, for: timeLockedDraft.id, type: .timeLocked, at: archivedAt))
        XCTAssertTrue(store.setArchived(true, for: protectedVault.id, type: .protected, at: archivedAt))
        XCTAssertTrue(store.setArchived(true, for: timeLockedVault.id, type: .timeLocked, at: archivedAt))
        XCTAssertFalse(store.setArchived(true, for: protectedVault.id, type: .protected, at: archivedAt))

        let relaunched = ProtectedVaultStore(defaults: defaults, protectedStorage: storage)
        XCTAssertEqual(relaunched.vaults(for: profileID).first(where: { $0.id == protectedVault.id })?.archivedAt,
                       archivedAt)
        let archivedProtected = try XCTUnwrap(relaunched.vaults(for: profileID).first { $0.id == protectedVault.id })
        XCTAssertEqual(archivedProtected.displayName, "Archive Protected")
        XCTAssertEqual(archivedProtected.vaultAddress, "kaspatest:protected-vault")
        XCTAssertEqual(archivedProtected.fundingTransactionID, protectedVault.fundingTransactionID)
        let archivedTimeLocked = try XCTUnwrap(relaunched.timeLockedSetupDraft(id: timeLockedVault.id))
        XCTAssertEqual(archivedTimeLocked.archivedAt, archivedAt)
        XCTAssertEqual(archivedTimeLocked.destination, timeLockedVault.destination)
        XCTAssertEqual(archivedTimeLocked.covenantID, timeLockedVault.covenantID)
        XCTAssertEqual(archivedTimeLocked.fundingTransactionID, timeLockedVault.fundingTransactionID)
        XCTAssertEqual(archivedTimeLocked.claimTransactionID, timeLockedVault.claimTransactionID)
        XCTAssertEqual(archivedTimeLocked.step, .spent)
        XCTAssertTrue(relaunched.timeLockedSetupDrafts(for: otherProfileID).isEmpty)
        XCTAssertFalse(relaunched.setArchived(true, for: UUID(), type: .timeLocked, at: archivedAt))
        relaunched.remove(id: protectedDraft.id)
        relaunched.removeSetupDraft(id: protectedSetupDraft.id)
        relaunched.removeTimeLockedSetupDraft(id: timeLockedDraft.id)
        XCTAssertNil(relaunched.vaults(for: profileID).first { $0.id == protectedDraft.id })
        XCTAssertNil(relaunched.setupDraft(id: protectedSetupDraft.id))
        XCTAssertNil(relaunched.timeLockedSetupDraft(id: timeLockedDraft.id))

        XCTAssertTrue(relaunched.setArchived(false, for: protectedVault.id, type: .protected))
        XCTAssertTrue(relaunched.setArchived(false, for: timeLockedVault.id, type: .timeLocked))
        let restored = ProtectedVaultStore(defaults: defaults, protectedStorage: storage)
        XCTAssertNil(restored.vaults(for: profileID).first(where: { $0.id == protectedVault.id })?.archivedAt)
        let restoredTimeLocked = try XCTUnwrap(restored.timeLockedSetupDraft(id: timeLockedVault.id))
        XCTAssertNil(restoredTimeLocked.archivedAt)
        XCTAssertEqual(restoredTimeLocked.destination, timeLockedVault.destination)
        XCTAssertEqual(restoredTimeLocked.claimTransactionID, timeLockedVault.claimTransactionID)
        XCTAssertTrue(restored.setupDrafts(for: profileID).isEmpty)
        XCTAssertNil(restored.vaults(for: profileID).first { $0.id == protectedDraft.id })
        XCTAssertNil(restored.setupDraft(id: protectedSetupDraft.id))
        XCTAssertNil(restored.timeLockedSetupDraft(id: timeLockedDraft.id))
        XCTAssertFalse(restored.setArchived(false, for: UUID(), type: .protected))
        XCTAssertFalse(restored.setArchived(false, for: UUID(), type: .timeLocked))
    }

    func testRefreshFailureRetainsVerifiedTimestampAndSuccessfulRetryClearsStaleState() throws {
        let firstCheck = Date(timeIntervalSince1970: 1_800_000_000)
        let verified = ProtectedVaultRefreshInfo(
            checkedAt: firstCheck,
            network: "Testnet 10",
            nodeLabel: "Automatic Nodes"
        )
        var state = ProtectedVaultRefreshState()
        state.begin(at: firstCheck, network: "Testnet 10", nodeLabel: "Automatic Nodes")
        state.succeed(with: verified)

        let failedAttempt = firstCheck.addingTimeInterval(60)
        state.begin(at: failedAttempt, network: "Testnet 10", nodeLabel: "Automatic Nodes")
        state.fail(message: "Could not refresh on-chain data.")

        XCTAssertTrue(state.isStale)
        XCTAssertFalse(state.isRefreshing)
        XCTAssertEqual(state.lastSuccessfulInfo, verified)
        XCTAssertEqual(state.lastAttemptAt, failedAttempt)
        XCTAssertEqual(state.errorMessage, "Could not refresh on-chain data.")

        let retryCheck = firstCheck.addingTimeInterval(120)
        let refreshed = ProtectedVaultRefreshInfo(
            checkedAt: retryCheck,
            network: "Testnet 10",
            nodeLabel: "Automatic Nodes"
        )
        state.begin(at: retryCheck, network: "Testnet 10", nodeLabel: "Automatic Nodes")
        state.succeed(with: refreshed)

        XCTAssertFalse(state.isStale)
        XCTAssertFalse(state.isRefreshing)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.lastSuccessfulInfo, refreshed)
    }

    func testRefreshStateRoundTripsForProtectedPersistence() throws {
        let info = ProtectedVaultRefreshInfo(
            checkedAt: Date(timeIntervalSince1970: 1_800_000_000),
            network: "Mainnet",
            nodeLabel: "example.org:443"
        )
        var state = ProtectedVaultRefreshState(lastSuccessfulInfo: info)
        state.begin(at: info.checkedAt.addingTimeInterval(30), network: "Mainnet", nodeLabel: "example.org:443")
        state.fail(message: "Could not refresh on-chain data.")

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(ProtectedVaultRefreshState.self, from: data)

        XCTAssertEqual(restored, state)
        XCTAssertTrue(restored.isStale)
        XCTAssertEqual(restored.lastSuccessfulInfo, info)
    }

    func testLegacyVaultMigrationAndSameWalletReassociationSurviveRelaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "VaultRecovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        let storage = ProtectedWalletStorage(directoryURL: root)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "VaultRecovery.\(UUID().uuidString)"))
        let oldProfile = WalletProfile(name: "Original", kpub: "kpub-recovery-test",
                                       network: KaspaNetwork.testnet10.rawValue)
        let vault = ProtectedVault(profileID: oldProfile.id, amount: 1,
                                   approvedAddresses: ["kaspatest:approved"],
                                   delayDays: 1, delayHours: 0, delayMinutes: 0)
        defaults.set(try JSONEncoder().encode([vault]), forKey: "kassigner.protectedVaults.v1")

        let migrated = ProtectedVaultStore(defaults: defaults, protectedStorage: storage)
        XCTAssertNil(migrated.storageError)
        XCTAssertEqual(migrated.vaults(for: oldProfile.id).count, 1)
        XCTAssertTrue(storage.contains(fileName: "protected-vault-state.json"))
        XCTAssertNil(defaults.data(forKey: "kassigner.protectedVaults.v1"))
        XCTAssertTrue(migrated.registerWallet(oldProfile))

        let restoredProfile = WalletProfile(name: "Restored", kpub: oldProfile.kpub,
                                            network: oldProfile.network)
        XCTAssertTrue(migrated.reassociateVaults(to: restoredProfile))
        XCTAssertTrue(migrated.vaults(for: oldProfile.id).isEmpty)
        XCTAssertEqual(migrated.vaults(for: restoredProfile.id).first?.id, vault.id)

        let relaunched = ProtectedVaultStore(defaults: defaults, protectedStorage: storage)
        XCTAssertEqual(relaunched.vaults(for: restoredProfile.id).first?.id, vault.id)
    }

    func testLastOpenedTimestampPersistsWithoutRewritingVaultRegistry() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "VaultLastOpened-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suiteName = "VaultLastOpened.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let storage = ProtectedWalletStorage(directoryURL: root)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let store = ProtectedVaultStore(defaults: defaults, protectedStorage: storage)
        let registryURL = root.appending(path: "protected-vault-state.json")
        let profileID = UUID()
        let vaultID = UUID()
        let openedAt = Date(timeIntervalSince1970: 1_800_000_123)
        let vault = ProtectedVault(
            id: vaultID,
            profileID: profileID,
            amount: 1,
            approvedAddresses: ["kaspatest:approved"],
            delayDays: 1,
            delayHours: 0,
            delayMinutes: 0
        )
        XCTAssertTrue(store.add(vault))
        let registryBeforeOpen = try Data(contentsOf: registryURL)

        store.recordOpened(id: vaultID, profileID: profileID, at: openedAt)

        XCTAssertEqual(try Data(contentsOf: registryURL), registryBeforeOpen)
        XCTAssertEqual(store.lastOpenedAt(id: vaultID, profileID: profileID), openedAt)
        XCTAssertNil(store.lastOpenedAt(id: vaultID, profileID: UUID()))
        XCTAssertNotNil(defaults.data(forKey: "kassigner.protectedVaultLastOpened.v1"))

        store.rename(id: vaultID, to: "Renamed Vault")
        XCTAssertTrue(store.recordFundingBroadcast(id: vaultID, transactionID: String(repeating: "a", count: 64)))
        XCTAssertEqual(store.lastOpenedAt(id: vaultID, profileID: profileID), openedAt)

        let relaunched = ProtectedVaultStore(defaults: defaults, protectedStorage: storage)
        XCTAssertEqual(relaunched.lastOpenedAt(id: vaultID, profileID: profileID), openedAt)
        XCTAssertEqual(relaunched.vaults(for: profileID).first?.displayName, "Renamed Vault")
        relaunched.remove(id: vaultID)
        XCTAssertNil(relaunched.lastOpenedAt(id: vaultID, profileID: profileID))
    }

    func testVaultLastOpenedOrderingUsesRecencyThenDeterministicCreationAndIDTieBreakers() {
        let olderID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let newerID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let olderCreation = Date(timeIntervalSince1970: 100)
        let newerCreation = Date(timeIntervalSince1970: 200)
        let firstOpen = Date(timeIntervalSince1970: 300)
        let recentOpen = Date(timeIntervalSince1970: 400)

        XCTAssertTrue(VaultLastOpenedOrder.precedes(
            id: olderID, createdAt: olderCreation, lastOpenedAt: recentOpen,
            id: newerID, createdAt: newerCreation, lastOpenedAt: firstOpen
        ))
        XCTAssertTrue(VaultLastOpenedOrder.precedes(
            id: olderID, createdAt: olderCreation, lastOpenedAt: firstOpen,
            id: newerID, createdAt: newerCreation, lastOpenedAt: nil
        ))
        XCTAssertTrue(VaultLastOpenedOrder.precedes(
            id: olderID, createdAt: newerCreation, lastOpenedAt: nil,
            id: newerID, createdAt: olderCreation, lastOpenedAt: nil
        ))
        XCTAssertTrue(VaultLastOpenedOrder.precedes(
            id: olderID, createdAt: olderCreation, lastOpenedAt: nil,
            id: newerID, createdAt: olderCreation, lastOpenedAt: nil
        ))
    }

    func testTimeLockedVaultRenamePreservesOrderAndRemovalClearsIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "TimeLockedVaultLastOpened-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suiteName = "TimeLockedVaultLastOpened.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let storage = ProtectedWalletStorage(directoryURL: root)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let store = ProtectedVaultStore(defaults: defaults, protectedStorage: storage)
        let profileID = UUID()
        let draftID = UUID()
        let openedAt = Date(timeIntervalSince1970: 1_800_000_456)
        var draft = TimeLockedVaultSetupDraft(
            id: draftID,
            profileID: profileID,
            unlockDate: Date(timeIntervalSince1970: 1_900_000_000),
            selectedUTXOIDs: [],
            fundingTransactionID: String(repeating: "b", count: 64),
            step: .funded
        )
        draft.name = "Original Time Lock"
        XCTAssertTrue(store.saveTimeLockedSetupDraft(draft))

        store.recordOpened(id: draftID, profileID: profileID, at: openedAt)
        store.renameTimeLockedVault(id: draftID, to: "Renamed Time Lock")
        XCTAssertEqual(store.lastOpenedAt(id: draftID, profileID: profileID), openedAt)

        let relaunched = ProtectedVaultStore(defaults: defaults, protectedStorage: storage)
        XCTAssertEqual(relaunched.lastOpenedAt(id: draftID, profileID: profileID), openedAt)
        XCTAssertEqual(relaunched.timeLockedSetupDraft(id: draftID)?.displayName, "Renamed Time Lock")
        relaunched.removeTimeLockedSetupDraft(id: draftID)
        XCTAssertNil(relaunched.lastOpenedAt(id: draftID, profileID: profileID))
    }

    func testCorruptProtectedVaultFileIsNotReplacedByLegacyData() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "VaultCorrupt-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "protected-vault-state.json")
        let corrupt = Data("invalid vault JSON".utf8)
        try corrupt.write(to: file)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "VaultCorrupt.\(UUID().uuidString)"))
        let store = ProtectedVaultStore(defaults: defaults,
                                        protectedStorage: ProtectedWalletStorage(directoryURL: root))
        XCTAssertNotNil(store.storageError)
        XCTAssertFalse(store.add(ProtectedVault(profileID: UUID(), amount: 1,
                                                approvedAddresses: ["kaspatest:approved"],
                                                delayDays: 1, delayHours: 0, delayMinutes: 0)))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testWalletImportDoesNotPublishProfileWhenProtectedSaveFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WalletSaveFailure-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: root)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WalletSaveFailure.\(UUID().uuidString)"))
        let wallet = WalletStore(protectedStorage: ProtectedWalletStorage(directoryURL: root),
                                 defaults: defaults)
        let profile = WalletProfile(name: "Must Not Appear", kpub: "kpub-save-failure")
        XCTAssertFalse(wallet.add(profile))
        XCTAssertTrue(wallet.profiles.isEmpty)
        XCTAssertNil(wallet.selectedProfile)
    }

    func testRecoveryFileRejectsAnotherWallet() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "VaultWrongWallet-\(UUID().uuidString)", directoryHint: .isDirectory)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "VaultWrongWallet.\(UUID().uuidString)"))
        let store = ProtectedVaultStore(defaults: defaults,
                                        protectedStorage: ProtectedWalletStorage(directoryURL: root))
        let original = WalletProfile(name: "Original", kpub: "kpub-one",
                                     network: KaspaNetwork.testnet10.rawValue)
        let other = WalletProfile(name: "Other", kpub: "kpub-two",
                                  network: KaspaNetwork.testnet10.rawValue)
        let document = try store.recoveryDocument(for: original)
        do {
            _ = try await store.restoreRecoveryDocument(document, for: other,
                                                        engine: KasSignerEngine())
            XCTFail("A vault recovery file must not load into another wallet.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not belong"))
        }
    }
}

@MainActor
final class UTXOBadgePersistenceTests: XCTestCase {
    private func utxo(_ id: String) -> WalletUTXO {
        WalletUTXO(
            txID: id, index: 0, amount: 100_000_000,
            scriptPublicKey: [], blockDAAScore: 1, covenantID: nil
        )
    }

    func testManualBadgeSurvivesReloadAndDefaultDoesNotReplaceIt() {
        let storage = ProtectedWalletStorage(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("utxo-badges-\(UUID().uuidString)"))
        let defaults = UserDefaults(suiteName: "utxo-badges-\(UUID().uuidString)")!
        let profile = WalletProfile(name: "Wallet", kpub: "badge-test")
        let output = utxo("existing")
        let first = UTXOCoinControlStore(protectedStorage: storage, defaults: defaults)
        first.activate(profile: profile)
        first.applyDefaultKYCStatus(to: [output], defaultStatus: .kyc)
        first.setKYCStatus(.nonKYC, for: output)
        XCTAssertNil(first.persistenceAlert)

        let reloaded = UTXOCoinControlStore(protectedStorage: storage, defaults: defaults)
        reloaded.activate(profile: profile)
        reloaded.applyDefaultKYCStatus(to: [output, utxo("new")], defaultStatus: .kyc)
        XCTAssertEqual(reloaded.kycStatus(for: output), .nonKYC)
        XCTAssertEqual(reloaded.kycStatus(for: utxo("new")), .kyc)
    }

    func testFailedBadgeSaveLeavesPreviousValueAndShowsError() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("utxo-badges-blocked-\(UUID().uuidString)")
        try Data().write(to: parent)
        let storage = ProtectedWalletStorage(directoryURL: parent)
        let defaults = UserDefaults(suiteName: "utxo-badges-\(UUID().uuidString)")!
        let store = UTXOCoinControlStore(protectedStorage: storage, defaults: defaults)
        let output = utxo("manual")
        store.activate(profile: WalletProfile(name: "Wallet", kpub: "badge-test"))
        store.setKYCStatus(.nonKYC, for: output)
        XCTAssertNil(store.kycStatus(for: output))
        XCTAssertNotNil(store.persistenceAlert)
    }

    func testUnreadableSavedBadgesBlockChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("utxo-badges-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = WalletProfile(name: "Wallet", kpub: "badge-test")
        let profileID = profile.id
        try Data("invalid".utf8).write(to: directory.appendingPathComponent(
            "utxo-kyc-statuses-\(profileID.uuidString.lowercased()).json"
        ))
        let defaults = UserDefaults(suiteName: "utxo-badges-\(UUID().uuidString)")!
        let store = UTXOCoinControlStore(
            protectedStorage: ProtectedWalletStorage(directoryURL: directory), defaults: defaults
        )
        let output = utxo("manual")
        store.activate(profile: profile)
        store.setKYCStatus(.nonKYC, for: output)
        XCTAssertNil(store.kycStatus(for: output))
        XCTAssertNotNil(store.persistenceAlert)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(
            "utxo-kyc-statuses-\(profileID.uuidString.lowercased()).json"
        )), Data("invalid".utf8))
    }
}

final class PortfolioCalculationsTests: XCTestCase {
    func testTimeLockedRefreshRecognizesOnlyAcceptedExactClaimSpend() {
        let fundingID = String(repeating: "a", count: 64)
        let claimID = String(repeating: "b", count: 64)
        let vaultAddress = "kaspatest:qvault"
        let destination = "kaspatest:qdestination"
        let claim = IndexedTransaction(
            transactionID: claimID,
            blockTime: nil,
            isAccepted: true,
            acceptingBlockTime: nil,
            acceptingBlockBlueScore: 123,
            inputs: [IndexedTransactionInput(
                previousOutpointHash: fundingID,
                previousOutpointIndex: 1,
                previousOutpointAddress: vaultAddress,
                previousOutpointAmount: 1_000_000
            )],
            outputs: [IndexedTransactionOutput(
                amount: 999_000,
                scriptPublicKeyAddress: destination
            )]
        )

        XCTAssertEqual(
            Testnet10TimeLockedClaimVerifier.confirmedClaimTransactionID(
                in: [claim],
                fundingTransactionID: fundingID,
                fundingOutputIndex: 1,
                destinationAddress: destination,
                amountSompi: 1_000_000,
                maximumFeeSompi: 10_000
            ),
            claimID
        )

        let unaccepted = IndexedTransaction(
            transactionID: claimID,
            blockTime: nil,
            isAccepted: false,
            acceptingBlockTime: nil,
            acceptingBlockBlueScore: nil,
            inputs: claim.inputs,
            outputs: claim.outputs
        )
        XCTAssertNil(Testnet10TimeLockedClaimVerifier.confirmedClaimTransactionID(
            in: [unaccepted], fundingTransactionID: fundingID,
            fundingOutputIndex: 1, destinationAddress: destination,
            amountSompi: 1_000_000, maximumFeeSompi: 10_000
        ))
    }

    func testTimeLockedRefreshRejectsWrongOutpointDestinationAndExcessiveFee() {
        let fundingID = String(repeating: "a", count: 64)
        let claimID = String(repeating: "b", count: 64)
        let transaction = IndexedTransaction(
            transactionID: claimID,
            blockTime: nil,
            isAccepted: true,
            acceptingBlockTime: nil,
            acceptingBlockBlueScore: 123,
            inputs: [IndexedTransactionInput(
                previousOutpointHash: String(repeating: "c", count: 64),
                previousOutpointIndex: 1,
                previousOutpointAddress: "kaspatest:qvault",
                previousOutpointAmount: 1_000_000
            )],
            outputs: [IndexedTransactionOutput(
                amount: 900_000,
                scriptPublicKeyAddress: "kaspatest:qother"
            )]
        )
        XCTAssertNil(Testnet10TimeLockedClaimVerifier.confirmedClaimTransactionID(
            in: [transaction], fundingTransactionID: fundingID,
            fundingOutputIndex: 1, destinationAddress: "kaspatest:qdestination",
            amountSompi: 1_000_000, maximumFeeSompi: 10_000
        ))
    }

    func testTransactionGraphRejectsMissingInputOrOutputLists() {
        let client = TransactionHistoryClient()
        let input = IndexedTransactionInput(
            previousOutpointAddress: "kaspa:qqqqqqqqq",
            previousOutpointAmount: 200
        )
        let output = IndexedTransactionOutput(
            amount: 190,
            scriptPublicKeyAddress: "kaspa:qqqqqqqqq"
        )

        func indexed(
            inputs: [IndexedTransactionInput]?,
            outputs: [IndexedTransactionOutput]?
        ) -> IndexedTransaction {
            IndexedTransaction(
                transactionID: "abc",
                blockTime: nil,
                isAccepted: nil,
                acceptingBlockTime: nil,
                acceptingBlockBlueScore: nil,
                inputs: inputs,
                outputs: outputs
            )
        }

        XCTAssertThrowsError(
            try client.makeTransactionGraph(indexed(inputs: nil, outputs: [output]), fallbackID: "abc")
        )
        XCTAssertThrowsError(
            try client.makeTransactionGraph(indexed(inputs: [input], outputs: nil), fallbackID: "abc")
        )
        let graph = try? client.makeTransactionGraph(
            indexed(inputs: [input], outputs: [output]),
            fallbackID: "abc"
        )
        XCTAssertEqual(graph?.feeSompi, 10)
    }

    func testGraphAddressFormatRejectsIncompleteAddresses() {
        XCTAssertFalse(TransactionGraphAddress.hasPlausibleFormat("kaspa:"))
        XCTAssertFalse(TransactionGraphAddress.hasPlausibleFormat("kaspa:qqqqqqqq"))
        XCTAssertFalse(TransactionGraphAddress.hasPlausibleFormat("kaspa:qqqqqqqqb"))
        XCTAssertFalse(TransactionGraphAddress.hasPlausibleFormat("https://example.com"))
        XCTAssertTrue(TransactionGraphAddress.hasPlausibleFormat("kaspa:qqqqqqqqq"))
    }

    @MainActor
    func testPartialGraphCacheRefreshesAndPersistsCompleteGraph() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("graph-cache-test-\(UUID().uuidString)")
        let storage = ProtectedWalletStorage(directoryURL: directory)
        let cache = TransactionGraphCache(storage: storage)
        let profileID = UUID()
        let partial = TransactionGraphDetails(
            transactionID: "abc",
            inputs: [TransactionGraphInput(outpoint: "prior:0", address: nil, amountSompi: nil)],
            outputs: [TransactionGraphOutput(index: 0, address: "kaspa:qqqqqqqqq", amountSompi: 190)],
            feeSompi: nil
        )

        await cache.save([partial], profileID: profileID)
        XCTAssertTrue(cache.shouldRefresh(partial, profileID: profileID))
        await cache.save([partial], profileID: profileID, markRefreshed: true)
        XCTAssertFalse(cache.shouldRefresh(partial, profileID: profileID))

        let complete = TransactionGraphDetails(
            transactionID: "abc",
            inputs: [TransactionGraphInput(
                outpoint: "prior:0",
                address: "kaspa:qqqqqqqqq",
                amountSompi: 200
            )],
            outputs: partial.outputs,
            feeSompi: 10
        )
        await cache.save([complete], profileID: profileID)
        XCTAssertFalse(cache.shouldRefresh(complete, profileID: profileID))
        await cache.save([partial], profileID: profileID)
        let reloadedGraph = await TransactionGraphCache(storage: storage).graph(
            profileID: profileID,
            transactionID: "ABC"
        )
        XCTAssertEqual(reloadedGraph, complete)
    }

    @MainActor
    func testGraphCacheReadsEarlierDiskFormat() async {
        struct EarlierDiskCache: Encodable {
            let schemaVersion: Int
            let graphs: [String: TransactionGraphDetails]
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("graph-cache-legacy-test-\(UUID().uuidString)")
        let storage = ProtectedWalletStorage(directoryURL: directory)
        let profileID = UUID()
        let graph = TransactionGraphDetails(
            transactionID: "abc",
            inputs: [],
            outputs: [TransactionGraphOutput(
                index: 0,
                address: "kaspa:qqqqqqqqq",
                amountSompi: 100
            )],
            feeSompi: nil
        )
        let name = "transaction-graphs-\(profileID.uuidString.lowercased()).json"
        XCTAssertTrue(storage.save(
            EarlierDiskCache(schemaVersion: 1, graphs: ["abc": graph]),
            fileName: name
        ))

        let loaded = await TransactionGraphCache(storage: storage).graph(
            profileID: profileID,
            transactionID: "abc"
        )
        XCTAssertEqual(loaded, graph)
    }

    @MainActor
    func testCopyToastShowsFirstAndLastSixCharacters() {
        let feedback = CopyFeedbackCenter()

        feedback.showCopied("kaspa:exampleaddress1234")

        XCTAssertEqual(feedback.message, "Address exampl...ss1234 copied")
    }

    func testCompactKpubPayloadAcceptsExactM5Format() throws {
        var raw = [UInt8](repeating: 0, count: 78)
        raw.replaceSubrange(0..<4, with: [0x03, 0x8f, 0x33, 0x2e])
        raw[4] = 3
        raw.replaceSubrange(9..<13, with: [0x80, 0x00, 0x00, 0x00])
        raw[45] = 0x02
        let payload = [UInt8(0x01)] + raw
        let payloadHex = payload.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(
            try KpubQRPayload.rawKpubHex(from: payloadHex),
            raw.map { String(format: "%02x", $0) }.joined()
        )
    }

    func testCompactKpubPayloadRejectsPrivateOrUnknownFormats() {
        var raw = [UInt8](repeating: 0, count: 78)
        raw.replaceSubrange(0..<4, with: [0x03, 0x8f, 0x33, 0x2e])
        raw[4] = 3
        raw.replaceSubrange(9..<13, with: [0x80, 0x00, 0x00, 0x00])
        raw[45] = 0x02

        func hex(_ bytes: [UInt8]) -> String {
            bytes.map { String(format: "%02x", $0) }.joined()
        }

        XCTAssertThrowsError(
            try KpubQRPayload.rawKpubHex(from: hex([0x02] + raw))
        )

        var wrongVersion = raw
        wrongVersion[0] = 0x04
        XCTAssertThrowsError(
            try KpubQRPayload.rawKpubHex(from: hex([0x01] + wrongVersion))
        )

        XCTAssertThrowsError(
            try KpubQRPayload.rawKpubHex(
                from: hex([0x01] + Array(raw.dropLast()))
            )
        )
    }

    @MainActor
    func testCompactKpubUsesStandardBundledImporter() async throws {
        let engine = KasSignerEngine()
        _ = engine.attachedWebView()
        let raw =
            "038f332e" + "03" + "00000000" + "80000000" +
            String(repeating: "01", count: 32) +
            "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        let canonicalKpub = try KpubQRPayload.canonicalKpub(
            from: "01" + raw
        )
        let imported = try await engine.importKpub(canonicalKpub)

        XCTAssertTrue(canonicalKpub.hasPrefix("kpub"))
        XCTAssertTrue(imported.kpub.hasPrefix("kpub"))
        XCTAssertFalse(imported.receiveAddresses.isEmpty)
        XCTAssertFalse(imported.changeAddresses.isEmpty)
    }

    @MainActor
    func testCompactKpubFramesReassembleOutOfOrderWithoutEarlyImport() async throws {
        let engine = KasSignerEngine()
        _ = engine.attachedWebView()
        let rawHex =
            "038f332e" + "03" + "00000000" + "80000000" +
            String(repeating: "01", count: 32) +
            "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        let payloadHex = "01" + rawHex
        let payload = stride(from: 0, to: payloadHex.count, by: 2).map { offset in
            let start = payloadHex.index(payloadHex.startIndex, offsetBy: offset)
            let end = payloadHex.index(start, offsetBy: 2)
            return UInt8(payloadHex[start..<end], radix: 16)!
        }
        let digest = Array(SHA256.hash(data: Data(payload)))
        func frame(index: UInt8, fragment: ArraySlice<UInt8>) -> String {
            var bytes: [UInt8] = [0x4b, 0x51, 0x02, 0x02]
            bytes += digest[16..<24]
            bytes += [UInt8(payload.count >> 8), UInt8(payload.count & 0xff)]
            bytes += digest[0..<16]
            bytes += [index, 0x02, UInt8(fragment.count)]
            bytes += fragment
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        let firstFrame = frame(index: 0, fragment: payload[0..<40])
        let secondFrame = frame(index: 1, fragment: payload[40..<79])

        try await engine.resetQRDecoder()
        let incomplete = try await engine.decodeQRFrame(secondFrame)
        XCTAssertNil(incomplete)
        let duplicate = try await engine.decodeQRFrame(secondFrame)
        XCTAssertNil(duplicate)
        let completed = try await engine.decodeQRFrame(firstFrame)

        XCTAssertEqual(completed, payloadHex)
        let canonical = try KpubQRPayload.canonicalKpub(
            from: XCTUnwrap(completed)
        )
        let imported = try await engine.importKpub(canonical)
        XCTAssertTrue(imported.kpub.hasPrefix("kpub"))
    }

    @MainActor
    func testStrictSignedReturnVerifierIsAvailableThroughBundledWebAssembly() async {
        let engine = KasSignerEngine()
        let firstWebView = engine.attachedWebView()

        do {
            _ = try await engine.verifyAndMergeSignedKSPTIntoPSKB(
                signedKSPTHex: "00",
                originalRelayKSPTHex: "00",
                originalPSKBHex: "00"
            )
            XCTFail("Malformed KSPT input unexpectedly passed verification.")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "KSPT truncated: want 4 bytes at pos 0, only 1 remain"
            )
        }

        do {
            _ = try await engine.verifyAndMergeSignedKSPTIntoPSKB(
                signedKSPTHex: "4b5350540101",
                originalRelayKSPTHex: "00",
                originalPSKBHex: "00"
            )
            XCTFail("Truncated M5 KSPT v1 input unexpectedly passed verification.")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "KSPT truncated: want 2 bytes at pos 6, only 0 remain"
            )
        }

        let secondEngine = KasSignerEngine()
        let secondWebView = secondEngine.attachedWebView()
        do {
            _ = try await secondEngine.verifyAndMergeSignedKSPTIntoPSKB(
                signedKSPTHex: "00",
                originalRelayKSPTHex: "00",
                originalPSKBHex: "00"
            )
            XCTFail("Malformed KSPT input unexpectedly passed verification.")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "KSPT truncated: want 4 bytes at pos 0, only 1 remain"
            )
        }

        XCTAssertNotEqual(firstWebView.url, secondWebView.url)
    }

    func testVerifiedSignedPSKBGateArmsOnlyAfterAcceptance() {
        var gate = VerifiedSignedPSKBGate()
        XCTAssertFalse(gate.isArmed)
        XCTAssertNil(gate.payload)

        gate.accept("verified-pskb")

        XCTAssertTrue(gate.isArmed)
        XCTAssertEqual(gate.payload, "verified-pskb")
    }

    func testVerifiedSignedPSKBGateClearsPreviouslyAcceptedPayload() {
        var gate = VerifiedSignedPSKBGate()
        gate.accept("previously-verified-pskb")

        gate.clear()

        XCTAssertFalse(gate.isArmed)
        XCTAssertNil(gate.payload)
    }

    private let portfolioID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testSompiFormattingUsesSelectedDecimalPlaces() {
        XCTAssertEqual(
            KasBalanceFormatter.string(fromSompi: 2_550_000_000, decimalPlaces: .zero),
            "26"
        )
        XCTAssertEqual(
            KasBalanceFormatter.string(fromSompi: 2_550_000_000, decimalPlaces: .two),
            "25.50"
        )
        XCTAssertEqual(
            KasBalanceFormatter.string(fromSompi: 2_500_000_000, decimalPlaces: .four),
            "25.0000"
        )
    }

    @MainActor
    func testBroadcastTransactionPublishesImmediately() {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let suiteName = "KasSignerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let store = WalletStore(
            protectedStorage: ProtectedWalletStorage(directoryURL: root),
            defaults: defaults,
            transactionCacheDirectoryURL: root.appending(path: "history", directoryHint: .isDirectory)
        )
        let profileID = UUID()
        let transactionID = String(repeating: "a", count: 64)

        store.recordBroadcastedTransaction(
            profileID: profileID,
            transactionID: transactionID,
            destination: "kaspa:testdestination",
            amountSompi: 100_000_000,
            feeSompi: 1_000
        )

        XCTAssertEqual(store.pendingTransactions.count, 1)
        XCTAssertEqual(store.pendingTransactions.first?.transactionID, transactionID)
        XCTAssertTrue(store.transactions.contains {
            $0.profileID == profileID && $0.transactionID == transactionID
        })
    }

    @MainActor
    func testOutOfOrderChangeAddressIsMarkedUsedWithoutMovingCursorBackward() throws {
        let fixture = try IsolatedWalletStoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        let profileID = UUID()
        let changeAddresses = (0..<6).map { "kaspa:change-\($0)" }
        store.add(
            WalletProfile(
                id: profileID,
                name: "Change Address Test",
                kpub: "kpub-test",
                changeAddresses: changeAddresses,
                nextChangeIndex: 5
            )
        )

        store.recordBroadcastedTransaction(
            profileID: profileID,
            transactionID: String(repeating: "d", count: 64),
            destination: "kaspa:destination",
            amountSompi: 100_000_000,
            feeSompi: 1_000,
            committedChangeIndices: [1]
        )

        XCTAssertTrue(
            store.isChangeAddressLocallyUsed(changeAddresses[1], profileID: profileID)
        )
        XCTAssertEqual(
            store.profiles.first(where: { $0.id == profileID })?.nextChangeIndex,
            5
        )

        if let index = store.profiles.firstIndex(where: { $0.id == profileID }) {
            store.remove(at: IndexSet(integer: index))
        }
    }

    @MainActor
    func testNonContiguousChangeAddressesAreAllMarkedUsedAndAdvanceCursor() throws {
        let fixture = try IsolatedWalletStoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        let profileID = UUID()
        let changeAddresses = (0..<6).map { "kaspa:change-\($0)" }
        store.add(
            WalletProfile(
                id: profileID,
                name: "Multiple Change Address Test",
                kpub: "kpub-test",
                changeAddresses: changeAddresses,
                nextChangeIndex: 1
            )
        )

        let recorded = store.recordBroadcastedTransaction(
            profileID: profileID,
            transactionID: String(repeating: "e", count: 64),
            destination: "kaspa:destination",
            amountSompi: 100_000_000,
            feeSompi: 1_000,
            committedChangeIndices: [1, 3, 5]
        )

        XCTAssertTrue(recorded)
        XCTAssertTrue(store.isChangeAddressLocallyUsed(changeAddresses[1], profileID: profileID))
        XCTAssertTrue(store.isChangeAddressLocallyUsed(changeAddresses[3], profileID: profileID))
        XCTAssertTrue(store.isChangeAddressLocallyUsed(changeAddresses[5], profileID: profileID))
        XCTAssertFalse(store.isChangeAddressLocallyUsed(changeAddresses[2], profileID: profileID))
        XCTAssertFalse(store.isChangeAddressLocallyUsed(changeAddresses[4], profileID: profileID))
        XCTAssertEqual(
            store.profiles.first(where: { $0.id == profileID })?.nextChangeIndex,
            6
        )
    }

    @MainActor
    func testInvalidChangeIndexRejectsBroadcastRecordWithoutPartialMarking() throws {
        let fixture = try IsolatedWalletStoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        let profileID = UUID()
        let changeAddresses = (0..<3).map { "kaspa:change-\($0)" }
        store.add(
            WalletProfile(
                id: profileID,
                name: "Invalid Change Address Test",
                kpub: "kpub-test",
                changeAddresses: changeAddresses,
                nextChangeIndex: 0
            )
        )

        let recorded = store.recordBroadcastedTransaction(
            profileID: profileID,
            transactionID: String(repeating: "f", count: 64),
            destination: "kaspa:destination",
            amountSompi: 100_000_000,
            feeSompi: 1_000,
            committedChangeIndices: [0, 4]
        )

        XCTAssertFalse(recorded)
        XCTAssertFalse(store.isChangeAddressLocallyUsed(changeAddresses[0], profileID: profileID))
        XCTAssertEqual(
            store.profiles.first(where: { $0.id == profileID })?.nextChangeIndex,
            0
        )
    }

    func testAutoSplitPreservesExactTotalAndMinimumAcrossRepeatedRuns() throws {
        let minimum: UInt64 = 66_900
        let available: UInt64 = 42_000_000_000
        let outputs = (0..<4).map {
            PlannedChangeOutput(
                addressIndex: $0,
                address: "kaspa:change-\($0)",
                amountSompi: 0
            )
        }

        for _ in 0..<128 {
            let split = try ChangeOutputPlanner.autoSplit(
                availableChangeSompi: available,
                selectedOutputs: outputs,
                minimumOutputSompi: minimum
            )

            XCTAssertEqual(split.count, outputs.count)
            XCTAssertTrue(split.allSatisfy { $0.amountSompi >= minimum })
            XCTAssertEqual(
                split.reduce(UInt64(0)) { $0 + $1.amountSompi },
                available
            )
        }
    }

    func testAutoSplitRejectsDuplicateAddresses() {
        let outputs = [
            PlannedChangeOutput(
                addressIndex: 0,
                address: "kaspa:duplicate",
                amountSompi: 0
            ),
            PlannedChangeOutput(
                addressIndex: 1,
                address: " KASPA:DUPLICATE ",
                amountSompi: 0
            )
        ]

        XCTAssertThrowsError(
            try ChangeOutputPlanner.autoSplit(
                availableChangeSompi: 1_000_000,
                selectedOutputs: outputs,
                minimumOutputSompi: 66_900
            )
        ) { error in
            XCTAssertEqual(
                error as? ChangeOutputPlanningError,
                .duplicateAddress
            )
        }
    }

    func testAutoSplitRejectsInsufficientChangeWithoutOverflow() {
        let outputs = (0..<4).map {
            PlannedChangeOutput(
                addressIndex: $0,
                address: "kaspa:change-\($0)",
                amountSompi: 0
            )
        }

        XCTAssertThrowsError(
            try ChangeOutputPlanner.autoSplit(
                availableChangeSompi: 267_599,
                selectedOutputs: outputs,
                minimumOutputSompi: 66_900
            )
        ) { error in
            XCTAssertEqual(
                error as? ChangeOutputPlanningError,
                .insufficientChange
            )
        }
    }

    @MainActor
    func testBroadcastToOwnedReceiveAddressMarksItUsedImmediately() throws {
        let fixture = try IsolatedWalletStoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        let profileID = UUID()
        let receiveAddress = "kaspa:owned-receive-address"
        store.add(
            WalletProfile(
                id: profileID,
                name: "Receive Address Test",
                kpub: "kpub-test",
                receiveAddresses: [receiveAddress]
            )
        )

        store.recordBroadcastedTransaction(
            profileID: profileID,
            transactionID: String(repeating: "e", count: 64),
            destination: receiveAddress,
            amountSompi: 100_000_000,
            feeSompi: 1_000
        )

        XCTAssertTrue(
            store.isReceiveAddressLocallyUsed(receiveAddress, profileID: profileID)
        )

        if let index = store.profiles.firstIndex(where: { $0.id == profileID }) {
            store.remove(at: IndexSet(integer: index))
        }
    }

    @MainActor
    func testKnownWalletBroadcastPreservesInternalTransferAmountWhenConfirmed() {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let suiteName = "KasSignerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let store = WalletStore(
            protectedStorage: ProtectedWalletStorage(directoryURL: root),
            defaults: defaults,
            transactionCacheDirectoryURL: root.appending(path: "history", directoryHint: .isDirectory)
        )
        let profileID = UUID()
        let internalAddress = "kaspa:internal"
        let transactionID = String(repeating: "b", count: 64)
        let profile = WalletProfile(
            id: profileID,
            name: "Internal Transfer Test",
            kpub: "kpub-test",
            receiveAddresses: [internalAddress]
        )
        store.add(profile)

        store.recordBroadcastedTransaction(
            profileID: profileID,
            transactionID: transactionID,
            destination: internalAddress,
            amountSompi: 250_000_000,
            feeSompi: 1_000
        )

        XCTAssertEqual(store.pendingTransactions.first?.kind, .internalTransfer)
        XCTAssertEqual(store.pendingTransactions.first?.destination, "Internal Transfer")
        XCTAssertEqual(store.pendingTransactions.first?.amountSompi, 250_000_000)

        store.mergeSyncedTransactions(
            [
                WalletTransaction(
                    profileID: profileID,
                    transactionID: transactionID,
                    destination: "Self transfer",
                    amountSompi: 0,
                    feeSompi: 1_000,
                    broadcastAt: Date(),
                    direction: .sent,
                    status: .confirmed
                )
            ],
            profileID: profileID
        )

        let confirmed = store.transactions.first { $0.transactionID == transactionID }
        XCTAssertEqual(confirmed?.kind, .internalTransfer)
        XCTAssertEqual(confirmed?.destination, "Internal Transfer")
        XCTAssertEqual(confirmed?.amountSompi, 250_000_000)
        XCTAssertEqual(confirmed?.status, .confirmed)
    }

    @MainActor
    func testLocallyBroadcastTransferToUncachedWalletAddressBecomesInternalWhenConfirmed() throws {
        let fixture = try IsolatedWalletStoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        let profileID = UUID()
        let transactionID = String(repeating: "c", count: 64)
        let profile = WalletProfile(
            id: profileID,
            name: "Uncached Internal Transfer Test",
            kpub: "kpub-test"
        )
        store.add(profile)

        store.recordBroadcastedTransaction(
            profileID: profileID,
            transactionID: transactionID,
            destination: "kaspa:uncached-wallet-address",
            amountSompi: 375_000_000,
            feeSompi: 1_000
        )

        XCTAssertTrue(store.transactions.contains {
            $0.transactionID == transactionID && $0.amountSompi == 375_000_000
        })

        store.mergeResolvedTransactions(
            [
                WalletTransaction(
                    profileID: profileID,
                    transactionID: transactionID,
                    destination: "Self transfer",
                    amountSompi: 0,
                    feeSompi: 1_000,
                    broadcastAt: Date(),
                    direction: .sent,
                    status: .confirmed
                )
            ],
            profileID: profileID
        )

        let confirmed = store.transactions.first { $0.transactionID == transactionID }
        XCTAssertEqual(confirmed?.kind, .internalTransfer)
        XCTAssertEqual(confirmed?.destination, "Internal Transfer")
        XCTAssertEqual(confirmed?.amountSompi, 375_000_000)
        XCTAssertEqual(confirmed?.status, .confirmed)
    }

    @MainActor
    func testAddedUTXOTransactionPublishesImmediately() {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let suiteName = "KasSignerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let store = WalletStore(
            protectedStorage: ProtectedWalletStorage(directoryURL: root),
            defaults: defaults,
            transactionCacheDirectoryURL: root.appending(path: "history", directoryHint: .isDirectory)
        )
        let profileID = UUID()
        let transactionID = String(repeating: "b", count: 64)

        store.recordObservedUTXOTransactions(
            profileID: profileID,
            addedUTXOs: [
                WalletUTXO(
                    txID: transactionID,
                    index: 0,
                    amount: 75_000_000,
                    scriptPublicKey: [],
                    blockDAAScore: 1,
                    covenantID: nil
                ),
                WalletUTXO(
                    txID: transactionID,
                    index: 1,
                    amount: 25_000_000,
                    scriptPublicKey: [],
                    blockDAAScore: 1,
                    covenantID: nil
                )
            ]
        )

        let transaction = store.transactions.first {
            $0.profileID == profileID && $0.transactionID == transactionID
        }
        XCTAssertEqual(transaction?.amountSompi, 100_000_000)
        XCTAssertEqual(transaction?.direction, .received)
        XCTAssertEqual(transaction?.status, .checking)
        XCTAssertEqual(transaction?.confirmationPresentation(currentBlueScore: 1000), .checking)
        XCTAssertNil(transaction?.acceptingBlockBlueScore)
        XCTAssertEqual(store.pendingTransactions.map(\.transactionID), [transactionID])
    }

    func testMultipleBuysUseWeightedAverageCost() {
        let summary = PortfolioHoldingSummary(transactions: [
            transaction(.buy, amount: 100, price: 0.02, offset: 0),
            transaction(.buy, amount: 300, price: 0.04, offset: 60)
        ])

        XCTAssertEqual(summary.holdings, 400, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.costBasis, 14, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.remainingCostBasis, 14, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.averageCost!, 0.035, accuracy: 0.000_000_01)
    }

    func testBuyFeeDoesNotChangeCMCCostBasis() {
        let summary = PortfolioHoldingSummary(transactions: [
            transaction(.buy, amount: 100, price: 0.02, fee: 0.50, offset: 0)
        ])

        XCTAssertEqual(summary.holdings, 100, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.costBasis, 2, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.remainingCostBasis, 2, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.averageCost!, 0.02, accuracy: 0.000_000_01)
    }

    func testPartialSellRemovesWeightedAverageCost() {
        let summary = PortfolioHoldingSummary(transactions: [
            transaction(.buy, amount: 100, price: 0.02, offset: 0),
            transaction(.buy, amount: 300, price: 0.04, offset: 60),
            transaction(.sell, amount: 100, price: 0.05, offset: 120)
        ])

        XCTAssertEqual(summary.holdings, 300, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.costBasis, 14, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.remainingCostBasis, 10.5, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.averageCost!, 0.035, accuracy: 0.000_000_01)
    }

    func testTransferOutRemovesProportionalBasisWithoutCreatingPurchaseCost() {
        let summary = PortfolioHoldingSummary(transactions: [
            transaction(.buy, amount: 100, price: 0.03, offset: 0),
            transaction(.transferIn, amount: 50, price: 0.20, offset: 60),
            transaction(.transferOut, amount: 25, price: 0.50, offset: 120)
        ])

        XCTAssertEqual(summary.holdings, 125, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.costBasis, 3, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.remainingCostBasis, 2.5, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.averageCost!, 0.03, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.totalTransferredIn, 50, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.totalTransferredOut, 25, accuracy: 0.000_000_01)
    }

    func testOversellCannotCreateNegativeHoldingsOrCostBasis() {
        let summary = PortfolioHoldingSummary(transactions: [
            transaction(.buy, amount: 10, price: 0.03, offset: 0),
            transaction(.sell, amount: 20, price: 0.05, offset: 60)
        ])

        XCTAssertEqual(summary.holdings, 0, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.costBasis, 0.3, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.remainingCostBasis, 0, accuracy: 0.000_000_01)
    }

    func testTransferOutCannotMakeLaterHoldingsDisappear() {
        let summary = PortfolioHoldingSummary(transactions: [
            transaction(.transferOut, amount: 20, price: 0, offset: 0),
            transaction(.transferIn, amount: 10, price: 0, offset: 60)
        ])

        XCTAssertEqual(summary.holdings, 10, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.costBasis, 0, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.remainingCostBasis, 0, accuracy: 0.000_000_01)
    }

    func testEqualTimestampsUseCreationOrder() {
        let sameTimestamp = baseDate
        let sellFirst = PortfolioTransaction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            portfolioID: portfolioID,
            type: PortfolioTransactionType.sell.rawValue,
            kasAmount: 10,
            kasPriceUSD: 0.04,
            timestamp: sameTimestamp,
            notes: "",
            createdAt: sameTimestamp
        )
        let buySecond = PortfolioTransaction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            portfolioID: portfolioID,
            type: PortfolioTransactionType.buy.rawValue,
            kasAmount: 10,
            kasPriceUSD: 0.02,
            timestamp: sameTimestamp,
            notes: "",
            createdAt: sameTimestamp.addingTimeInterval(1)
        )

        let summary = PortfolioHoldingSummary(transactions: [buySecond, sellFirst])
        XCTAssertLessThan(sellFirst.createdAt, buySecond.createdAt)
        XCTAssertEqual(
            [buySecond, sellFirst].sorted(by: PortfolioTransactionOrder.ascending).map(\.type),
            [PortfolioTransactionType.sell.rawValue, PortfolioTransactionType.buy.rawValue]
        )
        XCTAssertEqual(summary.holdings, 10, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.costBasis, 0.2, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.remainingCostBasis, 0.2, accuracy: 0.000_000_01)
    }

    func testChartStartsAtFirstTransactionAndNotBefore() {
        let prices = [
            price(0.01, offset: 0),
            price(0.02, offset: 100),
            price(0.03, offset: 200)
        ]
        let buy = transaction(.buy, amount: 100, price: 0.02, offset: 50)

        let points = PortfolioChartBuilder.points(transactions: [buy], prices: prices)

        XCTAssertEqual(points.first?.timestamp, buy.timestamp)
        XCTAssertEqual(points.first!.valueUSD, 1.5, accuracy: 0.000_000_01)
        XCTAssertTrue(points.allSatisfy { $0.timestamp >= buy.timestamp })
    }

    func testChartNeverStartsBeforeEarliestPrice() {
        let transactionBeforeHistory = transaction(
            .buy,
            amount: 100,
            price: 0.005,
            offset: -10_000
        )
        let prices = [
            price(0.01, offset: 0),
            price(0.02, offset: 100)
        ]

        let points = PortfolioChartBuilder.points(
            transactions: [transactionBeforeHistory],
            prices: prices
        )

        XCTAssertEqual(points.first?.timestamp, prices.first?.timestamp)
        XCTAssertTrue(points.allSatisfy { $0.timestamp >= prices[0].timestamp })
    }

    func testChartAppliesTransactionsAtTheirHistoricalTimes() {
        let points = PortfolioChartBuilder.points(
            transactions: [
                transaction(.buy, amount: 100, price: 0.01, offset: -10),
                transaction(.sell, amount: 40, price: 0.03, offset: 150)
            ],
            prices: [
                price(0.02, offset: 0),
                price(0.03, offset: 100),
                price(0.04, offset: 200)
            ]
        )

        XCTAssertEqual(points.count, 5)
        for (actual, expected) in zip(points.map(\.valueUSD), [2, 3, 3.5, 2.1, 2.4]) {
            XCTAssertEqual(actual, expected, accuracy: 0.000001)
        }
        XCTAssertEqual(points[2].timestamp, baseDate.addingTimeInterval(150))
        XCTAssertEqual(points[3].timestamp, baseDate.addingTimeInterval(150))
        XCTAssertEqual(points[2].phase, .beforeTransaction)
        XCTAssertEqual(points[3].phase, .afterTransaction)
    }

    func testChartValueDomainFollowsRealSpreadInsteadOfPortfolioMagnitude() {
        let points = [
            PortfolioChartPoint(timestamp: baseDate, valueUSD: 1_000),
            PortfolioChartPoint(timestamp: baseDate.addingTimeInterval(60), valueUSD: 1_010)
        ]

        let domain = PortfolioChartBuilder.valueDomain(for: points)

        XCTAssertEqual(domain.lowerBound, 998.8, accuracy: 0.000_000_01)
        XCTAssertEqual(domain.upperBound, 1_011.2, accuracy: 0.000_000_01)
    }

    func testChartValueDomainDoesNotForceOneDollarRangeForSmallPortfolio() {
        let points = [
            PortfolioChartPoint(timestamp: baseDate, valueUSD: 0.10),
            PortfolioChartPoint(timestamp: baseDate.addingTimeInterval(60), valueUSD: 0.11)
        ]

        let domain = PortfolioChartBuilder.valueDomain(for: points)

        XCTAssertLessThan(domain.upperBound - domain.lowerBound, 0.02)
        XCTAssertGreaterThan(domain.upperBound, 0.11)
        XCTAssertLessThan(domain.lowerBound, 0.10)
    }

    func testDownsamplingPreservesEndpointsAndExtremes() {
        let points = (0..<20).map { index in
            PortfolioChartPoint(
                timestamp: baseDate.addingTimeInterval(Double(index)),
                valueUSD: index == 9 ? 1_000 : Double(index)
            )
        }

        let sampled = PortfolioChartBuilder.downsampled(points, maximumCount: 8)

        XCTAssertEqual(sampled.first, points.first)
        XCTAssertEqual(sampled.last, points.last)
        XCTAssertTrue(sampled.contains(where: { $0.valueUSD == 1_000 }))
    }

    func testBundledHistoryParserValidatesAndOrdersCandles() throws {
        let csv = """
        timestamp,open,high,low,close
        2022-06-02T23:59:59.999Z,0.2,0.4,0.1,0.3
        2022-06-01T23:59:59.999Z,0.1,0.3,0.05,0.2
        """

        let candles = try HistoricalPriceCacheStore.parseBundledCSV(Data(csv.utf8))

        XCTAssertEqual(candles.count, 2)
        XCTAssertLessThan(candles[0].timestamp, candles[1].timestamp)
        XCTAssertEqual(candles[0].closeUSD, 0.2, accuracy: 0.000_000_01)
    }

    func testBundledHistoryParserRejectsDuplicateTimestamps() {
        let csv = """
        timestamp,open,high,low,close
        2022-06-01T23:59:59.999Z,0.1,0.3,0.05,0.2
        2022-06-01T23:59:59.999Z,0.1,0.3,0.05,0.2
        """

        XCTAssertThrowsError(
            try HistoricalPriceCacheStore.parseBundledCSV(Data(csv.utf8))
        )
    }

    func testPackagedHistoryHasExpectedHardBoundary() throws {
        let candles = try HistoricalPriceCacheStore.bundledCandles()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        XCTAssertEqual(candles.count, 1_535)
        XCTAssertEqual(
            candles.first?.timestamp,
            formatter.date(from: "2022-06-01T23:59:59.999Z")
        )
        XCTAssertEqual(
            candles.last?.timestamp,
            formatter.date(from: "2026-08-13T23:59:59.999Z")
        )
    }

    func testHistoricalDiskCacheRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")
        let cache = HistoricalPriceDiskCache(
            schemaVersion: HistoricalPriceCacheStore.schemaVersion,
            bundledVersion: HistoricalPriceCacheStore.bundledVersion,
            dailyCandles: [
                DailyPriceCandle(
                    timestamp: baseDate,
                    openUSD: 0.01,
                    highUSD: 0.03,
                    lowUSD: 0.005,
                    closeUSD: 0.02
                )
            ],
            hourlyPoints: [price(0.025, offset: 60)],
            lastRefreshAttemptDayUTC: "2026-08-14"
        )

        try HistoricalPriceCacheStore.save(cache, to: url)
        XCTAssertEqual(HistoricalPriceCacheStore.load(from: url), cache)
    }

    func testPortfolioCSVImportParsesQuotedAmountsAndFixedTimezone() throws {
        let csv = """
        Date (UTC-4:00),Token,Type,Price (USD),Amount,Total value (USD),Fee,Fee Currency,Notes
        "2026-03-04 11:40:00","KAS","buy","0.03202","1,178.32","37.73","0.","USD","Fold rewards, converted"
        """
        let now = ISO8601DateFormatter().date(from: "2026-08-14T12:00:00Z")!

        let preview = try PortfolioCSVImporter.preview(
            data: Data(csv.utf8),
            fileName: "transactions.csv",
            portfolioID: portfolioID,
            existingTransactions: [],
            now: now
        )

        XCTAssertEqual(preview.transactions.count, 1)
        XCTAssertEqual(preview.transactions[0].kasAmount, 1_178.32, accuracy: 0.000_000_01)
        XCTAssertEqual(preview.transactions[0].kasPriceUSD, 0.03202, accuracy: 0.000_000_01)
        XCTAssertEqual(preview.transactions[0].notes, "Fold rewards, converted")
        XCTAssertEqual(
            preview.transactions[0].timestamp,
            ISO8601DateFormatter().date(from: "2026-03-04T15:40:00Z")
        )
        XCTAssertTrue(preview.issues.isEmpty)
    }

    func testPortfolioCSVImportSkipsExistingAndFileDuplicates() throws {
        let csv = """
        Date (UTC-4:00),Token,Type,Price (USD),Amount,Total value (USD),Fee,Fee Currency,Notes
        2026-06-02 22:30:00,KAS,buy,0.02888,687.02,19.84,0,USD,Fold rewards
        2026-06-02 22:30:00,KAS,buy,0.02888,687.02,19.84,0,USD,Fold rewards
        """
        let timestamp = ISO8601DateFormatter().date(from: "2026-06-03T02:30:00Z")!
        let existing = PortfolioTransaction(
            portfolioID: portfolioID,
            type: PortfolioTransactionType.buy.rawValue,
            kasAmount: 687.02,
            kasPriceUSD: 0.02888,
            timestamp: timestamp,
            notes: "Fold rewards"
        )

        let preview = try PortfolioCSVImporter.preview(
            data: Data(csv.utf8),
            fileName: "transactions.csv",
            portfolioID: portfolioID,
            existingTransactions: [existing],
            now: ISO8601DateFormatter().date(from: "2026-08-14T12:00:00Z")!
        )

        XCTAssertTrue(preview.transactions.isEmpty)
        XCTAssertEqual(preview.duplicateCount, 2)
        XCTAssertTrue(preview.issues.isEmpty)
    }

    func testPortfolioCSVImportAcceptsFeeAndRejectsOversell() throws {
        let csv = """
        Date (UTC-4:00),Token,Type,Price (USD),Amount,Total value (USD),Fee,Fee Currency,Notes
        2026-06-01 12:00:00,KAS,buy,0.03,10,0.30,0,USD,
        2026-06-02 12:00:00,KAS,sell,0.04,20,0.80,0,USD,
        2026-06-03 12:00:00,KAS,buy,0.05,10,0.50,1,USD,
        """

        let preview = try PortfolioCSVImporter.preview(
            data: Data(csv.utf8),
            fileName: "transactions.csv",
            portfolioID: portfolioID,
            existingTransactions: [],
            now: ISO8601DateFormatter().date(from: "2026-08-14T12:00:00Z")!
        )

        XCTAssertEqual(preview.transactions.count, 2)
        XCTAssertEqual(preview.transactions[0].type, .buy)
        XCTAssertEqual(preview.transactions[1].feeUSD, 1)
        XCTAssertEqual(preview.issues.count, 1)
        XCTAssertTrue(preview.issues.contains { $0.message.contains("exceeds holdings") })
    }

    func testPortfolioCSVImportAcceptsCMCTransfersWithoutPurchasePriceOrFee() throws {
        let csv = """
        Date (UTC-4:00),Token,Type,Price (USD),Amount,Total value (USD),Fee,Fee Currency,Notes
        2026-07-05 12:00:00,KAS,transferIn,0,250,7.729,,,Received
        2026-07-05 13:00:00,KAS,transferOut,0,250,7.765,0,KAS,Sent
        """

        let preview = try PortfolioCSVImporter.preview(
            data: Data(csv.utf8),
            fileName: "cmc-transfers.csv",
            portfolioID: portfolioID,
            existingTransactions: [],
            now: ISO8601DateFormatter().date(from: "2026-08-14T12:00:00Z")!
        )

        XCTAssertEqual(preview.transactions.count, 2)
        XCTAssertEqual(preview.transactions[0].type, .transferIn)
        XCTAssertEqual(preview.transactions[0].kasPriceUSD, 7.729 / 250, accuracy: 0.000_000_01)
        XCTAssertEqual(preview.transactions[1].type, .transferOut)
        XCTAssertEqual(preview.transactions[1].kasPriceUSD, 7.765 / 250, accuracy: 0.000_000_01)
        XCTAssertTrue(preview.issues.isEmpty)
    }

    func testPortfolioCSVImportIdentifiesRenamedNumbersDocument() {
        var data = Data([0x50, 0x4b, 0x03, 0x04])
        data.append(Data("Index/Document.iwa".utf8))

        XCTAssertThrowsError(
            try PortfolioCSVImporter.preview(
                data: data,
                fileName: "renamed.csv",
                portfolioID: portfolioID,
                existingTransactions: []
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "This is an Apple Numbers document, not a CSV. In Numbers, choose Export → CSV, then try again."
            )
        }
    }

    func testPortfolioCSVImportParsesNumbersExportCRLFLineEndings() throws {
        let csv = [
            "Date (UTC-4:00),Token,Type,Price (USD),Amount,Total value (USD),Fee,Fee Currency,Notes",
            "2026-08-01 01:25:00,KAS,buy,0.02729,\"1,054.59\",28.78,0,USD,$30 worth of card cash back for KAS"
        ].joined(separator: "\r\n")

        let preview = try PortfolioCSVImporter.preview(
            data: Data(csv.utf8),
            fileName: "numbers-export.csv",
            portfolioID: portfolioID,
            existingTransactions: [],
            now: ISO8601DateFormatter().date(from: "2026-08-14T12:00:00Z")!
        )

        XCTAssertEqual(preview.transactions.count, 1)
        XCTAssertEqual(preview.transactions[0].kasAmount, 1_054.59, accuracy: 0.000_001)
        XCTAssertTrue(preview.issues.isEmpty)
    }

    func testPortfolioCSVExportRoundTripsTransactionsAndEscapesNotes() throws {
        let portfolioID = UUID()
        let later = PortfolioTransaction(
            portfolioID: portfolioID,
            type: PortfolioTransactionType.sell.rawValue,
            kasAmount: 25.5,
            kasPriceUSD: 0.12345678,
            timestamp: ISO8601DateFormatter().date(from: "2026-08-14T16:30:00Z")!,
            notes: "Partial sale, \"summer\"\nlot",
            feeUSD: 1.25
        )
        let earlier = PortfolioTransaction(
            portfolioID: portfolioID,
            type: PortfolioTransactionType.buy.rawValue,
            kasAmount: 100,
            kasPriceUSD: 0.10,
            timestamp: ISO8601DateFormatter().date(from: "2026-08-13T14:00:00Z")!,
            notes: "First lot"
        )

        let exportedData = PortfolioCSVExporter.data(transactions: [later, earlier])
        let exportedText = String(decoding: exportedData, as: UTF8.self)
        XCTAssertTrue(exportedText.hasPrefix("\u{feff}Date (UTC-4:00),Coin,Type"))
        let exportedRows = exportedText.components(separatedBy: "\r\n")
        XCTAssertTrue(exportedRows[1].hasPrefix("2026-08-14 12:30:00"))
        XCTAssertTrue(exportedRows[2].hasPrefix("2026-08-13 10:00:00"))

        let preview = try PortfolioCSVImporter.preview(
            data: exportedData,
            fileName: "export.csv",
            portfolioID: portfolioID,
            existingTransactions: [],
            now: ISO8601DateFormatter().date(from: "2026-08-15T12:00:00Z")!
        )

        XCTAssertEqual(preview.transactions.count, 2)
        XCTAssertEqual(preview.transactions.map(\.type), [.sell, .buy])
        XCTAssertEqual(preview.transactions[0].notes, "Partial sale, \"summer\"\nlot")
        XCTAssertEqual(preview.transactions[0].feeUSD, 1.25, accuracy: 0.000_001)
        XCTAssertTrue(preview.issues.isEmpty)
    }

    func testPortfolioCSVExportCreatesNativeFriendlyFileName() {
        let date = ISO8601DateFormatter().date(from: "2026-08-18T12:00:00Z")!
        XCTAssertEqual(
            PortfolioCSVExporter.suggestedFileName(portfolioName: "Long Term / Wallet", date: date),
            "KasSigner-Long-Term-Wallet-Transactions-2026-08-18"
        )
    }

    func testWalletTransactionCSVExportUsesLocalDatesAndEscapesNotes() {
        let timeZone = TimeZone(secondsFromGMT: -4 * 60 * 60)!
        let earlier = WalletTransactionCSVRecord(
            timestamp: ISO8601DateFormatter().date(from: "2026-08-20T03:40:00Z")!,
            kind: .received,
            priceUSD: 0.029,
            amountKas: 9.85,
            notes: "Gift, \"summer\"\nwallet"
        )
        let later = WalletTransactionCSVRecord(
            timestamp: ISO8601DateFormatter().date(from: "2026-08-21T15:11:00Z")!,
            kind: .sent,
            priceUSD: 0.03,
            amountKas: 28,
            notes: "Payment"
        )

        let data = WalletTransactionCSVExporter.data(
            records: [later, earlier],
            timeZone: timeZone
        )
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("\u{feff}Date (Local Time),Coin,Type,Price (USD),Amount (KAS),Value (USD),Notes\r\n"))
        XCTAssertTrue(text.contains("2026-08-19 23:40:00 -04:00,KAS,Received,0.029,9.85,0.28565"))
        XCTAssertTrue(text.contains("2026-08-21 11:11:00 -04:00,KAS,Sent,0.03,28,0.84,Payment"))
        XCTAssertTrue(text.contains("\"Gift, \"\"summer\"\"\nwallet\""))
        XCTAssertLessThan(
            text.range(of: "Sent")!.lowerBound,
            text.range(of: "Received")!.lowerBound
        )
    }

    func testWalletTransactionCSVExportCreatesWalletSpecificFileName() {
        let date = ISO8601DateFormatter().date(from: "2026-08-21T12:00:00Z")!
        XCTAssertEqual(
            WalletTransactionCSVExporter.suggestedFileName(
                walletName: "Cold / Savings Wallet",
                date: date
            ),
            "KasSigner-Cold-Savings-Wallet-Transactions-2026-08-21"
        )
    }

    func testWalletTransactionCSVExportIncludesInternalTransferValue() {
        let record = WalletTransactionCSVRecord(
            timestamp: ISO8601DateFormatter().date(from: "2026-08-21T15:11:00Z")!,
            kind: .internalTransfer,
            priceUSD: 0.03,
            amountKas: 250,
            notes: "Moved to savings"
        )

        let text = String(
            decoding: WalletTransactionCSVExporter.data(records: [record]),
            as: UTF8.self
        )
        XCTAssertTrue(text.contains(",KAS,Internal Transfer,0.03,250,7.5,Moved to savings"))
    }

    func testLegacyTransactionWithoutAcceptanceEvidenceDecodesAsChecking() throws {
        struct LegacyTransaction: Encodable {
            let id: UUID
            let profileID: UUID
            let transactionID: String
            let destination: String
            let amountSompi: UInt64
            let feeSompi: UInt64
            let broadcastAt: Date
        }

        let legacy = LegacyTransaction(
            id: UUID(),
            profileID: UUID(),
            transactionID: String(repeating: "a", count: 64),
            destination: "kaspa:destination",
            amountSompi: 100,
            feeSompi: 2,
            broadcastAt: baseDate
        )
        let decoded = try JSONDecoder().decode(
            WalletTransaction.self,
            from: JSONEncoder().encode(legacy)
        )

        XCTAssertEqual(decoded.direction, .sent)
        XCTAssertEqual(decoded.kind, .sent)
        XCTAssertEqual(decoded.status, .checking)
        XCTAssertNil(decoded.acceptingBlockBlueScore)
    }

    func testTransactionConfirmationCountUsesTwoHundredFiftyConfirmationThreshold() {
        let transaction = WalletTransaction(
            profileID: UUID(),
            transactionID: String(repeating: "a", count: 64),
            destination: "kaspa:destination",
            amountSompi: 100_000_000,
            feeSompi: 1_000,
            broadcastAt: Date(),
            direction: .sent,
            status: .confirmed,
            acceptingBlockBlueScore: 1_000
        )

        XCTAssertEqual(transaction.confirmationCount(currentBlueScore: 1_000), 0)
        XCTAssertEqual(transaction.confirmationCount(currentBlueScore: 1_249), 249)
        XCTAssertEqual(transaction.confirmationCount(currentBlueScore: 1_250), 250)
        XCTAssertTrue(transaction.needsConfirmationUpdates(currentBlueScore: 1_249))
        XCTAssertFalse(transaction.needsConfirmationUpdates(currentBlueScore: 1_250))
        XCTAssertEqual(
            transaction.confirmationPresentation(currentBlueScore: nil),
            .checking
        )
        XCTAssertEqual(
            transaction.confirmationPresentation(currentBlueScore: 1_249),
            .count(249)
        )
        XCTAssertEqual(
            transaction.confirmationPresentation(currentBlueScore: 1_250),
            .confirmed
        )
        XCTAssertEqual(
            transaction.confirmationPresentation(
                currentBlueScore: 1_250
            ),
            .confirmed
        )
    }

    @MainActor
    func testCachedVirtualBlueScoreIsAvailableBeforeNetworkRefresh() throws {
        let suiteName = "KasSignerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let previousSession = WalletSyncService(defaults: defaults)
        previousSession.rememberVirtualBlueScore(1_250)
        previousSession.rememberVirtualBlueScore(1_249)
        XCTAssertEqual(
            defaults.string(forKey: WalletSyncService.cachedVirtualBlueScoreKey),
            "1250"
        )

        let service = WalletSyncService(defaults: defaults)
        XCTAssertEqual(service.virtualBlueScore, 1_250)

        service.preload(profile: WalletProfile(name: "Cached", kpub: "kpub-test"))
        XCTAssertEqual(service.virtualBlueScore, 1_250)
    }

    @MainActor
    func testLiveBlueScoreDoesNotPublishEveryNotificationAndFlushesOnBackground() throws {
        let suiteName = "KasSignerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = WalletSyncService(defaults: defaults)
        service.observeVirtualBlueScore(1_250)
        XCTAssertEqual(service.virtualBlueScore, 1_250)

        service.observeVirtualBlueScore(1_251)
        service.observeVirtualBlueScore(1_252)
        XCTAssertEqual(service.virtualBlueScore, 1_250)
        XCTAssertEqual(
            defaults.string(forKey: WalletSyncService.cachedVirtualBlueScoreKey),
            "1250"
        )

        service.persistObservedVirtualBlueScore()
        XCTAssertEqual(service.virtualBlueScore, 1_252)
        XCTAssertEqual(
            defaults.string(forKey: WalletSyncService.cachedVirtualBlueScoreKey),
            "1252"
        )
    }

    @MainActor
    func testSinkBlueScoreSubscriptionAndNotificationParsing() {
        let request = KaspaLiveRPCService.sinkBlueScoreSubscriptionRequest(
            requestID: 7
        )
        XCTAssertEqual(
            [UInt8](request),
            [
                1, 7, 0, 0, 0, 0, 0, 0, 0, 3,
                12, 0, 0, 0,
                1, 0, 5, 0, 0, 0,
                2, 0, 0, 0, 1, 0
            ]
        )

        let score: UInt64 = 521_833_464
        var notification = Data([0, 0, 0, 1, 0, 5, 0, 10, 0, 0, 0, 1, 0])
        withUnsafeBytes(of: score.littleEndian) {
            notification.append(contentsOf: $0)
        }
        XCTAssertEqual(
            KaspaLiveRPCService.sinkBlueScore(from: notification),
            score
        )
    }

    func testDiscoveryRetainsFiftyAddressesAfterHighestHistoricalUse() {
        let receive = (0..<512).map { "kaspa:receive-\($0)" }
        let change = (0..<512).map { "kaspa:change-\($0)" }
        let plan = WalletSyncService.discoveryPlan(
            receiveAddresses: receive,
            changeAddresses: change,
            activeAddresses: [receive[65], change[31]],
            currentNextReceiveIndex: 0,
            currentNextChangeIndex: 0
        )

        XCTAssertEqual(plan.receiveCount, 116)
        XCTAssertEqual(plan.changeCount, 82)
        XCTAssertEqual(plan.nextReceiveIndex, 66)
        XCTAssertEqual(plan.nextChangeIndex, 32)
        XCTAssertFalse(plan.reachedSafetyLimit)
    }

    func testDiscoveryFindsActivityAfterAHistoryGap() {
        let receive = (0..<512).map { "kaspa:receive-\($0)" }
        let plan = WalletSyncService.discoveryPlan(
            receiveAddresses: receive,
            changeAddresses: [],
            activeAddresses: [receive[2], receive[107]],
            currentNextReceiveIndex: 0,
            currentNextChangeIndex: 0
        )

        XCTAssertEqual(plan.receiveCount, 158)
        XCTAssertEqual(plan.nextReceiveIndex, 108)
    }

    func testDiscoveryExpandsPastSavedRangeForSpentOnlyActivity() {
        let receive = (0..<512).map { "kaspa:receive-\($0)" }
        let change = (0..<512).map { "kaspa:change-\($0)" }
        // The wallet previously retained only indices 0–49. Historical
        // activity at 70 must still advance coverage even with no UTXO there.
        let plan = WalletSyncService.discoveryPlan(
            receiveAddresses: receive,
            changeAddresses: change,
            activeAddresses: [receive[70]],
            currentNextReceiveIndex: 0,
            currentNextChangeIndex: 0
        )

        XCTAssertEqual(plan.nextReceiveIndex, 71)
        XCTAssertEqual(plan.receiveCount, 121)
        XCTAssertEqual(plan.changeCount, 50)
    }

    func testDiscoveryRetainsFiftyFreshAddressesForUnusedWallet() {
        let receive = (0..<512).map { "kaspa:receive-\($0)" }
        let change = (0..<512).map { "kaspa:change-\($0)" }
        let plan = WalletSyncService.discoveryPlan(
            receiveAddresses: receive,
            changeAddresses: change,
            activeAddresses: [],
            currentNextReceiveIndex: 0,
            currentNextChangeIndex: 0
        )

        XCTAssertEqual(plan.receiveCount, 50)
        XCTAssertEqual(plan.changeCount, 50)
        XCTAssertEqual(plan.nextReceiveIndex, 0)
        XCTAssertEqual(plan.nextChangeIndex, 0)
        XCTAssertFalse(plan.reachedSafetyLimit)
    }

    func testDiscoveryPreservesLocalFrontierAndFiftyAddressBuffer() {
        let receive = (0..<512).map { "kaspa:receive-\($0)" }
        let change = (0..<512).map { "kaspa:change-\($0)" }
        let plan = WalletSyncService.discoveryPlan(
            receiveAddresses: receive,
            changeAddresses: change,
            activeAddresses: [receive[4], change[2]],
            currentNextReceiveIndex: 80,
            currentNextChangeIndex: 40
        )

        XCTAssertEqual(plan.receiveCount, 130)
        XCTAssertEqual(plan.changeCount, 90)
        XCTAssertEqual(plan.nextReceiveIndex, 80)
        XCTAssertEqual(plan.nextChangeIndex, 40)
        XCTAssertFalse(plan.reachedSafetyLimit)
    }

    func testDiscoveryPreservesReservedIndicesAndReportsSafetyLimit() {
        let receive = (0..<512).map { "kaspa:receive-\($0)" }
        let change = (0..<512).map { "kaspa:change-\($0)" }
        let plan = WalletSyncService.discoveryPlan(
            receiveAddresses: receive,
            changeAddresses: change,
            activeAddresses: [receive[500]],
            currentNextReceiveIndex: 507,
            currentNextChangeIndex: 9
        )

        XCTAssertEqual(plan.receiveCount, 512)
        XCTAssertEqual(plan.nextReceiveIndex, 507)
        XCTAssertEqual(plan.nextChangeIndex, 9)
        XCTAssertTrue(plan.reachedSafetyLimit)
    }

    func testLegacyWalletProfileDoesNotUnexpectedlyRequireDiscovery() throws {
        let profile = WalletProfile(
            name: "Legacy",
            kpub: "kpub-test",
            receiveAddresses: ["kaspa:receive"],
            changeAddresses: ["kaspa:change"]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
                as? [String: Any]
        )
        object.removeValue(forKey: "requiresInitialDiscovery")
        object.removeValue(forKey: "requiresInitialHistorySync")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(WalletProfile.self, from: legacyData)

        XCTAssertFalse(decoded.requiresInitialDiscovery)
        XCTAssertFalse(decoded.requiresInitialHistorySync)
    }

    func testHistoricalDiscoveryTimestampPersistsWithoutBreakingOlderProfiles() throws {
        var profile = WalletProfile(name: "Coverage", kpub: "kpub-test")
        let legacyData = try JSONEncoder().encode(profile)
        let legacy = try JSONDecoder().decode(WalletProfile.self, from: legacyData)
        XCTAssertNil(legacy.lastHistoricalDiscoveryAt)

        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        profile.lastHistoricalDiscoveryAt = checkedAt
        let restored = try JSONDecoder().decode(
            WalletProfile.self,
            from: JSONEncoder().encode(profile)
        )
        XCTAssertEqual(restored.lastHistoricalDiscoveryAt, checkedAt)
    }

    func testAcceptedHistoryWaitsForBlueScoreBeforeShowingConfirmed() {
        let profileID = UUID()
        let walletAddress = "kaspa:wallet"
        let indexed = IndexedTransaction(
            transactionID: String(repeating: "b", count: 64),
            blockTime: 1_700_000_000_000,
            isAccepted: true,
            acceptingBlockTime: 1_700_000_001_000,
            acceptingBlockBlueScore: nil,
            inputs: [
                IndexedTransactionInput(
                    previousOutpointAddress: "kaspa:external",
                    previousOutpointAmount: 1_000
                )
            ],
            outputs: [
                IndexedTransactionOutput(
                    amount: 1_000,
                    scriptPublicKeyAddress: walletAddress
                )
            ]
        )

        let transaction = TransactionHistoryClient().mapTransactions(
            [indexed],
            profileID: profileID,
            receiveAddresses: Set([walletAddress]),
            changeAddresses: []
        ).first

        XCTAssertEqual(transaction?.status, .confirmed)
        XCTAssertEqual(transaction?.confirmationPresentation(currentBlueScore: 1000), .checking)
        XCTAssertTrue(transaction?.requiresAcceptanceResolution ?? false)
        XCTAssertNil(transaction?.acceptingBlockBlueScore)
    }

    func testIndexedHistoryMapsIncomingAndOutgoingNetActivity() {
        let profileID = UUID()
        let walletAddress = "kaspa:wallet"
        let externalAddress = "kaspa:external"
        let client = TransactionHistoryClient()
        let incoming = IndexedTransaction(
            transactionID: String(repeating: "1", count: 64),
            blockTime: 1_700_000_000_000,
            isAccepted: true,
            acceptingBlockTime: 1_700_000_001_000,
            acceptingBlockBlueScore: 1_000,
            inputs: [
                IndexedTransactionInput(
                    previousOutpointAddress: externalAddress,
                    previousOutpointAmount: 1_000
                )
            ],
            outputs: [
                IndexedTransactionOutput(amount: 900, scriptPublicKeyAddress: walletAddress),
                IndexedTransactionOutput(amount: 90, scriptPublicKeyAddress: externalAddress)
            ]
        )
        let outgoing = IndexedTransaction(
            transactionID: String(repeating: "2", count: 64),
            blockTime: 1_700_000_002_000,
            isAccepted: true,
            acceptingBlockTime: nil,
            acceptingBlockBlueScore: 1_010,
            inputs: [
                IndexedTransactionInput(
                    previousOutpointAddress: walletAddress,
                    previousOutpointAmount: 1_000
                )
            ],
            outputs: [
                IndexedTransactionOutput(amount: 600, scriptPublicKeyAddress: externalAddress),
                IndexedTransactionOutput(amount: 390, scriptPublicKeyAddress: walletAddress)
            ]
        )

        let transactions = client.mapTransactions(
            [incoming, outgoing, incoming],
            profileID: profileID,
            receiveAddresses: Set([walletAddress]),
            changeAddresses: []
        )

        XCTAssertEqual(transactions.count, 2)
        let received = transactions.first { $0.direction == .received }
        XCTAssertEqual(received?.amountSompi, 900)
        XCTAssertEqual(received?.feeSompi, 0)
        XCTAssertEqual(received?.destination, externalAddress)
        XCTAssertEqual(received?.status, .confirmed)
        XCTAssertEqual(received?.acceptingBlockBlueScore, 1_000)

        let sent = transactions.first { $0.direction == .sent }
        XCTAssertEqual(sent?.amountSompi, 600)
        XCTAssertEqual(sent?.feeSompi, 10)
        XCTAssertEqual(sent?.destination, externalAddress)
        XCTAssertEqual(sent?.status, .confirmed)
        XCTAssertEqual(sent?.acceptingBlockBlueScore, 1_010)
    }

    func testIndexedHistoryMapsInternalDestinationSeparatelyFromChange() {
        let profileID = UUID()
        let inputAddress = "kaspa:qz5esder"
        let internalReceiveAddress = "kaspa:qq47r9e5"
        let changeAddress = "kaspa:qq0ycwwa"
        let client = TransactionHistoryClient()
        let indexed = IndexedTransaction(
            transactionID: "c29d9dc3f1ce740b9c743563483a5d0d9ab214358faa7bb7cb25bbb1d7d6b986",
            blockTime: 1_787_763_994_363,
            isAccepted: true,
            acceptingBlockTime: 1_787_763_994_583,
            acceptingBlockBlueScore: 2_000,
            inputs: [
                IndexedTransactionInput(
                    previousOutpointAddress: inputAddress,
                    previousOutpointAmount: 30_905_800_294
                )
            ],
            outputs: [
                IndexedTransactionOutput(
                    amount: 2_400_000_000,
                    scriptPublicKeyAddress: internalReceiveAddress
                ),
                IndexedTransactionOutput(
                    amount: 28_505_471_694,
                    scriptPublicKeyAddress: changeAddress
                )
            ]
        )

        let transaction = client.mapTransactions(
            [indexed],
            profileID: profileID,
            receiveAddresses: Set([inputAddress, internalReceiveAddress]),
            changeAddresses: Set([changeAddress])
        ).first

        XCTAssertEqual(transaction?.kind, .internalTransfer)
        XCTAssertEqual(transaction?.destination, "Internal Transfer")
        XCTAssertEqual(transaction?.amountSompi, 2_400_000_000)
        XCTAssertEqual(transaction?.feeSompi, 328_600)
    }

    func testOldDatedManualTransactionUsesHistoricalPriceInsteadOfLivePrice() {
        let oldTransactionDate = baseDate.addingTimeInterval(30)
        let now = baseDate.addingTimeInterval(86_400 * 30)
        let resolvedPrice = PortfolioTransactionPriceResolver.automaticPrice(
            at: oldTransactionDate,
            now: now,
            livePrice: 9.99,
            historicalPrices: [
                price(0.01, offset: 0),
                price(0.03, offset: 60)
            ],
            calendar: utcCalendar
        )

        XCTAssertEqual(resolvedPrice!, 0.02, accuracy: 0.000_000_01)
    }

    func testCurrentDatedManualTransactionUsesLivePrice() {
        let now = baseDate.addingTimeInterval(3_600)
        let resolvedPrice = PortfolioTransactionPriceResolver.automaticPrice(
            at: baseDate,
            now: now,
            livePrice: 0.0255,
            historicalPrices: [price(9.99, offset: 0)],
            calendar: utcCalendar
        )

        XCTAssertEqual(resolvedPrice!, 0.0255, accuracy: 0.000_000_01)
    }

    func testProtectedWalletStorageUsesCompleteProtectionAndBackupExclusion() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ProtectedWalletStorage(directoryURL: root)
        let payload = ["kaspa:receive", "kaspa:change"]

        XCTAssertTrue(storage.save(payload, fileName: "test.json"))
        XCTAssertEqual(
            storage.load([String].self, fileName: "test.json"),
            payload
        )

        let fileURL = root.appending(path: "test.json")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        #if targetEnvironment(simulator)
        // CoreSimulator does not expose NSFileProtection attributes even when
        // the write and setAttributes calls succeed. The device build verifies
        // the actual protection class; here we still verify the protected write.
        XCTAssertEqual(try Data(contentsOf: fileURL), try JSONEncoder().encode(payload))
        #else
        XCTAssertEqual(
            attributes[.protectionKey] as? FileProtectionType,
            .complete
        )
        #endif
        XCTAssertEqual(
            try fileURL.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            ).isExcludedFromBackup,
            true
        )
    }

    @MainActor
    func testLegacyWalletMigratesButLegacySigningDraftIsPurged() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let cache = root.appending(path: "history", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "KasSignerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = ProtectedWalletStorage(directoryURL: root)
        let profile = WalletProfile(
            name: "Migrated Wallet",
            kpub: "kpub-migration-test",
            receiveAddresses: ["kaspa:receive"],
            changeAddresses: ["kaspa:change"]
        )
        defaults.set(
            try JSONEncoder().encode([profile]),
            forKey: "kassigner.walletProfiles.v1"
        )
        defaults.set(profile.id.uuidString, forKey: "kassigner.selectedWalletProfile.v1")
        defaults.set(Data("legacy-draft".utf8), forKey: "kassigner.sendSessions.v1")

        let store = WalletStore(
            protectedStorage: storage,
            defaults: defaults,
            transactionCacheDirectoryURL: cache
        )

        XCTAssertEqual(store.profiles, [profile])
        XCTAssertTrue(store.sendSessions.isEmpty)
        XCTAssertTrue(storage.contains(fileName: "wallet-state.json"))
        XCTAssertNil(defaults.object(forKey: "kassigner.walletProfiles.v1"))
        XCTAssertNil(defaults.object(forKey: "kassigner.sendSessions.v1"))

        let relaunchedStore = WalletStore(
            protectedStorage: storage,
            defaults: defaults,
            transactionCacheDirectoryURL: cache
        )
        XCTAssertEqual(relaunchedStore.profiles, [profile])
        XCTAssertTrue(relaunchedStore.sendSessions.isEmpty)
    }

    @MainActor
    func testFailedProtectedMigrationDoesNotDeleteLegacyWallet() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("blocks-directory-creation".utf8).write(to: root)
        let suiteName = "KasSignerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = WalletProfile(
            name: "Legacy Wallet",
            kpub: "kpub-preserved-after-failed-migration"
        )
        defaults.set(
            try JSONEncoder().encode([profile]),
            forKey: "kassigner.walletProfiles.v1"
        )

        let store = WalletStore(
            protectedStorage: ProtectedWalletStorage(directoryURL: root),
            defaults: defaults,
            transactionCacheDirectoryURL: FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        )

        XCTAssertEqual(store.profiles, [profile])
        XCTAssertNotNil(defaults.object(forKey: "kassigner.walletProfiles.v1"))
    }

    @MainActor
    func testAccountDeletionJournalContainsNoSeedAndResumesKeychainCleanup() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "KasSignerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = ProtectedWalletStorage(directoryURL: root)
        var failSeedRemoval = true
        let store = WalletStore(
            protectedStorage: storage,
            defaults: defaults,
            removeTestnetSeed: { _ in
                if failSeedRemoval {
                    failSeedRemoval = false
                    throw NSError(domain: "TestSeedRemoval", code: 1)
                }
            }
        )
        let profile = WalletProfile(
            name: "Deletion journal test",
            kpub: "kpub-deletion-journal-test",
            network: KaspaNetwork.testnet10.rawValue
        )
        XCTAssertTrue(store.add(profile))

        XCTAssertEqual(store.deleteAccount(profileID: profile.id), .seedCleanupPending)
        XCTAssertTrue(store.profiles.contains(where: { $0.id == profile.id }))
        XCTAssertTrue(storage.contains(fileName: "wallet-deletion-intents.json"))
        let journalData = try Data(
            contentsOf: root.appending(path: "wallet-deletion-intents.json")
        )
        let journalJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: journalData) as? [[String: Any]]
        )
        let journalKeys = Set(try XCTUnwrap(journalJSON.first).keys)
        XCTAssertEqual(journalKeys, Set(["profileID", "network"]))

        let relaunchedStore = WalletStore(
            protectedStorage: storage,
            defaults: defaults,
            removeTestnetSeed: { _ in }
        )
        XCTAssertTrue(relaunchedStore.resumePendingAccountDeletions())
        XCTAssertFalse(storage.contains(fileName: "wallet-deletion-intents.json"))
        XCTAssertFalse(relaunchedStore.profiles.contains(where: { $0.id == profile.id }))
        XCTAssertNil(relaunchedStore.accountDeletionRecoveryMessage)
    }

    @MainActor
    func testAccountDeletionRemovesSeedBeforeRetryingFailedProfileWrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "KasSignerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var seedRemovalCount = 0
        let store = WalletStore(
            protectedStorage: ProtectedWalletStorage(directoryURL: root),
            defaults: defaults,
            removeTestnetSeed: { _ in seedRemovalCount += 1 }
        )
        let profile = WalletProfile(
            name: "Failed deletion test",
            kpub: "kpub-failed-deletion-test",
            network: KaspaNetwork.testnet10.rawValue
        )
        XCTAssertTrue(store.add(profile))

        let stateURL = root.appending(path: "wallet-state.json")
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)

        XCTAssertEqual(store.deleteAccount(profileID: profile.id), .profilePersistenceFailed)
        XCTAssertTrue(store.profiles.contains(where: { $0.id == profile.id }))
        XCTAssertEqual(seedRemovalCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appending(path: "wallet-deletion-intents.json").path
        ))
    }

    @MainActor
    func testSendSessionsAreFreshMemoryOnlyAndRejectStaleUpdates() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let cache = root.appending(path: "history", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "KasSignerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = ProtectedWalletStorage(directoryURL: root)
        let store = WalletStore(
            protectedStorage: storage,
            defaults: defaults,
            transactionCacheDirectoryURL: cache
        )
        let profile = WalletProfile(
            name: "Session Wallet",
            kpub: "kpub-session-test",
            changeAddresses: ["kaspa:change"]
        )
        store.add(profile)
        let utxo = WalletUTXO(
            txID: String(repeating: "a", count: 64),
            index: 0,
            amount: 100_000_000,
            scriptPublicKey: [0x20],
            blockDAAScore: 1,
            covenantID: nil
        )

        var first = try XCTUnwrap(
            store.beginSendSession(profileID: profile.id, selectedUTXOs: [utxo])
        )
        let second = try XCTUnwrap(
            store.beginSendSession(profileID: profile.id, selectedUTXOs: [utxo])
        )
        XCTAssertNotEqual(first.id, second.id)

        first.destination = "kaspa:stale-destination"
        store.updateSendSession(first)
        XCTAssertEqual(
            store.sendSession(id: second.id, profileID: profile.id)?.destination,
            ""
        )

        store.cancelSendSession(id: second.id, profileID: profile.id)
        XCTAssertNil(store.sendSession(id: second.id, profileID: profile.id))

        let relaunchedStore = WalletStore(
            protectedStorage: storage,
            defaults: defaults,
            transactionCacheDirectoryURL: cache
        )
        XCTAssertTrue(relaunchedStore.sendSessions.isEmpty)
        XCTAssertEqual(relaunchedStore.profiles, [profile])
    }

    @MainActor
    func testSendSessionTransactionTypesSelectRequiredFreshChangeAddresses() throws {
        let fixture = try IsolatedWalletStoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        let profile = WalletProfile(
            name: "Mode Wallet",
            kpub: "kpub-mode-test",
            changeAddresses: (0..<6).map { "kaspa:change-\($0)" },
            nextChangeIndex: 1
        )
        store.add(profile)
        let utxo = WalletUTXO(
            txID: String(repeating: "b", count: 64),
            index: 0,
            amount: 1_000_000_000,
            scriptPublicKey: [0x20],
            blockDAAScore: 1,
            covenantID: nil
        )

        let standard = try XCTUnwrap(store.beginSendSession(
            profileID: profile.id,
            selectedUTXOs: [utxo],
            transactionType: .standard
        ))
        XCTAssertEqual(standard.transactionType, .standard)
        XCTAssertEqual(standard.changeOutputs.map(\.addressIndex), [1])

        let privacy = try XCTUnwrap(store.beginSendSession(
            profileID: profile.id,
            selectedUTXOs: [utxo],
            transactionType: .privacyFocused
        ))
        XCTAssertEqual(privacy.transactionType, .privacyFocused)
        XCTAssertEqual(privacy.changeOutputs.map(\.addressIndex), [1, 2])

        let decoy = try XCTUnwrap(store.beginSendSession(
            profileID: profile.id,
            selectedUTXOs: [utxo],
            transactionType: .decoy
        ))
        XCTAssertEqual(decoy.transactionType, .decoy)
        XCTAssertEqual(decoy.changeOutputs.map(\.addressIndex), [1, 2, 3, 4])
    }

    @MainActor
    func testImportedWalletIsNotPersistedUntilDiscoveryCommits() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let cache = root.appending(path: "history", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "KasSignerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = ProtectedWalletStorage(directoryURL: root)
        let completed = WalletProfile(name: "Completed", kpub: "kpub-completed")
        let pending = WalletProfile(
            name: "Pending",
            kpub: "kpub-pending",
            requiresInitialDiscovery: true,
            requiresInitialHistorySync: true
        )
        let store = WalletStore(
            protectedStorage: storage,
            defaults: defaults,
            transactionCacheDirectoryURL: cache
        )
        store.add(completed)
        store.beginPendingImport(pending)

        XCTAssertEqual(store.selectedProfile, pending)
        XCTAssertEqual(store.profiles, [completed])

        let relaunchedBeforeCommit = WalletStore(
            protectedStorage: storage,
            defaults: defaults,
            transactionCacheDirectoryURL: cache
        )
        XCTAssertEqual(relaunchedBeforeCommit.profiles, [completed])
        XCTAssertEqual(relaunchedBeforeCommit.selectedProfile, completed)

        var discovered = pending
        discovered.requiresInitialDiscovery = false
        store.commitPendingImport(discovered)

        let relaunchedAfterCommit = WalletStore(
            protectedStorage: storage,
            defaults: defaults,
            transactionCacheDirectoryURL: cache
        )
        XCTAssertEqual(relaunchedAfterCommit.profiles, [completed, discovered])
        XCTAssertEqual(relaunchedAfterCommit.selectedProfile, discovered)
        XCTAssertTrue(relaunchedAfterCommit.selectedProfile?.requiresInitialHistorySync == true)

        var historyComplete = discovered
        historyComplete.requiresInitialHistorySync = false
        store.update(historyComplete)

        let relaunchedAfterHistory = WalletStore(
            protectedStorage: storage,
            defaults: defaults,
            transactionCacheDirectoryURL: cache
        )
        XCTAssertFalse(relaunchedAfterHistory.selectedProfile?.requiresInitialHistorySync ?? true)
    }

    @MainActor
    func testInitialHistoryStaysHiddenUntilCacheSaveSucceedsAndRetrySurvivesRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let cache = root.appending(path: "history", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "KasSignerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("blocks-cache-directory".utf8).write(to: cache)
        let store = WalletStore(
            protectedStorage: ProtectedWalletStorage(directoryURL: root),
            defaults: defaults,
            transactionCacheDirectoryURL: cache
        )
        let profile = WalletProfile(
            name: "History Retry",
            kpub: "kpub-history-retry",
            requiresInitialHistorySync: true
        )
        store.add(profile)

        let transaction = WalletTransaction(
            profileID: profile.id,
            transactionID: String(repeating: "a", count: 64),
            destination: "kaspa:receive",
            amountSompi: 100_000_000,
            feeSompi: 0,
            broadcastAt: Date(),
            direction: .received,
            status: .confirmed
        )
        let history = TransactionHistorySyncResult(transactions: [transaction], graphs: [])
        let service = WalletSyncService(defaults: defaults)
        service.preload(profile: profile)

        let didInitiallySave = await service.commitIndexedTransactionHistory(
            history,
            profile: profile,
            walletStore: store
        )
        XCTAssertFalse(didInitiallySave)
        service.completeTransactionHistoryReconciliation(
            profileID: profile.id,
            walletStore: store
        )
        XCTAssertTrue(store.selectedProfile?.requiresInitialHistorySync == true)
        XCTAssertNotNil(service.transactionHistoryError)

        let beforeRetry = WalletStore(
            protectedStorage: ProtectedWalletStorage(directoryURL: root),
            defaults: defaults,
            transactionCacheDirectoryURL: cache
        )
        XCTAssertTrue(beforeRetry.selectedProfile?.requiresInitialHistorySync == true)
        XCTAssertTrue(beforeRetry.transactions.isEmpty)

        try FileManager.default.removeItem(at: cache)
        let didRetryLocally = await service.retryInitialHistoryPersistenceIfNeeded(
            profile: profile,
            walletStore: store
        )
        XCTAssertTrue(didRetryLocally)
        XCTAssertFalse(store.selectedProfile?.requiresInitialHistorySync ?? true)
        XCTAssertNil(service.transactionHistoryError)

        let afterRetry = WalletStore(
            protectedStorage: ProtectedWalletStorage(directoryURL: root),
            defaults: defaults,
            transactionCacheDirectoryURL: cache
        )
        XCTAssertFalse(afterRetry.selectedProfile?.requiresInitialHistorySync ?? true)
        XCTAssertEqual(afterRetry.transactions.map(\.transactionID), [transaction.transactionID])
    }

    @MainActor
    func testInitialHistoryStaysHiddenWhenCompletionStateCannotBeSaved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let cache = root.appending(path: "history", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "KasSignerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WalletStore(
            protectedStorage: ProtectedWalletStorage(directoryURL: root),
            defaults: defaults,
            transactionCacheDirectoryURL: cache
        )
        let profile = WalletProfile(
            name: "Completion Retry",
            kpub: "kpub-completion-retry",
            requiresInitialHistorySync: true
        )
        store.add(profile)
        let service = WalletSyncService(defaults: defaults)
        service.preload(profile: profile)
        let didSaveHistory = await service.commitIndexedTransactionHistory(
            TransactionHistorySyncResult(transactions: [], graphs: []),
            profile: profile,
            walletStore: store
        )
        XCTAssertTrue(didSaveHistory)

        let stateFile = root.appending(path: "wallet-state.json")
        try FileManager.default.removeItem(at: stateFile)
        try FileManager.default.createDirectory(at: stateFile, withIntermediateDirectories: false)
        service.completeTransactionHistoryReconciliation(
            profileID: profile.id,
            walletStore: store
        )
        XCTAssertTrue(store.selectedProfile?.requiresInitialHistorySync == true)
        XCTAssertNotNil(service.transactionHistoryError)

        try FileManager.default.removeItem(at: stateFile)
        let didRetryLocally = await service.retryInitialHistoryPersistenceIfNeeded(
            profile: profile,
            walletStore: store
        )
        XCTAssertTrue(didRetryLocally)
        XCTAssertFalse(store.selectedProfile?.requiresInitialHistorySync ?? true)
        XCTAssertNil(service.transactionHistoryError)

        let relaunched = WalletStore(
            protectedStorage: ProtectedWalletStorage(directoryURL: root),
            defaults: defaults,
            transactionCacheDirectoryURL: cache
        )
        XCTAssertFalse(relaunched.selectedProfile?.requiresInitialHistorySync ?? true)
    }

    @MainActor
    func testHistoricalCoverageAndFreshBufferSurviveWalletStoreRelaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let cache = root.appending(path: "history", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "KasSignerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = ProtectedWalletStorage(directoryURL: root)
        let store = WalletStore(
            protectedStorage: storage,
            defaults: defaults,
            transactionCacheDirectoryURL: cache
        )
        var profile = WalletProfile(name: "Coverage", kpub: "kpub-test")
        store.add(profile)
        profile.receiveAddresses = (0..<121).map { "kaspa:receive-\($0)" }
        profile.changeAddresses = (0..<50).map { "kaspa:change-\($0)" }
        profile.nextReceiveIndex = 71
        profile.lastHistoricalDiscoveryAt = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(store.update(profile))

        let relaunched = WalletStore(
            protectedStorage: storage,
            defaults: defaults,
            transactionCacheDirectoryURL: cache
        )
        XCTAssertEqual(relaunched.selectedProfile, profile)
        XCTAssertEqual(relaunched.selectedProfile?.receiveAddresses.count, 121)
        XCTAssertEqual(relaunched.selectedProfile?.nextReceiveIndex, 71)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func transaction(
        _ type: PortfolioTransactionType,
        amount: Double,
        price: Double,
        fee: Double = 0,
        offset: TimeInterval
    ) -> PortfolioTransaction {
        PortfolioTransaction(
            portfolioID: portfolioID,
            type: type.rawValue,
            kasAmount: amount,
            kasPriceUSD: price,
            timestamp: baseDate.addingTimeInterval(offset),
            notes: "",
            createdAt: baseDate.addingTimeInterval(offset),
            feeUSD: fee
        )
    }

    private func price(_ value: Double, offset: TimeInterval) -> HistoricalPricePoint {
        HistoricalPricePoint(
            timestamp: baseDate.addingTimeInterval(offset),
            priceUSD: value
        )
    }
}


extension PortfolioCalculationsTests {
    func testLiveChartQuoteRefreshPreservesHistoryWithoutAccumulatingEndpoints() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let history = [
            HistoricalPricePoint(timestamp: start, priceUSD: 0.02),
            HistoricalPricePoint(timestamp: start.addingTimeInterval(60), priceUSD: 0.03)
        ]
        let first = ChartLivePriceSeries.points(history: history, quote: 0.04, quoteTimestamp: start.addingTimeInterval(120))
        let refreshed = ChartLivePriceSeries.points(history: history, quote: 0.05, quoteTimestamp: start.addingTimeInterval(180))
        XCTAssertEqual(Array(first.dropLast()), history)
        XCTAssertEqual(Array(refreshed.dropLast()), history)
        XCTAssertEqual(refreshed.count, 3)
        XCTAssertEqual(refreshed.last?.priceUSD, 0.05)
        XCTAssertEqual((refreshed.last!.priceUSD / refreshed.first!.priceUSD - 1) * 100, 150, accuracy: 0.000001)
    }

    func testLiveChartQuoteUpdatesPortfolioValueUsingCurrentHoldings() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let buy = PortfolioTransaction(portfolioID: UUID(), type: "Buy", kasAmount: 100,
            kasPriceUSD: 0.02, timestamp: start.addingTimeInterval(-60), notes: "")
        let history = [HistoricalPricePoint(timestamp: start, priceUSD: 0.02)]
        let prices = ChartLivePriceSeries.points(history: history, quote: 0.04, quoteTimestamp: start.addingTimeInterval(60))
        let values = PortfolioChartBuilder.points(transactions: [buy], prices: prices)
        XCTAssertEqual(values.first?.valueUSD, 2)
        XCTAssertEqual(values.last?.valueUSD, 4)
    }

    func testInvalidLiveChartQuotesDoNotReplaceValidHistory() {
        let now = Date()
        let history = [HistoricalPricePoint(timestamp: now.addingTimeInterval(-60), priceUSD: 0.02)]
        let quotes: [Double?] = [nil, 0, -1, .nan, .infinity]
        for quote in quotes {
            XCTAssertEqual(ChartLivePriceSeries.points(history: history, quote: quote, quoteTimestamp: now), history)
        }
        XCTAssertEqual(ChartLivePriceSeries.points(history: [], quote: 0.03, quoteTimestamp: now).count, 1)
    }
}


extension PortfolioCalculationsTests {
    func testSavedChartQuoteKeepsItsActualTimestamp() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let history = [HistoricalPricePoint(timestamp: start, priceUSD: 0.02)]
        let savedAt = start.addingTimeInterval(60)
        let first = ChartLivePriceSeries.points(history: history, quote: 0.03, quoteTimestamp: savedAt)
        let reopened = ChartLivePriceSeries.points(history: history, quote: 0.03, quoteTimestamp: savedAt)
        XCTAssertEqual(first, reopened)
        XCTAssertEqual(reopened.last?.timestamp, savedAt)
    }

    func testSavedQuoteCannotReplaceNewerHistoryOrInventUnknownTimestamp() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let history = [HistoricalPricePoint(timestamp: start, priceUSD: 0.04)]
        XCTAssertEqual(ChartLivePriceSeries.points(history: history, quote: 0.03,
            quoteTimestamp: start.addingTimeInterval(-60)), history)
        XCTAssertEqual(ChartLivePriceSeries.points(history: history, quote: 0.03,
            quoteTimestamp: nil), history)
        let sameTime = ChartLivePriceSeries.points(history: history, quote: 0.05, quoteTimestamp: start)
        XCTAssertEqual(sameTime.count, 1)
        XCTAssertEqual(sameTime.last?.priceUSD, 0.05)
    }
}

extension PortfolioCalculationsTests {
    func testChartWindowInterpolatesOnlySupportedStartingBoundary() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let prices = [
            HistoricalPricePoint(timestamp: start, priceUSD: 0.02),
            HistoricalPricePoint(timestamp: start.addingTimeInterval(120), priceUSD: 0.04)
        ]
        let result = ChartHistoryWindow.prepare(prices: prices,
            start: start.addingTimeInterval(60), now: start.addingTimeInterval(120), maximumGap: 180)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.points.first?.timestamp, start.addingTimeInterval(60))
        XCTAssertEqual(result.points.first!.priceUSD, 0.03, accuracy: 0.000001)
        XCTAssertEqual(result.points.last, prices.last)
    }

    func testChartWindowDoesNotExtrapolateMissingBeginning() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let prices = [HistoricalPricePoint(timestamp: start, priceUSD: 0.02),
            HistoricalPricePoint(timestamp: start.addingTimeInterval(60), priceUSD: 0.03)]
        let result = ChartHistoryWindow.prepare(prices: prices,
            start: start.addingTimeInterval(-60), now: start.addingTimeInterval(60), maximumGap: 120)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.points, prices)
    }

    func testChartWindowDetectsInteriorGapsEvenWithRecentQuote() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let prices = [HistoricalPricePoint(timestamp: start, priceUSD: 0.02),
            HistoricalPricePoint(timestamp: start.addingTimeInterval(86_400), priceUSD: 0.03)]
        let result = ChartHistoryWindow.prepare(prices: prices, start: start,
            now: start.addingTimeInterval(86_400), maximumGap: 2 * 60 * 60)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.points, prices)
    }

    func testChartWindowRejectsStaleEndAndSinglePointCoverage() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let prices = [HistoricalPricePoint(timestamp: start, priceUSD: 0.02),
            HistoricalPricePoint(timestamp: start.addingTimeInterval(60), priceUSD: 0.03)]
        XCTAssertFalse(ChartHistoryWindow.prepare(prices: prices, start: start,
            now: start.addingTimeInterval(8 * 60 * 60), maximumGap: 36 * 60 * 60).isComplete)
        XCTAssertFalse(ChartHistoryWindow.prepare(prices: [prices[0]], start: start,
            now: start, maximumGap: 36 * 60 * 60).isComplete)
    }

    func testRecentPortfolioBoundaryDoesNotRequireHistoryBeforeFirstTransaction() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let prices = [HistoricalPricePoint(timestamp: start, priceUSD: 0.02),
            HistoricalPricePoint(timestamp: start.addingTimeInterval(120), priceUSD: 0.04)]
        let firstTransactionDate = start.addingTimeInterval(60)
        let result = ChartHistoryWindow.prepare(prices: prices, start: firstTransactionDate,
            now: start.addingTimeInterval(120), maximumGap: 36 * 60 * 60)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.points.first?.timestamp, firstTransactionDate)
    }

    func testAllChartWindowStartsAtAvailableHistoryAndRetainsDailySamples() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let prices = [HistoricalPricePoint(timestamp: start, priceUSD: 0.02),
            HistoricalPricePoint(timestamp: start.addingTimeInterval(86_400), priceUSD: 0.03)]
        let result = ChartHistoryWindow.prepare(prices: prices, start: nil,
            now: start.addingTimeInterval(86_400), maximumGap: 36 * 60 * 60)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.points, prices)
    }
}

extension PortfolioCalculationsTests {
    func testPortfolioChartShowsEachTransactionTypeAtItsExactTime() {
        for type in [PortfolioTransactionType.buy, .sell, .transferIn, .transferOut] {
            let points = PortfolioChartBuilder.points(transactions: [
                transaction(.buy, amount: 100, price: 0.01, offset: -10),
                transaction(type, amount: 20, price: 0.01, offset: 50)
            ], prices: [price(0.01, offset: 0), price(0.01, offset: 100)])
            let expectedHoldings = type == .buy || type == .transferIn ? 120.0 : 80.0
            XCTAssertEqual(points.count, 4)
            XCTAssertEqual(Set(points.map(\.id)).count, points.count)
            XCTAssertEqual(points[1].timestamp, baseDate.addingTimeInterval(50))
            XCTAssertEqual(points[2].timestamp, baseDate.addingTimeInterval(50))
            XCTAssertEqual(points[1].valueUSD, 1, accuracy: 0.000001)
            XCTAssertEqual(points[2].valueUSD, expectedHoldings * 0.01, accuracy: 0.000001)
            XCTAssertEqual(PortfolioChartBuilder.selectedPoint(at: baseDate.addingTimeInterval(49),
                in: points)!.valueUSD, 1, accuracy: 0.000001)
            XCTAssertEqual(PortfolioChartBuilder.selectedPoint(at: baseDate.addingTimeInterval(50),
                in: points)!.valueUSD, expectedHoldings * 0.01, accuracy: 0.000001)
        }
    }

    func testPortfolioChartGroupsSimultaneousTransactionsWithoutDuplicateIDs() {
        let transactions = [
            transaction(.buy, amount: 100, price: 0.01, offset: -10),
            transaction(.buy, amount: 30, price: 0.01, offset: 50),
            transaction(.sell, amount: 20, price: 0.01, offset: 50),
            transaction(.transferIn, amount: 10, price: 0.01, offset: 50),
            transaction(.transferOut, amount: 5, price: 0.01, offset: 50)
        ]
        let points = PortfolioChartBuilder.points(transactions: transactions,
            prices: [price(0.01, offset: 0), price(0.01, offset: 50), price(0.01, offset: 100)])
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(Set(points.map(\.id)).count, points.count)
        XCTAssertEqual(points[2].valueUSD, PortfolioHoldingSummary(transactions: transactions).holdings * 0.01,
            accuracy: 0.000001)
        XCTAssertEqual(points[1].phase, .beforeTransaction)
        XCTAssertEqual(points[2].phase, .afterTransaction)
    }

    func testPortfolioDownsamplingPreservesEveryTransactionJumpAndSelection() {
        let transactions = [transaction(.buy, amount: 100, price: 0.01, offset: -10)]
            + (1...20).map { transaction(.buy, amount: 1, price: 0.01, offset: Double($0 * 10 + 5)) }
        let prices = (0...250).map { price(0.01, offset: Double($0)) }
        let full = PortfolioChartBuilder.points(transactions: transactions, prices: prices)
        let sampled = PortfolioChartBuilder.downsampled(full, maximumCount: 10)
        XCTAssertEqual(sampled.filter { $0.phase != .sample }, full.filter { $0.phase != .sample })
        let before = PortfolioChartBuilder.selectedPoint(at: baseDate.addingTimeInterval(14.9), in: sampled)!
        let after = PortfolioChartBuilder.selectedPoint(at: baseDate.addingTimeInterval(15), in: sampled)!
        XCTAssertEqual(before.valueUSD, 1, accuracy: 0.000001)
        XCTAssertEqual(after.valueUSD, 1.01, accuracy: 0.000001)
    }

    func testPortfolioSelectionFollowsPriceMovementBetweenTransactions() {
        let points = PortfolioChartBuilder.points(transactions: [
            transaction(.buy, amount: 100, price: 0.01, offset: -10),
            transaction(.sell, amount: 100, price: 0.03, offset: 100)
        ], prices: [price(0.01, offset: 0), price(0.03, offset: 100), price(0.04, offset: 200)])
        XCTAssertEqual(PortfolioChartBuilder.selectedPoint(at: baseDate.addingTimeInterval(50),
            in: points)!.valueUSD, 2, accuracy: 0.000001)
        XCTAssertEqual(PortfolioChartBuilder.selectedPoint(at: baseDate.addingTimeInterval(100),
            in: points)!.valueUSD, 0, accuracy: 0.000001)
        XCTAssertEqual(PortfolioChartBuilder.selectedPoint(at: baseDate.addingTimeInterval(150),
            in: points)!.valueUSD, 0, accuracy: 0.000001)
    }
}

extension PortfolioCalculationsTests {
    func testKASChartCanSelectHistorySampleOmittedFromReducedLine() {
        let history = (0...500).map { price(0.01 + Double($0 % 17) / 10_000, offset: Double($0)) }
        let sampled = PortfolioChartBuilder.downsampledPrices(history, maximumCount: 160)
        let sampledIDs = Set(sampled.map(\.id))
        let omitted = history.first { !sampledIDs.contains($0.id) }!
        let selected = PriceChartSelection.nearestPoint(to: omitted.timestamp, in: history)
        XCTAssertEqual(selected, omitted)
        let rendered = PriceChartSelection.renderedPoints(sampled: sampled, selected: selected)
        XCTAssertTrue(rendered.contains(omitted))
        XCTAssertEqual(rendered.count, sampled.count + 1)
        XCTAssertEqual(rendered.first, sampled.first)
        XCTAssertEqual(rendered.last, sampled.last)
        XCTAssertEqual(rendered.map(\.timestamp), rendered.map(\.timestamp).sorted())
        XCTAssertEqual(PriceChartSelection.renderedPoints(sampled: sampled, selected: nil), sampled)
    }

    func testKASChartSelectionClampsEdgesAndResolvesTiesWithoutInventingPrices() {
        let history = [price(0.01, offset: 0), price(0.03, offset: 100)]
        XCTAssertNil(PriceChartSelection.nearestPoint(to: baseDate, in: []))
        XCTAssertEqual(PriceChartSelection.nearestPoint(to: baseDate.addingTimeInterval(-10), in: history), history[0])
        XCTAssertEqual(PriceChartSelection.nearestPoint(to: baseDate.addingTimeInterval(110), in: history), history[1])
        XCTAssertEqual(PriceChartSelection.nearestPoint(to: baseDate.addingTimeInterval(50), in: history), history[0])
        XCTAssertEqual(PriceChartSelection.nearestPoint(to: baseDate.addingTimeInterval(51), in: history), history[1])
        XCTAssertEqual(PriceChartSelection.renderedPoints(sampled: history, selected: history[1]), history)
        XCTAssertEqual(PriceChartSelection.renderedPoints(sampled: history, selected: price(0.05, offset: 200)), history)
    }
}
