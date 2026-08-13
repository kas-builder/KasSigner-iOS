import Foundation
import SwiftData

@Model
final class PortfolioAccount {
    @Attribute(.unique) var id: UUID
    var name: String
    var accountDescription: String
    var iconName: String
    var accentName: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        accountDescription: String = "",
        iconName: String = "briefcase.fill",
        accentName: String = "teal",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.accountDescription = accountDescription
        self.iconName = iconName
        self.accentName = accentName
        self.createdAt = createdAt
    }
}
