import Foundation
import Security

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

struct TestnetHotWalletImportResult: Decodable {
    let mnemonic: String
    let wallet: WalletImportResult
}

enum TestnetSeedStore {
    private static let service = "org.kassigner.testnet10.seed.v1"

    static func save(_ mnemonic: String, for profileID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        let data = Data(mnemonic.utf8)
        let status: OSStatus
        if existing == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load(for profileID: UUID) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let mnemonic = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return mnemonic
    }

    static func remove(for profileID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
