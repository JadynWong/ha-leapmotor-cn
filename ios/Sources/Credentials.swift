import Foundation
import Security

struct Credentials: Codable {
    let address: String
    let token: String

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.jadynwong.leapmotorha",
            kSecAttrAccount as String: "home-assistant",
        ]
    }

    static func load() throws -> Credentials? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch is DecodingError {
            throw KeychainError(status: errSecDecode)
        }
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(Self.query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = Self.query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try Self.check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try Self.check(status)
        }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "无法访问 iOS 钥匙串（\(status)）。" }
}
