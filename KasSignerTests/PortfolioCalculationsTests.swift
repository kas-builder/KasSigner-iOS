import XCTest
@testable import KasSigner

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
        XCTAssertEqual(summary.averageCost!, 0.035, accuracy: 0.000_000_01)
    }

    func testPartialSellRemovesWeightedAverageCost() {
        let summary = PortfolioHoldingSummary(transactions: [
            transaction(.buy, amount: 100, price: 0.02, offset: 0),
            transaction(.buy, amount: 300, price: 0.04, offset: 60),
            transaction(.sell, amount: 100, price: 0.05, offset: 120)
        ])

        XCTAssertEqual(summary.holdings, 300, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.costBasis, 10.5, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.averageCost!, 0.035, accuracy: 0.000_000_01)
    }

    func testTransfersChangeHoldingsButNotCostBasis() {
        let summary = PortfolioHoldingSummary(transactions: [
            transaction(.buy, amount: 100, price: 0.03, offset: 0),
            transaction(.transferIn, amount: 50, price: 0.20, offset: 60),
            transaction(.transferOut, amount: 25, price: 0.50, offset: 120)
        ])

        XCTAssertEqual(summary.holdings, 125, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.costBasis, 3, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.totalTransferredIn, 50, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.totalTransferredOut, 25, accuracy: 0.000_000_01)
    }

    func testOversellCannotCreateNegativeHoldingsOrCostBasis() {
        let summary = PortfolioHoldingSummary(transactions: [
            transaction(.buy, amount: 10, price: 0.03, offset: 0),
            transaction(.sell, amount: 20, price: 0.05, offset: 60)
        ])

        XCTAssertEqual(summary.holdings, 0, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.costBasis, 0, accuracy: 0.000_000_01)
    }

    func testTransferOutCannotMakeLaterHoldingsDisappear() {
        let summary = PortfolioHoldingSummary(transactions: [
            transaction(.transferOut, amount: 20, price: 0, offset: 0),
            transaction(.transferIn, amount: 10, price: 0, offset: 60)
        ])

        XCTAssertEqual(summary.holdings, 10, accuracy: 0.000_000_01)
        XCTAssertEqual(summary.costBasis, 0, accuracy: 0.000_000_01)
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

    private func transaction(
        _ type: PortfolioTransactionType,
        amount: Double,
        price: Double,
        offset: TimeInterval
    ) -> PortfolioTransaction {
        PortfolioTransaction(
            portfolioID: portfolioID,
            type: type.rawValue,
            kasAmount: amount,
            kasPriceUSD: price,
            timestamp: baseDate.addingTimeInterval(offset),
            notes: "",
            createdAt: baseDate.addingTimeInterval(offset)
        )
    }

    private func price(_ value: Double, offset: TimeInterval) -> HistoricalPricePoint {
        HistoricalPricePoint(
            timestamp: baseDate.addingTimeInterval(offset),
            priceUSD: value
        )
    }
}
