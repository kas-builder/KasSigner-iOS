import XCTest
@testable import KasSigner

final class ProtectedVaultFundingPlanTests: XCTestCase {
    private let profileID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    func testFundingSelectionSessionClearsOnlyOnceForSameProfile() {
        var session = ProtectedVaultFundingSelectionSession()

        XCTAssertTrue(session.begin(profileID: profileID))
        XCTAssertFalse(session.begin(profileID: profileID))
        XCTAssertTrue(session.begin(profileID: UUID()))
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
            approvedAddress: "kaspa:test",
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

final class PortfolioCalculationsTests: XCTestCase {
    private let portfolioID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

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

        XCTAssertEqual(points.map(\.valueUSD), [2, 3, 2.4])
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
