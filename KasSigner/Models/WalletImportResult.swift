import Foundation

struct WalletImportResult: Codable, Equatable {
    let kpub: String
    let receiveAddresses: [String]
    let changeAddresses: [String]

    enum CodingKeys: String, CodingKey {
        case kpub
        case receiveAddresses = "receive_addresses"
        case changeAddresses = "change_addresses"
    }
}
