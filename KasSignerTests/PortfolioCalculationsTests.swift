import CryptoKit
import XCTest
@testable import KasSigner

final class PortfolioCalculationsTests: XCTestCase {
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
        let store = WalletStore()
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
    func testOutOfOrderChangeAddressIsMarkedUsedWithoutMovingCursorBackward() {
        let store = WalletStore()
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
            committedChangeIndex: 1
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
    func testBroadcastToOwnedReceiveAddressMarksItUsedImmediately() {
        let store = WalletStore()
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
        let store = WalletStore()
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
    func testLocallyBroadcastTransferToUncachedWalletAddressBecomesInternalWhenConfirmed() {
        let store = WalletStore()
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
        let store = WalletStore()
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
        XCTAssertEqual(transaction?.status, .pending)
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

        XCTAssertEqual(points.map(\.valueUSD), [2, 3, 2.4])
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

        let preview = try PortfolioCSVImporter.preview(
            data: exportedData,
            fileName: "export.csv",
            portfolioID: portfolioID,
            existingTransactions: [],
            now: ISO8601DateFormatter().date(from: "2026-08-15T12:00:00Z")!
        )

        XCTAssertEqual(preview.transactions.count, 2)
        XCTAssertEqual(preview.transactions.map(\.type), [.buy, .sell])
        XCTAssertEqual(preview.transactions[1].notes, "Partial sale, \"summer\"\nlot")
        XCTAssertEqual(preview.transactions[1].feeUSD, 1.25, accuracy: 0.000_001)
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

    func testLegacyBroadcastTransactionDecodesAsPendingSentTransaction() throws {
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
        XCTAssertEqual(decoded.status, .pending)
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

    func testDiscoveryRetainsTwentyAddressesAfterHighestHistoricalUse() {
        let receive = (0..<512).map { "kaspa:receive-\($0)" }
        let change = (0..<512).map { "kaspa:change-\($0)" }
        let plan = WalletSyncService.discoveryPlan(
            receiveAddresses: receive,
            changeAddresses: change,
            activeAddresses: [receive[65], change[31]],
            currentNextReceiveIndex: 0,
            currentNextChangeIndex: 0
        )

        XCTAssertEqual(plan.receiveCount, 86)
        XCTAssertEqual(plan.changeCount, 52)
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

        XCTAssertEqual(plan.receiveCount, 128)
        XCTAssertEqual(plan.nextReceiveIndex, 108)
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
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(WalletProfile.self, from: legacyData)

        XCTAssertFalse(decoded.requiresInitialDiscovery)
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

        XCTAssertEqual(transaction?.status, .pending)
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
            requiresInitialDiscovery: true
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
