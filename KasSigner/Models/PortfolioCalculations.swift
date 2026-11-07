import Foundation

enum PortfolioTransactionType: String, CaseIterable, Identifiable {
    case buy = "Buy"
    case sell = "Sell"
    case transferIn = "Transfer In"
    case transferOut = "Transfer Out"

    var id: Self { self }
}

enum PortfolioTransactionOrder {
    static func ascending(_ lhs: PortfolioTransaction, _ rhs: PortfolioTransaction) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct PortfolioHoldingSummary {
    let holdings: Double
    let costBasis: Double
    let remainingCostBasis: Double
    let totalBought: Double
    let totalSold: Double
    let totalTransferredIn: Double
    let totalTransferredOut: Double

    init(transactions: [PortfolioTransaction]) {
        var holdings = 0.0
        var lifetimeBuyCost = 0.0
        var remainingCostBasis = 0.0
        var totalBought = 0.0
        var totalSold = 0.0
        var totalTransferredIn = 0.0
        var totalTransferredOut = 0.0

        for transaction in transactions.sorted(by: PortfolioTransactionOrder.ascending) {
            switch transaction.type {
            case PortfolioTransactionType.buy.rawValue:
                holdings += transaction.kasAmount
                let acquisitionCost = transaction.kasAmount * transaction.kasPriceUSD
                lifetimeBuyCost += acquisitionCost
                remainingCostBasis += acquisitionCost
                totalBought += transaction.kasAmount
            case PortfolioTransactionType.sell.rawValue:
                let averageCost = holdings > 0 ? remainingCostBasis / holdings : 0
                let disposedAmount = min(transaction.kasAmount, max(holdings, 0))
                holdings -= disposedAmount
                remainingCostBasis = max(0, remainingCostBasis - (disposedAmount * averageCost))
                totalSold += transaction.kasAmount
            case PortfolioTransactionType.transferIn.rawValue:
                holdings += transaction.kasAmount
                totalTransferredIn += transaction.kasAmount
            case PortfolioTransactionType.transferOut.rawValue:
                let averageCost = holdings > 0 ? remainingCostBasis / holdings : 0
                let transferredAmount = min(transaction.kasAmount, max(holdings, 0))
                holdings -= transferredAmount
                remainingCostBasis = max(0, remainingCostBasis - (transferredAmount * averageCost))
                totalTransferredOut += transaction.kasAmount
            default:
                continue
            }
        }

        self.holdings = max(0, holdings)
        self.costBasis = lifetimeBuyCost
        self.remainingCostBasis = remainingCostBasis
        self.totalBought = totalBought
        self.totalSold = totalSold
        self.totalTransferredIn = totalTransferredIn
        self.totalTransferredOut = totalTransferredOut
    }

    var averageCost: Double? {
        guard totalBought > 0, costBasis > 0 else { return nil }
        return costBasis / totalBought
    }
}

struct PortfolioChartPoint: Identifiable, Equatable {
    enum Phase: Hashable { case sample, beforeTransaction, afterTransaction }
    struct ID: Hashable {
        let timestamp: Date
        let phase: Phase
    }

    let timestamp: Date
    let valueUSD: Double
    var phase: Phase = .sample

    var id: ID { ID(timestamp: timestamp, phase: phase) }
}

enum PortfolioTransactionPriceResolver {
    static func automaticPrice(
        at timestamp: Date,
        now: Date,
        livePrice: Double?,
        historicalPrices: [HistoricalPricePoint],
        calendar: Calendar = .current
    ) -> Double? {
        if calendar.isDate(timestamp, inSameDayAs: now) {
            return livePrice
        }
        let ordered = historicalPrices.filter { $0.priceUSD.isFinite && $0.priceUSD > 0 }
            .sorted { $0.timestamp < $1.timestamp }
        guard let first = ordered.first, let last = ordered.last,
              timestamp >= first.timestamp, timestamp <= last.timestamp else { return nil }
        var low = 0
        var high = ordered.count
        while low < high {
            let middle = (low + high) / 2
            if ordered[middle].timestamp < timestamp { low = middle + 1 }
            else { high = middle }
        }
        if low < ordered.count, ordered[low].timestamp == timestamp { return ordered[low].priceUSD }
        guard low > 0, low < ordered.count,
              ordered[low].timestamp.timeIntervalSince(ordered[low - 1].timestamp) <= 36 * 60 * 60 else {
            return nil
        }
        return PortfolioChartBuilder.interpolatedPrice(at: timestamp, in: ordered)
    }
}

enum PortfolioChartBuilder {
    static func valueDomain(for points: [PortfolioChartPoint]) -> ClosedRange<Double> {
        let values = points.map(\.valueUSD)
        guard let minimum = values.min(), let maximum = values.max() else { return 0...1 }

        let spread = maximum - minimum
        let reference = max(abs(maximum), abs(minimum), 0.01)
        let padding: Double
        if spread > 0 {
            padding = max(spread * 0.12, reference * 0.0005)
        } else {
            padding = max(reference * 0.01, 0.0001)
        }

        let lower = max(0, minimum - padding)
        let upper = max(lower + 0.0001, maximum + padding)
        return lower...upper
    }

    static func points(
        transactions: [PortfolioTransaction],
        prices: [HistoricalPricePoint]
    ) -> [PortfolioChartPoint] {
        let orderedTransactions = transactions.sorted(by: PortfolioTransactionOrder.ascending)
        guard let firstTransactionDate = orderedTransactions.first?.timestamp else { return [] }

        let orderedPrices = prices.sorted { $0.timestamp < $1.timestamp }
        guard !orderedPrices.isEmpty else { return [] }

        let start = max(firstTransactionDate, orderedPrices[0].timestamp)
        guard let end = orderedPrices.last?.timestamp, start <= end else { return [] }
        let eventTimes = orderedTransactions.lazy.map(\.timestamp).filter { $0 >= start && $0 <= end }
        let sampleTimes = orderedPrices.lazy.map(\.timestamp).filter { $0 >= start && $0 <= end }
        let timeline = Set(Array(eventTimes) + Array(sampleTimes) + [start]).sorted()
        var transactionIndex = 0
        var holdings = 0.0
        var result: [PortfolioChartPoint] = []

        for timestamp in timeline {
            guard let price = interpolatedPrice(at: timestamp, in: orderedPrices) else { continue }
            // Seed the chart with all prior holdings before processing the
            // transactions at this exact time in the existing accounting order.
            while transactionIndex < orderedTransactions.count,
                  orderedTransactions[transactionIndex].timestamp < timestamp {
                holdings = holdingsAfterApplying(orderedTransactions[transactionIndex], to: holdings)
                transactionIndex += 1
            }
            let previousHoldings = holdings
            while transactionIndex < orderedTransactions.count,
                  orderedTransactions[transactionIndex].timestamp == timestamp {
                holdings = holdingsAfterApplying(orderedTransactions[transactionIndex], to: holdings)
                transactionIndex += 1
            }
            if timestamp > start && holdings != previousHoldings {
                result.append(PortfolioChartPoint(timestamp: timestamp,
                    valueUSD: previousHoldings * price, phase: .beforeTransaction))
                result.append(PortfolioChartPoint(timestamp: timestamp,
                    valueUSD: holdings * price, phase: .afterTransaction))
            } else {
                result.append(PortfolioChartPoint(timestamp: timestamp, valueUSD: holdings * price))
            }
        }
        return result
    }

    /// Interpolate the rendered line while keeping transaction jumps discrete.
    /// At a transaction's exact timestamp, use the holdings after the group.
    static func selectedPoint(at date: Date, in points: [PortfolioChartPoint]) -> PortfolioChartPoint? {
        guard let first = points.first, let last = points.last else { return nil }
        if date < first.timestamp { return first }
        if date >= last.timestamp { return last }
        var low = 0
        var high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].timestamp <= date { low = middle + 1 }
            else { high = middle }
        }
        let previous = points[low - 1]
        if previous.timestamp == date { return previous }
        let next = points[low]
        let fraction = date.timeIntervalSince(previous.timestamp)
            / next.timestamp.timeIntervalSince(previous.timestamp)
        return PortfolioChartPoint(timestamp: date,
            valueUSD: previous.valueUSD + (next.valueUSD - previous.valueUSD) * fraction)
    }

    private static func holdingsAfterApplying(
        _ transaction: PortfolioTransaction,
        to holdings: Double
    ) -> Double {
        switch transaction.type {
        case PortfolioTransactionType.buy.rawValue,
             PortfolioTransactionType.transferIn.rawValue:
            return holdings + transaction.kasAmount
        case PortfolioTransactionType.sell.rawValue,
             PortfolioTransactionType.transferOut.rawValue:
            return holdings - min(transaction.kasAmount, max(holdings, 0))
        default:
            return holdings
        }
    }

    static func interpolatedPrice(
        at date: Date,
        in prices: [HistoricalPricePoint]
    ) -> Double? {
        guard let first = prices.first, let last = prices.last else { return nil }
        if date <= first.timestamp { return first.priceUSD }
        if date >= last.timestamp { return last.priceUSD }

        var lowerBound = 0
        var upperBound = prices.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if prices[middle].timestamp < date {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        let previous = prices[lowerBound - 1]
        let next = prices[lowerBound]
        let interval = next.timestamp.timeIntervalSince(previous.timestamp)
        guard interval > 0 else { return previous.priceUSD }
        let progress = date.timeIntervalSince(previous.timestamp) / interval
        return previous.priceUSD + ((next.priceUSD - previous.priceUSD) * progress)
    }

    static func downsampled(
        _ points: [PortfolioChartPoint],
        maximumCount: Int
    ) -> [PortfolioChartPoint] {
        guard points.count > maximumCount, maximumCount >= 4 else { return points }

        let interior = Array(points.dropFirst().dropLast())
        let bucketCount = max(1, (maximumCount - 2) / 2)
        let bucketSize = Int(ceil(Double(interior.count) / Double(bucketCount)))
        var result = [points[0]]

        for start in stride(from: 0, to: interior.count, by: bucketSize) {
            let end = min(start + bucketSize, interior.count)
            let bucket = interior[start..<end]
            guard let minimum = bucket.min(by: { $0.valueUSD < $1.valueUSD }),
                  let maximum = bucket.max(by: { $0.valueUSD < $1.valueUSD }) else {
                continue
            }

            if minimum.timestamp <= maximum.timestamp {
                result.append(minimum)
                if maximum.id != minimum.id { result.append(maximum) }
            } else {
                result.append(maximum)
                if minimum.id != maximum.id { result.append(minimum) }
            }
        }

        result.append(points[points.count - 1])
        let sampledIDs = Set(result.map(\.id))
        // Preserve both sides of every holdings jump, even when this exceeds
        // the ordinary sample budget. Reordering equal timestamps breaks steps.
        return points.filter { sampledIDs.contains($0.id) || $0.phase != .sample }
    }

    static func downsampledPrices(
        _ points: [HistoricalPricePoint],
        maximumCount: Int
    ) -> [HistoricalPricePoint] {
        guard points.count > maximumCount, maximumCount >= 4 else { return points }

        let interior = Array(points.dropFirst().dropLast())
        let bucketCount = max(1, (maximumCount - 2) / 2)
        let bucketSize = Int(ceil(Double(interior.count) / Double(bucketCount)))
        var result = [points[0]]

        for start in stride(from: 0, to: interior.count, by: bucketSize) {
            let end = min(start + bucketSize, interior.count)
            let bucket = interior[start..<end]
            guard let minimum = bucket.min(by: { $0.priceUSD < $1.priceUSD }),
                  let maximum = bucket.max(by: { $0.priceUSD < $1.priceUSD }) else {
                continue
            }

            if minimum.timestamp <= maximum.timestamp {
                result.append(minimum)
                if maximum.id != minimum.id { result.append(maximum) }
            } else {
                result.append(maximum)
                if minimum.id != maximum.id { result.append(minimum) }
            }
        }

        result.append(points[points.count - 1])
        return result
    }
}

private extension Array {
    func partitioningIndex(where belongsInSecondPartition: (Element) -> Bool) -> Int {
        var lowerBound = 0
        var upperBound = count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if belongsInSecondPartition(self[middle]) {
                upperBound = middle
            } else {
                lowerBound = middle + 1
            }
        }
        return lowerBound
    }
}


/// Rebuild the live endpoint from an unchanged history snapshot, so quote
/// refreshes neither accumulate synthetic history nor require a history fetch.
enum ChartLivePriceSeries {
    static func points(history: [HistoricalPricePoint], quote: Double?, quoteTimestamp: Date?) -> [HistoricalPricePoint] {
        guard let quote, quote.isFinite, quote > 0,
              let quoteTimestamp, quoteTimestamp.timeIntervalSince1970.isFinite else { return history }
        // A saved spot quote must not replace more recent historical data.
        guard history.last.map({ quoteTimestamp >= $0.timestamp }) ?? true else { return history }
        var result = history.filter { $0.timestamp < quoteTimestamp }
        result.append(HistoricalPricePoint(timestamp: quoteTimestamp, priceUSD: quote))
        return result
    }
}


/// Validate the selected window without extrapolating across missing history.
enum ChartHistoryWindow {
    struct Result {
        let points: [HistoricalPricePoint]
        let isComplete: Bool
    }

    static func prepare(
        prices: [HistoricalPricePoint], start: Date?, now: Date,
        maximumGap: TimeInterval
    ) -> Result {
        let ordered = prices.filter {
            $0.priceUSD.isFinite && $0.priceUSD > 0 && $0.timestamp <= now
        }.sorted { $0.timestamp < $1.timestamp }
        guard let first = ordered.first else { return Result(points: [], isComplete: false) }
        let boundary = start ?? first.timestamp
        var window = ordered.filter { $0.timestamp >= boundary }
        var hasBoundary = window.first?.timestamp == boundary
        if !hasBoundary,
           let previous = ordered.last(where: { $0.timestamp < boundary }),
           let next = window.first,
           next.timestamp.timeIntervalSince(previous.timestamp) <= maximumGap {
            let interval = next.timestamp.timeIntervalSince(previous.timestamp)
            let fraction = boundary.timeIntervalSince(previous.timestamp) / interval
            let price = previous.priceUSD + (next.priceUSD - previous.priceUSD) * fraction
            window.insert(HistoricalPricePoint(timestamp: boundary, priceUSD: price), at: 0)
            hasBoundary = true
        }
        let hasGaps = zip(window, window.dropFirst()).contains {
            $1.timestamp.timeIntervalSince($0.timestamp) > maximumGap
        }
        let recentEnd = window.last.map {
            now.timeIntervalSince($0.timestamp) <= min(maximumGap, 6 * 60 * 60)
        } ?? false
        return Result(points: window, isComplete: hasBoundary && window.count >= 2 && !hasGaps && recentEnd)
    }
}


/// Select real samples from full history while rendering a bounded price series.
enum PriceChartSelection {
    static func nearestPoint(to date: Date, in points: [HistoricalPricePoint]) -> HistoricalPricePoint? {
        guard !points.isEmpty else { return nil }
        let index = insertionIndex(for: date, in: points)
        if index == 0 { return points[0] }
        if index == points.count { return points.last }
        let previous = points[index - 1]
        let next = points[index]
        return abs(previous.timestamp.timeIntervalSince(date)) <= abs(next.timestamp.timeIntervalSince(date))
            ? previous : next
    }

    static func renderedPoints(sampled: [HistoricalPricePoint], selected: HistoricalPricePoint?) -> [HistoricalPricePoint] {
        guard let selected, let first = sampled.first, let last = sampled.last,
              selected.timestamp >= first.timestamp, selected.timestamp <= last.timestamp else { return sampled }
        var result = sampled
        let index = insertionIndex(for: selected.timestamp, in: result)
        if index < result.count, result[index].timestamp == selected.timestamp {
            result[index] = selected
        } else {
            // Include the selected real sample in the line and fill, so the
            // marker shows its true price without floating off the reduced line.
            result.insert(selected, at: index)
        }
        return result
    }

    private static func insertionIndex(for date: Date, in points: [HistoricalPricePoint]) -> Int {
        var low = 0
        var high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].timestamp < date { low = middle + 1 }
            else { high = middle }
        }
        return low
    }
}
