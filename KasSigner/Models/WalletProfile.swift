import Foundation

struct WalletProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let kpub: String
    let network: String
    let importedAt: Date
    var receiveAddresses: [String]
    var changeAddresses: [String]

    init(
        id: UUID = UUID(),
        name: String,
        kpub: String,
        network: String = "mainnet",
        importedAt: Date = Date(),
        receiveAddresses: [String] = [],
        changeAddresses: [String] = []
    ) {
        self.id = id
        self.name = name
        self.kpub = kpub
        self.network = network
        self.importedAt = importedAt
        self.receiveAddresses = receiveAddresses
        self.changeAddresses = changeAddresses
    }
}
