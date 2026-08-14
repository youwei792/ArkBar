import AppKit
import Foundation
import SweetCookieKit

/// Imports the Kimi For Coding sign-in from an existing browser or Kimi.app session.
///
/// The Code API (`api.kimi.com/coding/v1/usages`) works with an API key, but the
/// shared-pool monthly ring comes from `www.kimi.com` membership endpoints.
/// They accept the `access_token` JWT from `https://www.kimi.com` localStorage
/// (either `iss=account` from Kimi.app or `iss=user-center` from a browser
/// refresh) as long as it has not expired. Access tokens live only ~15 minutes,
/// so the companion `refresh_token` (90-day TTL) is captured and used to mint
/// fresh access tokens via `GET /api/auth/token/refresh`.
enum KimiBrowserSession {
    struct Session: Sendable, Equatable {
        /// JWT used as Bearer + `kimi-auth` cookie against the console APIs.
        let authToken: String
        /// Long-lived refresh JWT used to obtain a new access token.
        let refreshToken: String?
        let sourceLabel: String
    }

    /// A resolved credential: the best available access token, optionally a
    /// refresh token, and where it came from.
    struct Credential: Sendable, Equatable {
        let accessToken: String?
        let refreshToken: String?
        let source: String
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
    private static let refreshCredentialAccount = "kimi-refresh"
    private static let sourceLabelKey = "tokenbar.kimiBrowserSourceLabel"
    private static let browserKey = "tokenbar.kimiBrowser"
    private static let client = BrowserCookieClient()
    private static let query = BrowserCookieQuery(domains: [
        "www.kimi.com",
        "kimi.com",
    ])
    private static let localStorageOrigin = "https://www.kimi.com"

    private static let preferredBrowsers: [Browser] = {
        let preferred: [Browser] = [.chrome, .arc, .safari, .edge, .brave, .firefox]
        return preferred + Browser.defaultImportOrder.filter { !preferred.contains($0) }
    }()

    static func cachedSession() -> Session? {
        guard let raw = CookieKeychainStore.load(provider: cachedCredentialAccount),
              let token = Self.normalizeToken(raw)
        else {
            return nil
        }
        let source = UserDefaults.standard.string(forKey: sourceLabelKey) ?? L(.browserSession)
        let refresh = CookieKeychainStore.load(provider: refreshCredentialAccount)
            .flatMap(Self.normalizeToken)
        return Session(authToken: token, refreshToken: refresh, sourceLabel: source)
    }

    static func cachedSourceLabel() -> String? {
        UserDefaults.standard.string(forKey: sourceLabelKey)
    }

    /// Loads the cached refresh token from the Keychain, if present.
    static func cachedRefreshToken() -> String? {
        CookieKeychainStore.load(provider: refreshCredentialAccount)
            .flatMap(Self.normalizeToken)
    }

    /// Uses a refresh token to obtain a new access token. Returns the fresh
    /// access token (and a rotated refresh token if the server issued one).
    /// Mirrors Kimi.app's own flow: `GET /api/auth/token/refresh` with the
    /// refresh token as Bearer.
    static func refreshAccessToken(
        refreshToken: String,
        transport: any HTTPTransport = defaultHTTPTransport()
    ) async throws -> (accessToken: String, refreshToken: String?) {
        var request = URLRequest(url: URL(string: "https://www.kimi.com/api/auth/token/refresh")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(refreshToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("web", forHTTPHeaderField: "x-msh-platform")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw UsageError.kimiInvalidToken
            }
            let body = String(data: response.data, encoding: .utf8) ?? ""
            throw UsageError.apiError(
                statusCode: response.statusCode,
                message: "Kimi token refresh: \(body)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let accessToken = object["access_token"] as? String,
              normalizeToken(accessToken) != nil
        else {
            throw UsageError.parseFailed("Kimi token refresh: missing access_token")
        }
        let newRefresh = (object["refresh_token"] as? String).flatMap(normalizeToken)
        return (accessToken, newRefresh)
    }

    /// Best credential for the membership console.
    ///
    /// Resolution order:
    /// 1. If the cached access token is still valid, use it directly — this
    ///    avoids hitting the Keychain on every refresh (ad-hoc signed builds
    ///    trigger an ACL dialog on SecItemUpdate) and avoids replacing a
    ///    long-lived refreshed token with Kimi.app's short-lived one.
    /// 2. If the cached token is expired/missing, read Kimi.app localStorage
    ///    and pick the best available token.
    /// 3. If no valid access token exists but a refresh token does, return a
    ///    credential with a `nil` access token so the caller can refresh.
    static func resolveCredential(cached: String?) -> Credential? {
        let cachedRefresh = CookieKeychainStore.load(provider: refreshCredentialAccount)
            .flatMap(normalizeToken)

        // 1. Cached access token is still valid — use it as-is.
        if let cached = normalizeToken(cached),
           !accessTokenNeedsRefresh(cached)
        {
            return Credential(
                accessToken: cached,
                refreshToken: cachedRefresh,
                source: cachedSourceLabel() ?? "cache")
        }

        // 2. Cached token expired/missing — look for a desktop token.
        var candidates: [(token: String, source: String)] = []
        if let cached = normalizeToken(cached) {
            candidates.append((cached, cachedSourceLabel() ?? "cache"))
        }
        if let cachedRefresh {
            candidates.append((cachedRefresh, "cache"))
        }
        if let desktop = desktopTokens() {
            for token in desktop {
                candidates.append((token, "Kimi.app"))
            }
        }

        let best = preferredAuthToken(from: candidates)
        let refresh = bestRefreshToken(from: candidates) ?? cachedRefresh
        if let best {
            return Credential(
                accessToken: best.token,
                refreshToken: refresh,
                source: best.source)
        }
        // 3. No valid access token, but a refresh token may still work.
        if let refresh {
            return Credential(
                accessToken: nil,
                refreshToken: refresh,
                source: "refresh")
        }
        return nil
    }

    /// Reads Kimi.app's localStorage without touching the Keychain or browser
    /// cookie stores. Safe to call on a routine refresh.
    static func silentDesktopAccessToken() -> String? {
        desktopTokens().flatMap { tokens in
            preferredAuthToken(from: tokens.map { ($0, "Kimi.app") })?.token
        }
    }

    private static func desktopTokens() -> [String]? {
        let levelDB = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kimi-desktop/Local Storage/leveldb")
        guard FileManager.default.fileExists(atPath: levelDB.path) else { return nil }

        // First try the structured origin-filtered reader (works with older
        // Chromium key formats). For newer Electron builds (Kimi.app 3.1.8) the
        // LevelDB keys have a `0x01 0x23` prefix that the structured reader
        // doesn't decode, so fall back to raw token-candidate scanning which
        // doesn't depend on key parsing.
        let entries = ChromiumLocalStorageReader.readEntries(
            for: localStorageOrigin,
            in: levelDB,
            logger: nil)
        var tokens = tokens(from: entries)
        if tokens.isEmpty {
            let candidates = ChromiumLocalStorageReader.readTokenCandidates(
                in: levelDB, minimumLength: 100, logger: nil)
            for candidate in candidates {
                for token in extractJWTs(from: candidate) {
                    if !tokens.contains(token) { tokens.append(token) }
                }
            }
        }
        return tokens
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

    /// Explicit user action. Collects Kimi.app localStorage, the chosen browser's
    /// localStorage `access_token` + `refresh_token`, and the `kimi-auth` cookie,
    /// then persists the highest-ranked access token plus any valid refresh token.
    static func importSessionInteractively(from browser: Browser?) throws -> Session {
        var candidates: [(token: String, source: String)] = []
        if let desktop = desktopTokens() {
            for token in desktop {
                candidates.append((token, "Kimi.app"))
            }
        }
        if let browser {
            candidates.append(contentsOf: collectFromBrowser(browser))
        }
        guard let best = preferredAuthToken(from: candidates) else {
            throw ImportError.noSession(browser?.displayName)
        }
        let refresh = bestRefreshToken(from: candidates)
        let session = Session(
            authToken: best.token,
            refreshToken: refresh,
            sourceLabel: best.source)
        cache(session, browser: browser)
        return session
    }

    static func persist(token: String, sourceLabel: String) {
        cache(Session(authToken: token, refreshToken: nil, sourceLabel: sourceLabel), browser: nil)
    }

    /// Persists a refresh token separately from the access token so it
    /// survives access-token-only updates.
    static func persistRefreshToken(_ token: String?) {
        CookieKeychainStore.store(cookie: token, provider: refreshCredentialAccount)
    }

    /// Persists a refreshed access/refresh pair without changing the stored
    /// browser preference or source label.
    static func persistRefreshed(accessToken: String, refreshToken: String?) {
        CookieKeychainStore.store(cookie: accessToken, provider: cachedCredentialAccount)
        if let refreshToken {
            CookieKeychainStore.store(cookie: refreshToken, provider: refreshCredentialAccount)
        }
    }

    static func clearCache() {
        CookieKeychainStore.clear(provider: cachedCredentialAccount)
        CookieKeychainStore.clear(provider: refreshCredentialAccount)
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
            return normalizeToken(raw)
        }
        return normalizeToken(token)
    }

    /// Picks the JWT most likely to authenticate the Coding Plan console.
    /// Access tokens with `code_membership` rank highest; expired tokens and
    /// refresh tokens are skipped. The issuer (`account` from Kimi.app vs
    /// `user-center` from a browser refresh) does not affect authentication —
    /// both work as long as the token is unexpired.
    static func preferredAuthToken(
        from candidates: [(token: String, source: String)]) -> (token: String, source: String)?
    {
        struct Ranked {
            let token: String
            let source: String
            let score: Int
        }
        let now = Date().timeIntervalSince1970
        var ranked: [Ranked] = []
        for candidate in candidates {
            guard let token = normalizeToken(candidate.token) else { continue }
            let claims = decodeJWTPayload(token) ?? [:]
            let typ = (claims["typ"] as? String)?.lowercased()
            if typ == "refresh" { continue }
            if let exp = jwtExpiration(claims), exp < now { continue }
            var score = 1
            if typ == "access" { score += 4 }
            if claims["code_membership"] != nil { score += 3 }
            if (claims["iss"] as? String) == "account" { score += 1 }
            ranked.append(Ranked(token: token, source: candidate.source, score: score))
        }
        return ranked.max(by: { $0.score < $1.score }).map { ($0.token, $0.source) }
    }

    /// Returns the longest-lived unexpired refresh token among candidates.
    static func bestRefreshToken(
        from candidates: [(token: String, source: String)]) -> String?
    {
        let now = Date().timeIntervalSince1970
        var best: (token: String, exp: Double)?
        for candidate in candidates {
            guard let token = normalizeToken(candidate.token) else { continue }
            let claims = decodeJWTPayload(token) ?? [:]
            guard (claims["typ"] as? String)?.lowercased() == "refresh" else { continue }
            guard let exp = jwtExpiration(claims), exp > now else { continue }
            if best == nil || exp > best!.exp {
                best = (token, exp)
            }
        }
        return best?.token
    }

    /// Returns true when the access token is missing or expired.
    static func accessTokenNeedsRefresh(_ token: String?) -> Bool {
        guard let token = normalizeToken(token) else { return true }
        let claims = decodeJWTPayload(token) ?? [:]
        let typ = (claims["typ"] as? String)?.lowercased()
        guard typ != "refresh" else { return true }
        guard let exp = jwtExpiration(claims) else { return true }
        // Refresh a minute early to avoid racing the membership call.
        return exp - 60 < Date().timeIntervalSince1970
    }

    static func tokens(from entries: [ChromiumLocalStorageEntry]) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        func add(_ raw: String?) {
            guard let token = normalizeToken(raw), seen.insert(token).inserted else { return }
            found.append(token)
        }
        for entry in entries {
            let key = entry.key.lowercased()
            if key == "access_token" || key.hasSuffix("access_token") || key.contains("access-token") {
                add(entry.value)
            }
            for token in extractJWTs(from: entry.value) {
                add(token)
            }
        }
        return found
    }

    static func extractJWTs(from raw: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#)
        else {
            return []
        }
        let ns = raw as NSString
        return regex.matches(in: raw, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            normalizeToken(ns.substring(with: match.range))
        }
    }

    static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    static func normalizeToken(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.split(separator: ".").count == 3 else { return nil }
        return value
    }

    private static func jwtExpiration(_ claims: [String: Any]) -> TimeInterval? {
        if let exp = claims["exp"] as? Double { return exp }
        if let exp = claims["exp"] as? Int { return TimeInterval(exp) }
        if let exp = claims["exp"] as? Int64 { return TimeInterval(exp) }
        return nil
    }

    private static func collectFromBrowser(_ browser: Browser) -> [(token: String, source: String)] {
        var candidates: [(token: String, source: String)] = []
        let label = browser.displayName

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
                    for: localStorageOrigin,
                    in: levelDB,
                    logger: nil)
                var found = tokens(from: entries)
                if found.isEmpty {
                    let candidates = ChromiumLocalStorageReader.readTokenCandidates(
                        in: levelDB, minimumLength: 100, logger: nil)
                    for candidate in candidates {
                        for token in extractJWTs(from: candidate) where !found.contains(token) {
                            found.append(token)
                        }
                    }
                }
                for token in found {
                    candidates.append((token, "\(label) localStorage"))
                }
            }
        }

        do {
            let sources = try client.records(matching: query, in: browser)
            for source in sources where !source.records.isEmpty {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                let rawHeader = cookies
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                if let token = requestAuthToken(from: rawHeader) {
                    candidates.append((token, "\(source.label) cookie"))
                }
            }
        } catch {
            UsageStore.log("Kimi browser cookie import failed \(label): \(error.localizedDescription)")
        }
        return candidates
    }

    private static func cache(_ session: Session, browser: Browser?) {
        guard CookieKeychainStore.store(
            cookie: session.authToken,
            provider: cachedCredentialAccount)
        else {
            return
        }
        if let refreshToken = session.refreshToken {
            CookieKeychainStore.store(
                cookie: refreshToken,
                provider: refreshCredentialAccount)
        }
        UserDefaults.standard.set(session.sourceLabel, forKey: sourceLabelKey)
        if let browser {
            UserDefaults.standard.set(browser.rawValue, forKey: browserKey)
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
