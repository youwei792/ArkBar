import Foundation
#if canImport(Security)
import Security
#endif

/// Minimal keychain-backed cookie store for web-auth providers (e.g. OpenCode Go).
///
/// Modelled after CodexBar's `KeychainCacheStore`, but trimmed to only what
/// ArkBar needs: storing a single cookie header string per provider. Cookies
/// never touch UserDefaults; only a boolean "is configured" hint does.
///
/// - Service: `com.arkbar.cache`
/// - Account: `cookie.<provider>` (e.g. `cookie.opencode`)
/// - Class: `kSecClassGenericPassword`
/// - Accessible: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
enum CookieKeychainStore {
    static let service = "com.arkbar.cache"

    /// Per-provider keychain account name.
    static func account(forProvider provider: String) -> String {
        "cookie.\(provider)"
    }

    /// Store (or replace) the cookie header for a provider.
    /// Passing nil clears any existing entry.
    @discardableResult
    static func store(cookie: String?, provider: String) -> Bool {
        let account = Self.account(forProvider: provider)
        guard let cookie, !cookie.isEmpty else {
            return Self.clear(provider: provider)
        }
        let data = Data(cookie.utf8)

        // Try update first; fall back to add.
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus != errSecItemNotFound {
            UsageStore.log("Keychain cookie update failed (\(account)): OSStatus \(updateStatus)")
            return false
        }

        var addQuery = updateQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrLabel as String] = "ArkBar Cookie Cache"
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            UsageStore.log("Keychain cookie add failed (\(account)): OSStatus \(addStatus)")
        }
        return addStatus == errSecSuccess
    }

    /// Load the cookie header for a provider, or nil if none / undecodable.
    static func load(provider: String) -> String? {
        let account = Self.account(forProvider: provider)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let cookie = String(data: data, encoding: .utf8),
              !cookie.isEmpty
        else {
            return nil
        }
        return cookie
    }

    /// Remove the cookie entry for a provider. Returns true if removed or absent.
    @discardableResult
    static func clear(provider: String) -> Bool {
        let account = Self.account(forProvider: provider)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
