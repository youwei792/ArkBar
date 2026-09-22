import CryptoKit
import Foundation
import Security
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Mints and keeps the bearer token that SenseNova's console quota API accepts.
///
/// `GET {origin}/lite/console/v1/tokenplan/pool-usage` only takes the OAuth
/// token the console SPA itself uses: the plan API key is rejected with
/// `Authentication type 'apikey' is not enabled`, and the session cookie alone
/// answers `auth_header_missing`. The SPA gets its token from a Hydra
/// authorization-code + PKCE dance, and for this first-party client Hydra
/// auto-approves both the login and the consent hop, so an imported
/// `oauth2_authentication_session` cookie is enough to complete the same dance
/// headlessly. Access tokens live three hours, so the refresh token is kept
/// too and the browser session is only needed again once refreshing fails.
enum SenseNovaConsoleAuth {
    struct Tokens: Sendable, Equatable {
        let accessToken: String
        let refreshToken: String
        /// When `accessToken` stops being usable.
        let expiresAt: Date
    }

    /// An error from the dance, carrying the server's own reason so the card can
    /// say what actually stopped it.
    struct AuthFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let authorizeURL = "https://platform.sensenova.cn/oauth2/auth"
    private static let tokenURL = "https://platform.sensenova.cn/oauth2/token"
    private static let clientID = "nova"
    private static let redirectURI = "https://platform.sensenova.cn"
    private static let scope = "openid offline offline_access"
    private static let keychainAccount = "sensenova-token"
    /// Swap the access token out before it actually lapses so a refresh never
    /// rides an expiry race.
    static let expiryMargin: TimeInterval = 120
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    private static let maxHops = 8

    /// A usable access token: cached, then refreshed from the stored refresh
    /// token, then minted from the imported browser session.
    ///
    /// - Parameter sessionCookie: the imported console Cookie header, used only
    ///   when no refreshable token is on file.
    static func accessToken(sessionCookie: String) async throws -> Tokens {
        let cached = load()
        if let cached, cached.expiresAt > Date().addingTimeInterval(expiryMargin) {
            return cached
        }
        if let refresh = cached?.refreshToken, !refresh.isEmpty,
           let refreshed = try? await exchangeRefreshToken(refresh)
        {
            store(refreshed)
            return refreshed
        }
        guard !sessionCookie.isEmpty else {
            throw AuthFailure(message: L(.errorSenseNovaMissingCredentials))
        }
        let minted = try await authorize(sessionCookie: sessionCookie)
        store(minted)
        return minted
    }

    /// Drops the cached token so the next call re-mints, for the case where the
    /// API rejects a token that had not expired yet.
    static func invalidateCachedToken() {
        CookieKeychainStore.clear(provider: keychainAccount)
    }

    // MARK: - Authorization-code + PKCE dance

    private static func authorize(sessionCookie: String) async throws -> Tokens {
        let verifier = randomURLSafeString(bytes: 48)
        let challenge = base64URLNoPadding(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafeString(bytes: 8)
        var jar = seedJar(from: sessionCookie)
        var url = authoredURL(challenge: challenge, state: state) ?? URL(string: authorizeURL)!

        for _ in 0 ..< maxHops {
            let hop = try await get(url, cookies: jar)
            jar.append(contentsOf: hop.setCookies)
            guard let target = hop.redirectURL else {
                // A 200 instead of a redirect means Hydra wants an interactive
                // step (login or consent) that cannot be answered headlessly.
                throw AuthFailure(message: L(.errorSenseNovaInteractiveAuth))
            }
            if let code = queryItem("code", in: target) {
                let returnedState = queryItem("state", in: target) ?? state
                return try await exchangeCode(code, state: returnedState, verifier: verifier)
            }
            if let error = queryItem("error", in: target) {
                let reason = queryItem("error_description", in: target) ?? error
                throw AuthFailure(message: String(format: L(.errorSenseNovaAuthRejected), reason))
            }
            url = target
        }
        throw AuthFailure(message: L(.errorSenseNovaAuthLoop))
    }

    private static func authoredURL(challenge: String, state: String) -> URL? {
        guard var components = URLComponents(string: authorizeURL) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scope),
        ]
        return components.url
    }

    private static func exchangeCode(_ code: String, state: String, verifier: String) async throws -> Tokens {
        try await postToken([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "state": state,
            "redirect_uri": redirectURI,
        ])
    }

    private static func exchangeRefreshToken(_ refresh: String) async throws -> Tokens {
        try await postToken([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refresh,
        ])
    }

    private static func postToken(_ fields: [String: String]) async throws -> Tokens {
        guard let url = URL(string: tokenURL) else {
            throw AuthFailure(message: L(.errorSenseNovaTokenEndpoint))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://platform.sensenova.cn/", forHTTPHeaderField: "Referer")
        request.httpBody = Data(formUrlEncoded(fields).utf8)

        let (data, http) = try await OAuthSession.shared.data(for: request)
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AuthFailure(message: String(
                format: L(.errorSenseNovaTokenFailed),
                http.statusCode,
                String(detail.prefix(160))))
        }
        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        let payload: TokenResponse
        do {
            payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw AuthFailure(message: L(.errorSenseNovaTokenUnparseable))
        }
        guard !payload.access_token.isEmpty else {
            throw AuthFailure(message: L(.errorSenseNovaTokenMissing))
        }
        return Tokens(
            accessToken: payload.access_token,
            // Hydra rotates refresh tokens; keep the previous one if none came back.
            refreshToken: payload.refresh_token ?? load()?.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(payload.expires_in ?? 3600))
    }

    // MARK: - Hop transport

    private struct Hop {
        let redirectURL: URL?
        let setCookies: [HTTPCookie]
    }

    private static func get(_ url: URL, cookies: [HTTPCookie]) async throws -> Hop {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        // Cookies are assembled by hand: the chain crosses two registrable
        // domains, and automatic storage would drop the CSRF cookie Hydra
        // echoes back on the next hop.
        request.httpShouldHandleCookies = false
        let header = cookieHeader(cookies, for: url)
        if !header.isEmpty {
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("https://platform.sensenova.cn/console", forHTTPHeaderField: "Referer")

        let (_, http) = try await OAuthSession.shared.data(for: request)
        var redirect: URL?
        if let location = http.value(forHTTPHeaderField: "Location") {
            redirect = URL(string: location, relativeTo: url)?.absoluteURL
        }
        let fields = http.allHeaderFields.reduce(into: [String: String]()) { acc, entry in
            if let name = entry.key as? String, let value = entry.value as? String {
                acc[name] = value
            }
        }
        return Hop(
            redirectURL: redirect,
            setCookies: HTTPCookie.cookies(withResponseHeaderFields: fields, for: url))
    }

    // MARK: - Cookies

    /// Seeds the jar with the sign-in cookie only. The stored `*_csrf` cookies
    /// are deliberately left out: each one is bound to a single challenge, and
    /// replaying an old one makes Hydra answer `request_forbidden … CSRF value
    /// from the token does not match`.
    static func seedJar(from header: String) -> [HTTPCookie] {
        header.split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].lowercased().contains("authentication_session") else {
                return nil
            }
            return HTTPCookie(properties: [
                .name: parts[0],
                .value: parts[1],
                .domain: "platform.sensenova.cn",
                .path: "/",
            ])
        }
    }

    /// The Cookie header for `url`, keeping only unexpired cookies whose domain
    /// and path match it.
    static func cookieHeader(_ cookies: [HTTPCookie], for url: URL) -> String {
        guard let host = url.host?.lowercased() else { return "" }
        let now = Date()
        return cookies.compactMap { cookie in
            if let expiry = cookie.expiresDate, expiry < now { return nil }
            let domain = cookie.domain.lowercased()
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard host == bare || host.hasSuffix("." + bare) else { return nil }
            let path = cookie.path.isEmpty ? "/" : cookie.path
            guard url.path.isEmpty || url.path.hasPrefix(path) else { return nil }
            return "\(cookie.name)=\(cookie.value)"
        }.joined(separator: "; ")
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
    }

    private static func store(_ tokens: Tokens) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Stored(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt)),
            let raw = String(data: data, encoding: .utf8)
        else { return }
        CookieKeychainStore.store(cookie: raw, provider: keychainAccount)
    }

    private static func load() -> Tokens? {
        guard let raw = CookieKeychainStore.load(provider: keychainAccount),
              let data = raw.data(using: .utf8)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(Stored.self, from: data),
              !stored.accessToken.isEmpty
        else { return nil }
        return Tokens(
            accessToken: stored.accessToken,
            refreshToken: stored.refreshToken,
            expiresAt: stored.expiresAt)
    }

    // MARK: - Small helpers

    static func randomURLSafeString(bytes: Int) -> String {
        var data = [UInt8](repeating: 0, count: bytes)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes, &data) == errSecSuccess else {
            return base64URLNoPadding(Data((0 ..< bytes).map { _ in UInt8.random(in: .min ... .max) }))
        }
        return base64URLNoPadding(Data(data))
    }

    static func base64URLNoPadding(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func pkceChallenge(for verifier: String) -> String {
        base64URLNoPadding(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func formUrlEncoded(_ fields: [String: String]) -> String {
        fields
            .sorted { $0.key < $1.key }
            .map { "\(percentEncoded($0.key))=\(percentEncoded($0.value))" }
            .joined(separator: "&")
    }

    static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func queryItem(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}

/// Session used for the OAuth hops and the token POST. Redirects are captured
/// rather than followed, so each hop can carry the previous hop's cookies.
private enum OAuthSession {
    static let shared = Implementation()

    final class Implementation: @unchecked Sendable {
        private let configuration: URLSessionConfiguration = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            return configuration
        }()

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let delegate = RedirectCapturingDelegate()
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<(Data, HTTPURLResponse?), Error>) in
                delegate.attach(continuation)
                session.dataTask(with: request).resume()
            }
            guard let http = response else {
                throw URLError(.unsupportedURL)
            }
            return (data, http)
        }
    }

    private final class RedirectCapturingDelegate: NSObject, URLSessionDataDelegate {
        private var continuation: CheckedContinuation<(Data, HTTPURLResponse?), Error>?
        private var body = Data()
        private var redirect: HTTPURLResponse?

        func attach(_ continuation: CheckedContinuation<(Data, HTTPURLResponse?), Error>) {
            self.continuation = continuation
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void)
        {
            // Stop here: the caller replays the chain itself so the Set-Cookie
            // headers of each hop can be paired with the next request.
            redirect = response
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            body.append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            defer { continuation = nil }
            if let error {
                continuation?.resume(throwing: error)
                return
            }
            continuation?.resume(returning: (body, redirect ?? task.response as? HTTPURLResponse))
        }
    }
}
