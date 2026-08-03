import Foundation

struct WalletProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let kpub: String
    let network: String
    let importedAt: Date
    var receiveAddresses: [String]
    var changeAddresses: [String]
    var nextReceiveIndex: Int
    var nextChangeIndex: Int

    init(
        id: UUID = UUID(),
        name: String,
        kpub: String,
        network: String = "mainnet",
        importedAt: Date = Date(),
        receiveAddresses: [String] = [],
        changeAddresses: [String] = [],
        nextReceiveIndex: Int = 0,
        nextChangeIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.kpub = kpub
        self.network = network
        self.importedAt = importedAt
        self.receiveAddresses = receiveAddresses
        self.changeAddresses = changeAddresses
        self.nextReceiveIndex = max(0, nextReceiveIndex)
        self.nextChangeIndex = max(0, nextChangeIndex)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kpub
        case network
        case importedAt
        case receiveAddresses
        case changeAddresses
        case nextReceiveIndex
        case nextChangeIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kpub = try container.decode(String.self, forKey: .kpub)
        network = try container.decode(String.self, forKey: .network)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        receiveAddresses = try container.decode([String].self, forKey: .receiveAddresses)
        changeAddresses = try container.decode([String].self, forKey: .changeAddresses)
        nextReceiveIndex = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .nextReceiveIndex) ?? 0
        )
        nextChangeIndex = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .nextChangeIndex) ?? 0
        )
    }
}
