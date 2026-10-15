import Foundation
import Security
import UsageCore

/// API keys in UsageBar's own Keychain items: one generic password per
/// provider, service `io.github.jhnqch.usagebar.api-key`, account the
/// provider's id. Nothing else holds a key: not `UserDefaults`, not a file,
/// not the log. Claude Code's and Codex's own items are never touched here.
struct KeychainKeyStore: KeyStore {
    static let service = "io.github.jhnqch.usagebar.api-key"

    struct Failure: Error, CustomStringConvertible {
        var status: OSStatus
        var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: id]
    }

    /// Reading the secret can show a Keychain prompt (after a rebuild
    /// changes the ad-hoc signature), so it waits off the main thread.
    func key(for id: String) async throws -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let request = query
        return try await Task.detached(priority: .utility) {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
            return String(data: data, encoding: .utf8).flatMap(APIKey.normalized)
        }.value
    }

    /// Asks for the item's attributes only, which never shows a prompt.
    func hasKey(for id: String) -> Bool {
        var query = query(id)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func save(_ key: String, for id: String) throws {
        try removeKey(for: id)
        var item = query(id)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrLabel as String] = "UsageBar API key (\(id))"
        item[kSecAttrDescription as String] = "API key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func removeKey(for id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
