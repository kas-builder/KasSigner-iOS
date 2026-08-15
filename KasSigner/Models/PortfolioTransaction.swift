import Foundation
import SwiftData

@Model
final class PortfolioTransaction {
    @Attribute(.unique) var id: UUID
    var portfolioID: UUID
    var type: String
    var kasAmount: Double
    var kasPriceUSD: Double
    var feeUSD: Double = 0
    var timestamp: Date
    var notes: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        portfolioID: UUID,
        type: String,
        kasAmount: Double,
        kasPriceUSD: Double,
        timestamp: Date,
        notes: String,
        createdAt: Date = Date(),
        feeUSD: Double = 0
    ) {
        self.id = id
        self.portfolioID = portfolioID
        self.type = type
        self.kasAmount = kasAmount
        self.kasPriceUSD = kasPriceUSD
        self.feeUSD = feeUSD
        self.timestamp = timestamp
        self.notes = notes
        self.createdAt = createdAt
    }
}
