import AppKit
import Foundation
import SweetCookieKit

/// Imports the StepFun console's session cookies from an existing browser
/// sign-in. The console authenticates with cookies (no Bearer token), so the
/// full identity cookie set is kept (only `utm_*` tracking cookies are
/// dropped). The extracted header is cached in Keychain so routine refreshes
/// do not repeatedly decrypt the browser cookie store.
enum StepFunBrowserSession {
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
                    return "\(L(.errorStepFunBrowserSessionMissing))（\(detail)）"
                }
                return L(.errorStepFunBrowserSessionMissing)
            }
        }
    }

    private static let cachedCredentialAccount = "stepfun-browser"
    private static let sourceLabelKey = "tokenbar.stepFunBrowserSourceLabel"
    private static let browserKey = "tokenbar.stepFunBrowser"
    private static let client = BrowserCookieClient()
    private static let query = BrowserCookieQuery(domains: ["platform.stepfun.com", "account.stepfun.com", "stepfun.com"])

    private static let preferredBrowsers: [Browser] = {
        let preferred: [Browser] = [.chrome, .arc, .safari, .edge, .brave, .firefox]
        return preferred + Browser.defaultImportOrder.filter { !preferred.contains($0) }
    }()

    static func cachedSession() -> Session? {
        guard let raw = CookieKeychainStore.load(provider: cachedCredentialAccount),
              !raw.isEmpty
        else {
            return nil
        }
        let source = UserDefaults.standard.string(forKey: sourceLabelKey) ?? L(.browserSession)
        return Session(cookieHeader: raw, sourceLabel: source)
    }

    /// Ordered import candidates: the previously-used browser first, then the
    /// stored source label, then Chrome (its profile directory is
    /// TCC-protected so store enumeration can fail even though the per-file
    /// reads work once Full Disk Access is granted), then the remaining
    /// readable Chromium/Gecko browsers, Safari last.
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

    /// Interactive-only import (the settings action): try every candidate in
    /// order and keep the first browser that yields any matching cookies.
    /// A Keychain denial on one candidate must not abort the rest. Keeps every
    /// cookie except `utm_*` tracking cookies, since the console session cookie
    /// names are not published.
    static func importSessionInteractively(from _: Browser?) throws -> Session {
        var lastError: Error?
        StepFunProvider.writeImportDiagnostic(
            "import-start candidates=\(browserCandidates().map(\.displayName))")
        for candidate in browserCandidates() {
            do {
                let sources = try client.records(matching: query, in: candidate)
                let names = sources.flatMap(\.records).map { "\($0.domain)::\($0.name)" }
                StepFunProvider.writeImportDiagnostic(
                    "candidate \(candidate.displayName) records=\(names.count) \(names.prefix(12))")
                for source in sources where !source.records.isEmpty {
                    let header = Self.requestCookieHeader(
                        from: BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin))
                    guard !header.isEmpty else { continue }
                    let session = Session(cookieHeader: header, sourceLabel: source.label)
                    Self.cache(session, browser: candidate)
                    return session
                }
            } catch {
                UsageStore.log("StepFun import \(candidate.displayName) skipped: \(error.localizedDescription)")
                lastError = error
            }
        }
        if let lastError {
            StepFunProvider.writeImportDiagnostic("import-failed: \(lastError.localizedDescription)")
            throw ImportError.noSession(lastError.localizedDescription)
        }
        StepFunProvider.writeImportDiagnostic("import-failed: no matching cookies in any browser")
        throw ImportError.noSession(L(.notFound))
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

    /// Keeps all identity cookies, dropping only `utm_*` tracking cookies.
    /// Returns nil when nothing survives.
    private static func requestCookieHeader(from cookies: [HTTPCookie]) -> String {
        cookies
            .filter { !$0.name.lowercased().hasPrefix("utm_") }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }
}
