import AppKit
import Foundation
import SweetCookieKit

/// Imports the Kimi For Coding sign-in from an existing browser session.
///
/// The Code API (`api.kimi.com/coding/v1/usages`) works with an API key, but the
/// shared-pool and Code 7-day windows come from the `www.kimi.com` membership
/// console endpoints, which authenticate with the `kimi-auth` cookie (a JWT).
/// This imports that cookie, mirrors Nebula's explicit-import flow.
enum KimiBrowserSession {
    struct Session: Sendable, Equatable {
        /// The JWT value of the `kimi-auth` cookie.
        let authToken: String
        let sourceLabel: String
    }

    enum ImportError: LocalizedError {
        case noSession(String?)

        var errorDescription: String? {
            switch self {
            case let .noSession(detail):
                if let detail, !detail.isEmpty {
                    return "\(L(.errorKimiBrowserSessionMissing))（\(detail)）"
                }
                return L(.errorKimiBrowserSessionMissing)
            }
        }
    }

    private static let cachedCredentialAccount = "kimi-auth"
    private static let sourceLabelKey = "tokenbar.kimiBrowserSourceLabel"
    private static let browserKey = "tokenbar.kimiBrowser"
    private static let client = BrowserCookieClient()
    private static let query = BrowserCookieQuery(domains: [
        "www.kimi.com",
        "kimi.com",
    ])

    private static let preferredBrowsers: [Browser] = {
        let preferred: [Browser] = [.chrome, .arc, .safari, .edge, .brave, .firefox]
        return preferred + Browser.defaultImportOrder.filter { !preferred.contains($0) }
    }()

    static func cachedSession() -> Session? {
        guard let raw = CookieKeychainStore.load(provider: cachedCredentialAccount),
              let token = Self.requestAuthToken(from: raw)
        else {
            return nil
        }
        let source = UserDefaults.standard.string(forKey: sourceLabelKey) ?? L(.browserSession)
        return Session(authToken: token, sourceLabel: source)
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
            toOpen: URL(string: "https://www.kimi.com/code/console")!),
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
                guard let token = Self.requestAuthToken(from: rawHeader) else {
                    continue
                }
                let session = Session(authToken: token, sourceLabel: source.label)
                cache(session, browser: browser)
                return session
            }
        } catch {
            UsageStore.log("Kimi browser session import failed \(browser.displayName): \(error.localizedDescription)")
            throw ImportError.noSession("\(browser.displayName): \(error.localizedDescription)")
        }
        throw ImportError.noSession(browser.displayName)
    }

    static func clearCache() {
        CookieKeychainStore.clear(provider: cachedCredentialAccount)
        UserDefaults.standard.removeObject(forKey: sourceLabelKey)
        UserDefaults.standard.removeObject(forKey: browserKey)
    }

    /// Extract the `kimi-auth` cookie value (a JWT) from a raw Cookie header.
    static func requestAuthToken(from raw: String) -> String? {
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
        guard let token = pairs.first(where: { $0.0.lowercased() == "kimi-auth" })?.1 else {
            return nil
        }
        return token
    }

    private static func cache(_ session: Session, browser: Browser) {
        guard CookieKeychainStore.store(
            cookie: session.authToken,
            provider: cachedCredentialAccount)
        else {
            return
        }
        UserDefaults.standard.set(session.sourceLabel, forKey: sourceLabelKey)
        UserDefaults.standard.set(browser.rawValue, forKey: browserKey)
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
