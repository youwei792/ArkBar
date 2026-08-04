import Foundation
#if canImport(Security)
import Darwin
import LocalAuthentication
import Security
#endif

/// Stores session credentials in the macOS Keychain plus a file cache.
///
/// The file cache (`CredentialFileCache`) is the primary read path so that
/// a warm restart never needs to touch the Keychain (zero password prompts).
/// The Keychain remains the canonical store and serves as a fallback when
/// the file cache is missing or corrupt.
///
/// v1/v2 entries are migrated to v3 on first access and then deleted.
enum CookieKeychainStore {
    static let service = "com.tokenbar.cache.v3"
    private static let legacyService = "com.tokenbar.cache.v2"
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var processCache: [String: String] = [:]

    static func account(forProvider provider: String) -> String {
        "cookie.\(provider)"
    }

    /// Read path: file cache → process cache → Keychain (silent, no UI).
    /// On a successful Keychain read the value is backfilled into every cache.
    static func load(provider: String) -> String? {
        let account = account(forProvider: provider)

        // 1. File cache (fastest, survives restarts).
        if let fileValue = CredentialFileCache.loadAll()[account] {
            cacheLock.withLock { processCache[account] = fileValue }
            return fileValue
        }

        // 2. Process cache.
        if let cached = cacheLock.withLock({ processCache[account] }) {
            return cached
        }

        // 3. Keychain (silent read, no password prompt).
        if let keychainValue = load(service: service, account: account) {
            backfill(account: account, value: keychainValue)
            return keychainValue
        }

        // 4. Migrate a legacy v2 item on first access, then drop the old entry.
        if let legacy = load(service: legacyService, account: account) {
            _ = store(keychainOnly: legacy, account: account)
            _ = clear(service: legacyService, account: account)
            backfill(account: account, value: legacy)
            return legacy
        }

        return nil
    }

    /// Write path: Keychain + file cache + process cache.
    /// Returns `true` when the value was persisted to at least one layer.
    @discardableResult
    static func store(cookie: String?, provider: String) -> Bool {
        let account = account(forProvider: provider)
        guard let cookie, !cookie.isEmpty else { return clear(provider: provider) }

        // Keychain first (canonical).
        _ = store(keychainOnly: cookie, account: account)

        // File cache.
        CredentialFileCache.store(provider: account, value: cookie)

        // Process cache.
        cacheLock.withLock { processCache[account] = cookie }

        // Drop any legacy v2 entry.
        _ = clear(service: legacyService, account: account)
        return true
    }

    /// Removes a credential from all three layers.
    @discardableResult
    static func clear(provider: String) -> Bool {
        let account = account(forProvider: provider)
        cacheLock.withLock { processCache.removeValue(forKey: account) }
        CredentialFileCache.clear(provider: account)
        _ = clear(service: service, account: account)
        _ = clear(service: legacyService, account: account)
        return true
    }

    // MARK: - Keychain helpers

    /// Write a value to the Keychain (v3 service). Uses `applyNoUI` for the
    /// update attempt; add uses the default ACL (no custom wildcard, since
    /// `SecTrustedApplicationCreateFromPath` is deprecated on macOS 14+).
    @discardableResult
    private static func store(keychainOnly value: String, account: String) -> Bool {
        let data = Data(value.utf8)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        applyNoUI(to: &query)
        let updateStatus = SecItemUpdate(query as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            UsageStore.log("Keychain cookie update failed (\(account)): OSStatus \(updateStatus)")
            return false
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "TokenBar Cache"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // Note: no kSecAttrAccess — modern securityd on macOS 14+ ignores the
        // deprecated SecTrustedApplication path-based ACL, so we rely on the
        // default Keychain access control. The file cache handles the "no
        // prompt on restart" use case instead.
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            UsageStore.log("Keychain cookie add failed (\(account)): OSStatus \(addStatus)")
        }
        return addStatus == errSecSuccess
    }

    private static func load(service: String, account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        applyNoUI(to: &query)
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            if status != errSecItemNotFound, status != errSecInteractionNotAllowed {
                UsageStore.log("Keychain cookie read failed (\(account)): OSStatus \(status)")
            }
            return nil
        }
        return value
    }

    @discardableResult
    private static func clear(service: String, account: String) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        applyNoUI(to: &query)
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Prevents the Keychain from showing a password dialog. Used for all
    /// routine reads and writes so the app never prompts the user on its own.
    private static func applyNoUI(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = uiFailPolicy as CFString
    }

    private static let uiFailPolicy: String = {
        let securityPath = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(securityPath, RTLD_NOW) else { return "u_AuthUIF" }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else {
            return "u_AuthUIF"
        }
        let pointer = symbol.assumingMemoryBound(to: CFString?.self)
        return (pointer.pointee as String?) ?? "u_AuthUIF"
    }()

    /// Backfill the file cache and process cache after a successful Keychain read.
    private static func backfill(account: String, value: String) {
        cacheLock.withLock { processCache[account] = value }
        CredentialFileCache.store(provider: account, value: value)
    }
}