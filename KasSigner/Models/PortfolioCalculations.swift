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
    let totalBought: Double
    let totalSold: Double
    let totalTransferredIn: Double
    let totalTransferredOut: Double

    init(transactions: [PortfolioTransaction]) {
        var holdings = 0.0
        var costBasis = 0.0
        var totalBought = 0.0
        var totalSold = 0.0
        var totalTransferredIn = 0.0
        var totalTransferredOut = 0.0

        for transaction in transactions.sorted(by: PortfolioTransactionOrder.ascending) {
            switch transaction.type {
            case PortfolioTransactionType.buy.rawValue:
                holdings += transaction.kasAmount
                costBasis += transaction.kasAmount * transaction.kasPriceUSD
                totalBought += transaction.kasAmount
            case PortfolioTransactionType.sell.rawValue:
                let averageCost = holdings > 0 ? costBasis / holdings : 0
                let disposedAmount = min(transaction.kasAmount, max(holdings, 0))
                holdings -= disposedAmount
                costBasis = max(0, costBasis - (disposedAmount * averageCost))
                totalSold += transaction.kasAmount
            case PortfolioTransactionType.transferIn.rawValue:
                holdings += transaction.kasAmount
                totalTransferredIn += transaction.kasAmount
            case PortfolioTransactionType.transferOut.rawValue:
                let transferredAmount = min(transaction.kasAmount, max(holdings, 0))
                holdings -= transferredAmount
                totalTransferredOut += transaction.kasAmount
            default:
                continue
            }
        }

        self.holdings = max(0, holdings)
        self.costBasis = costBasis
        self.totalBought = totalBought
        self.totalSold = totalSold
        self.totalTransferredIn = totalTransferredIn
        self.totalTransferredOut = totalTransferredOut
    }

    var averageCost: Double? {
        guard holdings > 0, costBasis > 0 else { return nil }
        return costBasis / holdings
    }
}

struct PortfolioChartPoint: Identifiable, Equatable {
    let timestamp: Date
    let valueUSD: Double

    var id: Date { timestamp }
}

enum PortfolioChartBuilder {
    static func points(
        transactions: [PortfolioTransaction],
        prices: [HistoricalPricePoint]
    ) -> [PortfolioChartPoint] {
        let orderedTransactions = transactions.sorted(by: PortfolioTransactionOrder.ascending)
        guard let firstTransactionDate = orderedTransactions.first?.timestamp else { return [] }

        let orderedPrices = prices.sorted { $0.timestamp < $1.timestamp }
        guard !orderedPrices.isEmpty else { return [] }

        var applicablePrices = orderedPrices
        var startingPoint: PortfolioChartPoint?
        if let rangeStart = orderedPrices.first?.timestamp,
           firstTransactionDate > rangeStart {
            applicablePrices = orderedPrices.filter { $0.timestamp >= firstTransactionDate }
            if let startingPrice = interpolatedPrice(at: firstTransactionDate, in: orderedPrices) {
                let startingHoldings = PortfolioHoldingSummary(
                    transactions: orderedTransactions.filter { $0.timestamp <= firstTransactionDate }
                ).holdings
                startingPoint = PortfolioChartPoint(
                    timestamp: firstTransactionDate,
                    valueUSD: startingHoldings * startingPrice
                )
            }
        }

        var result = applicablePrices.map { pricePoint in
            let holdings = PortfolioHoldingSummary(
                transactions: orderedTransactions.filter { $0.timestamp <= pricePoint.timestamp }
            ).holdings
            return PortfolioChartPoint(
                timestamp: pricePoint.timestamp,
                valueUSD: holdings * pricePoint.priceUSD
            )
        }

        if let startingPoint, result.first?.timestamp != startingPoint.timestamp {
            result.insert(startingPoint, at: 0)
        }
        return result
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
        return result
    }
}
