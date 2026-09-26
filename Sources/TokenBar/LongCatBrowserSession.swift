import AppKit
import Foundation
import SweetCookieKit

/// Imports the LongCat console login session from an existing browser session.
///
/// LongCat's usage endpoints (`/api/lc-platform/v1/tokenUsage`) are console APIs
/// that authenticate with the browser cookies set when you sign in at
/// longcat.chat. There is no API-key usage endpoint on `api.longcat.chat`, so
/// the provider depends on a browser session (or a manually pasted Cookie
/// header). The console commonly uses session/auth cookies on the
/// `longcat.chat` domain; all of them are forwarded.
enum LongCatBrowserSession {
    struct Session: Sendable, Equatable {
        let cookieHeader: String
        let sourceLabel: String
    }

    enum ImportError: LocalizedError {
        case noSession(String?)

        var errorDescription: String? {
            switch self {
            case let .noSession(detail):
                if let detail, !detail.isEmpty {
                    return "\(L(.errorLongcatBrowserSessionMissing))（\(detail)）"
                }
                return L(.errorLongcatBrowserSessionMissing)
            }
        }
    }

    private static let cachedCredentialAccount = "longcat-browser"
    private static let sourceLabelKey = "tokenbar.longcatBrowserSourceLabel"
    private static let browserKey = "tokenbar.longcatBrowser"
    private static let client = BrowserCookieClient()
    private static let domains = [
        "longcat.chat",
        "www.longcat.chat",
    ]
    private static let query = BrowserCookieQuery(domains: domains)

    private static let preferredBrowsers: [Browser] = {
        let preferred: [Browser] = [.chrome, .arc, .safari, .edge, .brave, .firefox]
        return preferred + Browser.defaultImportOrder.filter { !preferred.contains($0) }
    }()

    static func cachedSession() -> Session? {
        guard let raw = CookieKeychainStore.load(provider: cachedCredentialAccount),
              let header = Self.requestCookieHeader(from: raw),
              Self.hasSessionCookie(header)
        else {
            return nil
        }
        let source = UserDefaults.standard.string(forKey: sourceLabelKey) ?? L(.browserSession)
        return Session(cookieHeader: header, sourceLabel: source)
    }

    /// The console sign-in lives in Meituan's `passport_token_key` SSO cookie;
    /// without it the browser is signed out (or only carries analytics cookies).
    static func hasSessionCookie(_ header: String) -> Bool {
        for part in header.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            if trimmed[..<eq] == "passport_token_key" { return true }
        }
        return false
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
            toOpen: URL(string: "https://longcat.chat")!),
           let defaultBrowser = browser(forApplicationURL: appURL),
           available.contains(defaultBrowser)
        {
            return defaultBrowser
        }
        return available.first
    }

    /// Explicit user action only. Routine refreshes use `cachedSession()`.
    ///
    /// Tries the preferred browser first, then falls back to every other
    /// available browser so a login held in any browser can be imported.
    static func importSessionInteractively(from browser: Browser?) throws -> Session {
        var candidates = preferredBrowsers.filter { !client.stores(for: $0).isEmpty }
        // Put the preferred browser first if it is available.
        if let browser, let idx = candidates.firstIndex(of: browser) {
            candidates.remove(at: idx)
            candidates.insert(browser, at: 0)
        }
        guard !candidates.isEmpty else {
            UsageStore.log("LongCat browser import: no browser with a cookie store available")
            throw ImportError.noSession(L(.notFound))
        }
        UsageStore.log("LongCat browser import: will try \(candidates.map { $0.displayName }.joined(separator: " → "))")

        var lastError: Error?
        for candidate in candidates {
            do {
                let sources = try client.records(matching: query, in: candidate)
                let matched = sources.filter { !$0.records.isEmpty }
                UsageStore.log("LongCat browser import: \(candidate.displayName) → \(matched.count) source(s) with longcat.chat cookies")
                for source in matched {
                    // Strict domain boundary: the query matches by substring,
                    // so lookalike domains could otherwise ride along.
                    let records = CookieDomainFilter.filter(source.records, allowedDomains: domains)
                    guard !records.isEmpty else { continue }
                    let cookies = BrowserCookieClient.makeHTTPCookies(records, origin: query.origin)
                    let rawHeader = cookies
                        .map { "\($0.name)=\($0.value)" }
                        .joined(separator: "; ")
                    let cookieNames = cookies.map { $0.name }.joined(separator: ", ")
                    UsageStore.log("LongCat browser import: \(source.label) → \(cookies.count) cookies [\(cookieNames)], header length \(rawHeader.count)")
                    guard let header = Self.requestCookieHeader(from: rawHeader),
                          Self.hasSessionCookie(header)
                    else {
                        UsageStore.log("LongCat browser import: \(source.label) → no passport_token_key sign-in cookie")
                        continue
                    }
                    let session = Session(cookieHeader: header, sourceLabel: source.label)
                    cache(session, browser: candidate)
                    UsageStore.log("LongCat browser import: cached session from \(source.label) (header length \(header.count))")
                    return session
                }
            } catch {
                UsageStore.log("LongCat browser import: \(candidate.displayName) failed: \(error.localizedDescription)")
                lastError = error
            }
        }
        if let lastError {
            throw ImportError.noSession(lastError.localizedDescription)
        }
        throw ImportError.noSession(candidates.map { $0.displayName }.joined(separator: ", "))
    }

    static func clearCache() {
        CookieKeychainStore.clear(provider: cachedCredentialAccount)
        UserDefaults.standard.removeObject(forKey: sourceLabelKey)
        UserDefaults.standard.removeObject(forKey: browserKey)
    }

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
        let allowed: Set<String> = [
            "passport_token_key", "_lxsdk_cuid", "long_cat_region_key",
            "sankuai_strategy", "sankuai_ab_strategy",
        ]
        let chosen = pairs.filter { allowed.contains($0.0) }
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
