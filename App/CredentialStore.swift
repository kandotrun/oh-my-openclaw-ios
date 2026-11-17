import Foundation
import Security

enum CredentialStore {
    private static let service = "run.kandot.oh-my-openclaw.credentials"

    static func read<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialError(status: status) }
        return try JSONDecoder().decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            let status = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
            guard status == errSecSuccess else { throw CredentialError(status: status) }
        } else if update != errSecSuccess { throw CredentialError(status: update) }
    }

    private struct CredentialError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "接続情報を安全な保存先に保存できませんでした（\(status)）。端末のロックを解除してやり直してください。" }
    }
}
