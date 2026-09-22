import AppKit
import Foundation
import SweetCookieKit

/// Imports SenseNova's console session cookies from an existing browser
/// sign-in. The console authenticates with an OAuth2/cookie session on
/// platform.sensenova.cn; identity cookies are kept, tracking cookies dropped.
enum SenseNovaBrowserSession {
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
                    return "\(L(.errorSenseNovaBrowserSessionMissing))（\(detail)）"
                }
                return L(.errorSenseNovaBrowserSessionMissing)
            }
        }
    }

    private static let cachedCredentialAccount = "sensenova-browser"
    private static let sourceLabelKey = "tokenbar.senseNovaBrowserSourceLabel"
    private static let browserKey = "tokenbar.senseNovaBrowser"
    private static let client = BrowserCookieClient()
    private static let query = BrowserCookieQuery(
        domains: ["platform.sensenova.cn", "sensenova.cn", "console.sensecore.cn"])

    private static let preferredBrowsers: [Browser] = {
        let preferred: [Browser] = [.chrome, .arc, .safari, .edge, .brave, .firefox]
        return preferred + Browser.defaultImportOrder.filter { !preferred.contains($0) }
    }()

    /// True when a Cookie header carries the console's Hydra sign-in cookie.
    ///
    /// Analytics cookies (`Hm_lvt_*`, `gr_user_id`) are set on the very same
    /// `sensenova.cn` domains, so a plain "is the header non-empty" check let a
    /// logged-out browser produce a "successful" import full of tracking
    /// cookies. Every later request then went out with garbage credentials and
    /// the tab reported a session problem instead of "not signed in".
    static func hasSignInCookie(_ header: String) -> Bool {
        header.split(separator: ";").contains { pair in
            let name = pair.prefix { $0 != "=" }
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            return name.contains("authentication_session")
        }
    }

    /// Cookie names only — never values — so the diagnostic can show what the
    /// browser actually held without exporting credentials.
    static func cookieNames(_ header: String) -> String {
        header.split(separator: ";")
            .map { $0.prefix { $0 != "=" }.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: ", ")
    }

    static func cachedSession() -> Session? {
        guard let raw = CookieKeychainStore.load(provider: cachedCredentialAccount),
              !raw.isEmpty
        else {
            return nil
        }
        // A cached bag predating the sign-in check is worthless (and misleading
        // to keep probing); drop it so the provider reports "not signed in".
        guard hasSignInCookie(raw) else {
            UsageStore.log("SenseNova cached session has no sign-in cookie; ignoring it")
            return nil
        }
        let source = UserDefaults.standard.string(forKey: sourceLabelKey) ?? L(.browserSession)
        return Session(cookieHeader: raw, sourceLabel: source)
    }

    /// Ordered import candidates: previously-used first, then the stored
    /// source label, then Chrome (its profile directory is TCC-protected so
    /// store enumeration can fail even though per-file reads work once Full
    /// Disk Access is granted), then the remaining readable Chromium/Gecko
    /// browsers, Safari last.
    static func browserCandidates() -> [Browser] {
        var out: [Browser] = []
        if let raw = UserDefaults.standard.string(forKey: browserKey),
           let previous = Browser(rawValue: raw)
        {
            out.append(previous)
        }
        if let source = UserDefaults.standard.string(forKey: sourceLabelKey),
           let inferred = preferredBrowsers.first(where: {
               source.localizedCaseInsensitiveContains($0.displayName)
           })
        {
            out.append(inferred)
        }
        out.append(.chrome)
        let available = preferredBrowsers.filter { !client.stores(for: $0).isEmpty }
        out.append(contentsOf: available.filter {
            $0.usesChromiumProfileStore || $0.usesGeckoProfileStore
        })
        out.append(contentsOf: available.filter {
            !($0.usesChromiumProfileStore || $0.usesGeckoProfileStore)
        })
        var seen: Set<Browser> = []
        return out.filter { seen.insert($0).inserted }
    }

    /// Interactive-only import: try every candidate in order and keep the
    /// first browser that yields a real sign-in session. A Keychain denial on
    /// one candidate must not abort the rest.
    static func importSessionInteractively(from _: Browser?) throws -> Session {
        var lastError: Error?
        var seenNames: [String] = []
        for candidate in browserCandidates() {
            do {
                let sources = try client.records(matching: query, in: candidate)
                for source in sources where !source.records.isEmpty {
                    let header = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                        .filter { !$0.name.lowercased().hasPrefix("utm_") }
                        .map { "\($0.name)=\($0.value)" }
                        .joined(separator: "; ")
                    guard !header.isEmpty else { continue }
                    guard hasSignInCookie(header) else {
                        seenNames.append("\(candidate.displayName)/\(source.label): " + cookieNames(header))
                        continue
                    }
                    let session = Session(cookieHeader: header, sourceLabel: source.label)
                    cache(session, browser: candidate)
                    return session
                }
            } catch {
                UsageStore.log("SenseNova import \(candidate.displayName) skipped: \(error.localizedDescription)")
                lastError = error
            }
        }
        // Nothing anywhere carried the session cookie: the user is simply not
        // signed in (or signed in in a browser we cannot read). The cookie
        // names go to the diagnostic only — values never leave the machine.
        if !seenNames.isEmpty {
            SenseNovaProvider.writeDiagnostic(
                "import: no sign-in cookie. found: \(seenNames.joined(separator: " | "))")
            throw ImportError.noSession(nil)
        }
        let detail = lastError?.localizedDescription ?? L(.notFound)
        SenseNovaProvider.writeDiagnostic("import-failed: \(detail)")
        throw ImportError.noSession(detail)
    }

    static func clearCache() {
        CookieKeychainStore.clear(provider: cachedCredentialAccount)
        UserDefaults.standard.removeObject(forKey: sourceLabelKey)
        UserDefaults.standard.removeObject(forKey: browserKey)
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
}
