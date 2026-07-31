import AppKit
import Foundation
import SweetCookieKit

/// Imports only OpenCode's authentication cookie from an existing browser
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
    private static let query = BrowserCookieQuery(domains: ["opencode.ai", "app.opencode.ai"])

    /// Prefer the browser most TokenBar users already use for the dashboard, then
    /// try the remaining SweetCookieKit catalog without duplicates.
    private static let preferredBrowsers: [Browser] = {
        let preferred: [Browser] = [.chrome, .arc, .safari, .edge, .brave, .firefox]
        return preferred + Browser.defaultImportOrder.filter { !preferred.contains($0) }
    }()

    static func configureKeychainPrompt() {
        BrowserCookieKeychainPromptHandler.handler = { context in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    presentKeychainPrompt(label: context.label)
                }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        presentKeychainPrompt(label: context.label)
                    }
                }
            }
        }
    }

    @MainActor
    private static func presentKeychainPrompt(label: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L(.openCodeBrowserAccessTitle)
        alert.informativeText = String(
            format: L(.openCodeBrowserAccessMessage),
            label)
        alert.addButton(withTitle: L(.continueAction))
        alert.runModal()
    }

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
            toOpen: URL(string: "https://opencode.ai")!),
           let defaultBrowser = browser(forApplicationURL: appURL),
           available.contains(defaultBrowser)
        {
            return defaultBrowser
        }

        return available.first
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
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                let rawHeader = cookies
                    .filter { $0.name == "auth" || $0.name == "__Host-auth" }
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
