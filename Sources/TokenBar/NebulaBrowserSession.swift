import AppKit
import Foundation
import SweetCookieKit

/// Imports the Nebula console login session from an existing browser session.
///
/// Official docs only document model-call credentials (`/v1` + API key). Balance
/// and usage-log endpoints (`/api/user/self`, `/api/log/self`) are console APIs.
/// new-api consoles authenticate with a `session` cookie **plus** a
/// `New-Api-User: <user id>` header; the user id is stored in the site's
/// localStorage, so both are imported together.
enum NebulaBrowserSession {
    struct Session: Sendable, Equatable {
        let cookieHeader: String
        let userId: String?
        let sourceLabel: String
    }

    enum ImportError: LocalizedError {
        case noSession(String?)

        var errorDescription: String? {
            switch self {
            case let .noSession(detail):
                if let detail, !detail.isEmpty {
                    return "\(L(.errorNebulaBrowserSessionMissing))（\(detail)）"
                }
                return L(.errorNebulaBrowserSessionMissing)
            }
        }
    }

    private static let cachedCredentialAccount = "nebula-browser"
    private static let sourceLabelKey = "tokenbar.nebulaBrowserSourceLabel"
    private static let browserKey = "tokenbar.nebulaBrowser"
    private static let userIdKey = "tokenbar.nebulaUserId"
    private static let client = BrowserCookieClient()
    private static let query = BrowserCookieQuery(domains: [
        "apinebula.ai",
        "apinebula.com",
        "api.yhlxj.ai",
        "www.apinebula.ai",
        "www.apinebula.com",
    ])

    private static let preferredBrowsers: [Browser] = {
        let preferred: [Browser] = [.chrome, .arc, .safari, .edge, .brave, .firefox]
        return preferred + Browser.defaultImportOrder.filter { !preferred.contains($0) }
    }()

    static func cachedSession() -> Session? {
        guard let raw = CookieKeychainStore.load(provider: cachedCredentialAccount),
              let header = Self.requestCookieHeader(from: raw)
        else {
            return nil
        }
        let source = UserDefaults.standard.string(forKey: sourceLabelKey) ?? L(.browserSession)
        let userId = UserDefaults.standard.string(forKey: userIdKey)
        return Session(cookieHeader: header, userId: userId, sourceLabel: source)
    }

    static func cachedSourceLabel() -> String? {
        UserDefaults.standard.string(forKey: sourceLabelKey)
    }

    @MainActor
    static func browserForInteractiveImport() -> Browser? {
        let available = preferredBrowsers.filter { !client.stores(for: $0).isEmpty }
        guard !available.isEmpty else { return nil }

        if let raw = UserDefaults.standard.string(forKey: browserKey),
           let previous = Browser(rawValue: raw),
           available.contains(previous)
        {
            return previous
        }
        if let source = UserDefaults.standard.string(forKey: sourceLabelKey),
           let inferred = available.first(where: {
               source.localizedCaseInsensitiveContains($0.displayName)
           })
        {
            return inferred
        }
        if let appURL = NSWorkspace.shared.urlForApplication(
            toOpen: URL(string: "https://apinebula.ai")!),
           let defaultBrowser = browser(forApplicationURL: appURL),
           available.contains(defaultBrowser)
        {
            return defaultBrowser
        }
        return available.first
    }

    /// Explicit user action only. Routine refreshes use `cachedSession()`.
    static func importSessionInteractively(from browser: Browser?) throws -> Session {
        guard let browser else {
            throw ImportError.noSession(L(.notFound))
        }
        do {
            let sources = try client.records(matching: query, in: browser)
            for source in sources where !source.records.isEmpty {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                let rawHeader = cookies
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                guard let header = Self.requestCookieHeader(from: rawHeader) else {
                    continue
                }
                // The console's New-Api-User header needs the account id, which
                // new-api keeps in the site's localStorage (plaintext).
                let userId = Self.resolveUserId(browser: browser, sourceLabel: source.label)
                let session = Session(cookieHeader: header, userId: userId, sourceLabel: source.label)
                cache(session, browser: browser)
                return session
            }
        } catch {
            UsageStore.log("Nebula browser session import failed \(browser.displayName): \(error.localizedDescription)")
            throw ImportError.noSession("\(browser.displayName): \(error.localizedDescription)")
        }
        throw ImportError.noSession(browser.displayName)
    }

    static func clearCache() {
        CookieKeychainStore.clear(provider: cachedCredentialAccount)
        UserDefaults.standard.removeObject(forKey: sourceLabelKey)
        UserDefaults.standard.removeObject(forKey: browserKey)
        UserDefaults.standard.removeObject(forKey: userIdKey)
    }

    /// Reads the console account id from the browser's localStorage for the
    /// matching profile (localStorage is plaintext; no Keychain prompt).
    private static func resolveUserId(browser: Browser, sourceLabel: String) -> String? {
        let roots = ChromiumProfileLocator.roots(
            for: [browser],
            homeDirectories: BrowserCookieClient.defaultHomeDirectories())
        for root in roots {
            guard let directories = try? FileManager.default.contentsOfDirectory(
                at: root.url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for directory in directories {
                guard let isDirectory = try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                      isDirectory
                else { continue }
                let name = directory.lastPathComponent
                guard name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-") else { continue }
                let levelDB = directory.appendingPathComponent("Local Storage").appendingPathComponent("leveldb")
                guard FileManager.default.fileExists(atPath: levelDB.path) else { continue }
                let entries = ChromiumLocalStorageReader.readEntries(
                    for: "https://apinebula.ai",
                    in: levelDB,
                    logger: nil)
                if let userId = userID(from: entries) {
                    UsageStore.log("Nebula console user id resolved (\(sourceLabel))")
                    return userId
                }
            }
        }
        UsageStore.log("Nebula console user id not found in localStorage")
        return nil
    }

    /// new-api's console stores the account id either as `user_id` in
    /// localStorage or inside a JSON auth bundle (`user.id`).
    static func userID(from entries: [ChromiumLocalStorageEntry]) -> String? {
        for entry in entries where entry.key == "user_id" {
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, value.allSatisfy(\.isNumber) {
                return value
            }
        }
        for entry in entries {
            guard let data = entry.value.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            if let dict = object as? [String: Any] {
                if let user = dict["user"] as? [String: Any],
                   let id = user["id"] as? Int,
                   id > 0
                {
                    return String(id)
                }
                if let id = dict["id"] as? Int, id > 0, dict["username"] != nil {
                    return String(id)
                }
            }
        }
        return nil
    }

    /// Keep session-related cookies only. new-api commonly uses `session`.
    static func requestCookieHeader(from raw: String) -> String? {
        let pairs = raw
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { pair -> (String, String)? in
                guard let eq = pair.firstIndex(of: "=") else { return nil }
                let name = String(pair[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !value.isEmpty else { return nil }
                return (name, value)
            }
        let preferred = pairs.filter { name, _ in
            let lower = name.lowercased()
            return lower == "session"
                || lower.contains("session")
                || lower.contains("token")
                || lower == "cf_clearance"
        }
        let chosen = preferred.isEmpty ? pairs : preferred
        guard !chosen.isEmpty else { return nil }
        return chosen.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    private static func cache(_ session: Session, browser: Browser) {
        guard CookieKeychainStore.store(
            cookie: session.cookieHeader,
            provider: cachedCredentialAccount)
        else {
            return
        }
        UserDefaults.standard.set(session.sourceLabel, forKey: sourceLabelKey)
        UserDefaults.standard.set(browser.rawValue, forKey: browserKey)
        if let userId = session.userId {
            UserDefaults.standard.set(userId, forKey: userIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userIdKey)
        }
    }

    private static func browser(forApplicationURL url: URL) -> Browser? {
        let bundleID = Bundle(url: url)?.bundleIdentifier?.lowercased() ?? ""
        let appName = url.deletingPathExtension().lastPathComponent.lowercased()
        if bundleID == "com.apple.safari" || appName == "safari" { return .safari }
        if bundleID == "com.google.chrome" || appName == "google chrome" { return .chrome }
        if bundleID == "company.thebrowser.browser" || appName == "arc" { return .arc }
        if bundleID == "com.microsoft.edgemac" || appName == "microsoft edge" { return .edge }
        if bundleID == "com.brave.browser" || appName == "brave browser" { return .brave }
        if bundleID == "org.mozilla.firefox" || appName == "firefox" { return .firefox }
        if appName == "dia" { return .dia }
        return nil
    }
}
