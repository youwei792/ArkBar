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

    static func cachedSession() -> Session? {
        guard let raw = CookieKeychainStore.load(provider: cachedCredentialAccount),
              !raw.isEmpty
        else {
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
    /// first browser that yields matching cookies. A Keychain denial on one
    /// candidate must not abort the rest.
    static func importSessionInteractively(from _: Browser?) throws -> Session {
        var lastError: Error?
        for candidate in browserCandidates() {
            do {
                let sources = try client.records(matching: query, in: candidate)
                for source in sources where !source.records.isEmpty {
                    let header = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                        .filter { !$0.name.lowercased().hasPrefix("utm_") }
                        .map { "\($0.name)=\($0.value)" }
                        .joined(separator: "; ")
                    guard !header.isEmpty else { continue }
                    let session = Session(cookieHeader: header, sourceLabel: source.label)
                    cache(session, browser: candidate)
                    return session
                }
            } catch {
                UsageStore.log("SenseNova import \(candidate.displayName) skipped: \(error.localizedDescription)")
                lastError = error
            }
        }
        if let lastError {
            let message = lastError.localizedDescription
            SenseNovaProvider.writeDiagnostic("import-failed: \(message)")
            throw ImportError.noSession(message)
        }
        SenseNovaProvider.writeDiagnostic("import-failed: no matching cookies in any browser")
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
}
