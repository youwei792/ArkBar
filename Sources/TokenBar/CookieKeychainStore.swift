import Foundation
#if canImport(Security)
import Darwin
import LocalAuthentication
import Security
#endif

/// Stores only the user-provided OpenCode session header in the macOS Keychain.
/// It is deliberately separate from `UserDefaults`, which may hold harmless UI
/// preferences but must never contain session credentials.
enum CookieKeychainStore {
    /// v1 used the default Keychain ACL. Local ad-hoc rebuilds therefore caused
    /// macOS to ask for the login password every time TokenBar's signature
    /// changed. v2 trusted app paths, but macOS re-validates the application's
    /// signature against path-created ACLs, so ad-hoc re-signing still prompted.
    /// v3 creates items with a wildcard ACL (no signature/path binding) so a
    /// re-signed bundle can always read its own credentials without prompting.
    /// v1/v2 items are migrated to v3 on first access and then deleted; legacy
    /// items are never queried after migration.
    static let service = "com.tokenbar.cache.v3"
    private static let legacyService = "com.tokenbar.cache.v2"
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var processCache: [String: String] = [:]

    static func account(forProvider provider: String) -> String {
        "cookie.\(provider)"
    }

    @discardableResult
    static func store(cookie: String?, provider: String) -> Bool {
        let account = account(forProvider: provider)
        guard let cookie, !cookie.isEmpty else { return clear(provider: provider) }
        let data = Data(cookie.utf8)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        applyNoUI(to: &query)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            cacheLock.withLock {
                processCache[account] = cookie
            }
            clear(service: legacyService, account: account)
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            UsageStore.log("Keychain cookie update failed (\(account)): OSStatus \(updateStatus)")
            return false
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "TokenBar Cache"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrAccess as String] = wildcardAccessControl()
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            UsageStore.log("Keychain cookie add failed (\(account)): OSStatus \(addStatus)")
        } else {
            cacheLock.withLock {
                processCache[account] = cookie
            }
            clear(service: legacyService, account: account)
        }
        return addStatus == errSecSuccess
    }

    static func load(provider: String) -> String? {
        let account = account(forProvider: provider)
        if let cached = cacheLock.withLock({ processCache[account] }) {
            return cached
        }

        if let current = load(service: service, account: account) {
            cacheLock.withLock {
                processCache[account] = current
            }
            return current
        }
        // Migrate a legacy v2 item on first access, then drop the old entry.
        if let legacy = load(service: legacyService, account: account),
           store(cookie: legacy, provider: provider)
        {
            _ = clear(service: legacyService, account: account)
            return legacy
        }
        return nil
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
    static func clear(provider: String) -> Bool {
        let account = account(forProvider: provider)
        _ = cacheLock.withLock {
            processCache.removeValue(forKey: account)
        }
        let current = clear(service: service, account: account)
        let legacy = clear(service: legacyService, account: account)
        return current && legacy
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

    /// An ACL that trusts every application (a NULL-path SecTrustedApplication
    /// is a wildcard). This keeps ad-hoc re-signed builds from triggering the
    /// Keychain authorization dialog on every launch.
    private static func wildcardAccessControl() -> SecAccess {
        var application: SecTrustedApplication?
        _ = secTrustedApplicationCreateFromPath(nil, &application)

        var access: SecAccess?
        let applications: [SecTrustedApplication] = application.map { [$0] } ?? []
        let status = secAccessCreate("TokenBar Cache" as CFString, applications as CFArray, &access)
        if status == errSecSuccess, let access {
            return access
        }
        // Fallback: create with an empty trusted list (no ACL restrictions).
        var fallback: SecAccess?
        _ = secAccessCreate("TokenBar Cache" as CFString, [] as CFArray, &fallback)
        return fallback!
    }

    private typealias SecTrustedApplicationCreateFromPathFunction = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafeMutablePointer<SecTrustedApplication?>?) -> OSStatus
    private typealias SecAccessCreateFunction = @convention(c) (
        CFString,
        CFArray,
        UnsafeMutablePointer<SecAccess?>?) -> OSStatus

    private nonisolated(unsafe) static let securityFrameworkHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW)
    }()

    private static func securitySymbol(named name: String) -> UnsafeMutableRawPointer? {
        guard let securityFrameworkHandle else { return nil }
        return dlsym(securityFrameworkHandle, name)
    }

    private static func secTrustedApplicationCreateFromPath(
        _ path: UnsafePointer<CChar>?,
        _ application: UnsafeMutablePointer<SecTrustedApplication?>?) -> OSStatus
    {
        guard let symbol = securitySymbol(named: "SecTrustedApplicationCreateFromPath") else {
            return errSecInternalComponent
        }
        let function = unsafeBitCast(symbol, to: SecTrustedApplicationCreateFromPathFunction.self)
        return function(path, application)
    }

    private static func secAccessCreate(
        _ descriptor: CFString,
        _ trustedList: CFArray,
        _ access: UnsafeMutablePointer<SecAccess?>?) -> OSStatus
    {
        guard let symbol = securitySymbol(named: "SecAccessCreate") else {
            return errSecInternalComponent
        }
        let function = unsafeBitCast(symbol, to: SecAccessCreateFunction.self)
        return function(descriptor, trustedList, access)
    }
}
