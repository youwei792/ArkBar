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
    /// macOS to ask for the login password every time ArkBar's signature
    /// changed. v2 is read with an explicit no-UI policy and trusts the stable
    /// app/executable paths when the item is created.
    /// The v1 item is intentionally never queried: even a “noninteractive”
    /// legacy-Keychain read can surface the old Allow/Deny password dialog on
    /// some macOS versions.
    static let service = "com.arkbar.cache.v2"
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
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            UsageStore.log("Keychain cookie update failed (\(account)): OSStatus \(updateStatus)")
            return false
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "ArkBar OpenCode Cookie"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let access = cacheAccessControl() {
            add[kSecAttrAccess as String] = access
        }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            UsageStore.log("Keychain cookie add failed (\(account)): OSStatus \(addStatus)")
        } else {
            cacheLock.withLock {
                processCache[account] = cookie
            }
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
        return clear(service: service, account: account)
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

    private static func cacheAccessControl() -> SecAccess? {
        let paths = trustedApplicationPaths()
        guard !paths.isEmpty else { return nil }

        var applications: [SecTrustedApplication] = []
        for path in paths {
            var application: SecTrustedApplication?
            let status = path.withCString { cPath in
                secTrustedApplicationCreateFromPath(cPath, &application)
            }
            if status == errSecSuccess, let application {
                applications.append(application)
            }
        }
        guard !applications.isEmpty else { return nil }

        var access: SecAccess?
        let status = secAccessCreate(
            "ArkBar Cache" as CFString,
            applications as CFArray,
            &access)
        return status == errSecSuccess ? access : nil
    }

    private static func trustedApplicationPaths() -> [String] {
        var paths: [String] = []
        func append(_ path: String?) {
            guard let path,
                  !path.isEmpty,
                  FileManager.default.fileExists(atPath: path),
                  !paths.contains(path)
            else { return }
            paths.append(path)
        }

        append(Bundle.main.bundleURL.path)
        append(Bundle.main.executableURL?.path)
        append("/Applications/ArkBar.app")
        append("/Applications/ArkBar.app/Contents/MacOS/ArkBar")
        return paths
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
