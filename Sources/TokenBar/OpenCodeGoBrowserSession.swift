import AppKit
import Foundation
import SweetCookieKit

/// Imports OpenCode's authentication cookies from an existing browser
/// session. The extracted credential is cached in TokenBar's Keychain so routine
/// five-minute refreshes do not repeatedly decrypt the browser cookie store.
enum OpenCodeGoBrowserSession {
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
                    return "\(L(.errorOpenCodeBrowserSessionMissing))（\(detail)）"
                }
                return L(.errorOpenCodeBrowserSessionMissing)
            }
        }
    }

    private static let cachedCredentialAccount = "opencode-browser"
    private static let sourceLabelKey = "tokenbar.opencodeBrowserSourceLabel"
    private static let browserKey = "tokenbar.opencodeBrowser"
    private static let client = BrowserCookieClient()
    private static let domains = ["opencode.ai", "app.opencode.ai"]
    private static let query = BrowserCookieQuery(domains: domains)

    /// Prefer the browser most TokenBar users already use for the dashboard, then
    /// try the remaining SweetCookieKit catalog without duplicates.
    private static let preferredBrowsers: [Browser] = {
        let preferred: [Browser] = [.chrome, .arc, .safari, .edge, .brave, .firefox]
        return preferred + Browser.defaultImportOrder.filter { !preferred.contains($0) }
    }()

    static func cachedSession() -> Session? {
        guard let raw = CookieKeychainStore.load(provider: cachedCredentialAccount),
              let header = OpenCodeGoCookieSupport.requestCookieHeader(from: raw)
        else {
            return nil
        }
        let source = UserDefaults.standard.string(forKey: sourceLabelKey) ?? L(.browserSession)
        return Session(cookieHeader: header, sourceLabel: source)
    }

    /// Picks one browser for an explicit import. Restricting one user action to
    /// one browser mirrors CodexBar's retry scope and prevents a Chrome → Arc →
    /// Edge prompt cascade when several Chromium browsers are installed.
    @MainActor
    static func browserForInteractiveImport() -> Browser? {
        let available = preferredBrowsers.filter { !client.stores(for: $0).isEmpty }
        let counts = preferredBrowsers
            .map { "\($0.displayName)=\(client.stores(for: $0).count)" }
            .joined(separator: " ")
        // Diagnostic (names/counts only — never cookie values) so a support
        // session can see which browsers the process could even enumerate.
        OpenCodeGoProvider.writeDiagnostic("browsers: \(counts) [webkit-blocked=true]")
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

        // Prefer Chromium/Gecko over WebKit: Safari's cookie file requires
        // Full Disk Access, which a normally-launched menu-bar app never has,
        // so a Safari pick always fails even when another installed browser
        // holds the session (e.g. ChatGPT Atlas). Checked before the default-
        // browser resolution because the system default is often Safari while
        // the actual session lives in a Chromium browser.
        if let nonWebKit = available.first(where: {
            $0.usesChromiumProfileStore || $0.usesGeckoProfileStore
        }) {
            return nonWebKit
        }

        if let appURL = NSWorkspace.shared.urlForApplication(
            toOpen: URL(string: "https://opencode.ai")!),
           let defaultBrowser = browser(forApplicationURL: appURL),
           available.contains(defaultBrowser)
        {
            return defaultBrowser
        }

        return available.first
    }

    /// Chrome's (and Safari's) data directories are privacy-protected on
    /// current macOS: a process without Full Disk Access sees zero cookie
    /// stores even though the browser is installed and in use. Detecting that
    /// shape lets the error say what to do instead of "no session found".
    static func chromiumBlockedByPrivacyControls() -> Bool {
        guard NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.google.Chrome") != nil
        else { return false }
        return client.stores(for: .chrome).isEmpty
    }

    /// Performs the only interactive browser-cookie read in TokenBar.
    ///
    /// This must only be called from the explicit “re-import browser session”
    /// settings action. Startup, scheduled refreshes, menu-open refreshes, and
    /// ordinary Refresh actions must use `cachedSession()` instead; otherwise
    /// Chromium can repeatedly ask for the user's Keychain password.
    static func importSessionInteractively(from browser: Browser?) throws -> Session {
        guard let browser else {
            throw ImportError.noSession(L(.notFound))
        }
        do {
            let sources = try client.records(matching: query, in: browser)
            for source in sources where !source.records.isEmpty {
                // Strict domain boundary: the query matches by substring, so
                // lookalike domains (opencode.ai.evil.tld) could ride along.
                let records = CookieDomainFilter.filter(source.records, allowedDomains: domains)
                guard !records.isEmpty else { continue }
                let cookies = BrowserCookieClient.makeHTTPCookies(records, origin: query.origin)
                OpenCodeGoProvider.writeDiagnostic(
                    "import browser=\(source.label) domains=\(query.domains.joined(separator: ",")) "
                        + "cookies=\(cookies.map(\.name).sorted().joined(separator: ","))")
                let rawHeader = cookies
                    .filter {
                        // The legacy `auth` cookie authenticates the old
                        // server-fn endpoints; the Go usage data now lives
                        // behind the console app, which authenticates with its
                        // own session cookie.
                        $0.name == "auth" || $0.name == "__Host-auth"
                            || $0.name == "console_session" || $0.name == "__Host-console_session"
                    }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                guard let header = OpenCodeGoCookieSupport.requestCookieHeader(from: rawHeader) else {
                    continue
                }
                let session = Session(cookieHeader: header, sourceLabel: source.label)
                cache(session, browser: browser)
                return session
            }
        } catch {
            UsageStore.log("OpenCode browser session import failed \(browser.displayName): \(error.localizedDescription)")
            if Self.chromiumBlockedByPrivacyControls() {
                throw ImportError.noSession(L(.errorOpenCodeNeedsFullDiskAccess))
            }
            throw ImportError.noSession("\(browser.displayName): \(error.localizedDescription)")
        }
        throw ImportError.noSession(browser.displayName)
    }

    static func clearCache() {
        CookieKeychainStore.clear(provider: cachedCredentialAccount)
        UserDefaults.standard.removeObject(forKey: sourceLabelKey)
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
