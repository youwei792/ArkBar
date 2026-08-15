import Foundation

// MARK: - API response types

/// grok2api admin envelope: `{"data": ...}` on success, `{"error": {...}}`
/// on failure (stable `code` strings like `adminUnauthorized`).
struct GrokPoolEnvelope<T: Decodable>: Decodable {
    let data: T?
    let error: GrokPoolErrorBody?

    enum CodingKeys: String, CodingKey { case data, error }
}

struct GrokPoolErrorBody: Decodable {
    let code: String?
    let message: String?
}

struct GrokPoolLoginResponse: Decodable {
    let accessToken: String?
    let accessTokenExpiresAt: String?

    enum CodingKeys: String, CodingKey {
        case accessToken
        case accessTokenExpiresAt
    }
}

struct GrokPoolDashboardDTO: Decodable {
    let period: String?
    let resources: GrokPoolResourcesDTO?
    let usage: GrokPoolUsageDTO?
    let topModels: [GrokPoolModelUsageDTO]?
}

struct GrokPoolResourcesDTO: Decodable {
    let activeAccounts: Int?
    let totalAccounts: Int?

    enum CodingKeys: String, CodingKey {
        case activeAccounts
        case totalAccounts
    }
}

struct GrokPoolUsageDTO: Decodable {
    let requests: Int?
    let successfulRequests: Int?
    let failedRequests: Int?
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let reasoningTokens: Int?
    let tokens: Int?
    /// Billed cost in 10^-10 USD ticks (1 USD = 10^10 ticks).
    let billedCostUsdTicks: Int64?
    /// Success rate as a 0–100 percentage.
    let successRate: Double?

    enum CodingKeys: String, CodingKey {
        case requests
        case successfulRequests
        case failedRequests
        case inputTokens
        case cachedInputTokens
        case outputTokens
        case reasoningTokens
        case tokens
        case billedCostUsdTicks = "billedCostUsdTicks"
        case successRate
    }
}

struct GrokPoolModelUsageDTO: Decodable {
    let model: String?
    let tokens: Int?
}

// MARK: - Provider

/// GrokPool (grok2api admin gateway) monitoring.
///
/// The gateway migrated off the new-api console API. Balance/usage now comes
/// from the grok2api admin panel: log in with the administrator username and
/// password (`POST /api/admin/v1/auth/login`), then read the 24-hour dashboard
/// (`GET /api/admin/v1/dashboard?period=24h`) with the short-lived Bearer
/// access token. There is no money balance — the ring shows the request
/// success rate and the status item can show the 24h billed cost.
final class GrokPoolProvider: UsageProvider {
    let displayName = "GrokPool"

    static let defaultBaseURL = "https://grok.axonlume.com"
    /// grok2api reports billed cost in 10^-10 USD ticks.
    static let usdTicksPerDollar: Double = 10_000_000_000
    private static let accessTokenRefreshMargin: TimeInterval = 60
    private static let timeoutSeconds: TimeInterval = 15

    private let settings: AppSettings
    private let transport: any HTTPTransport
    private let tokenCache = GrokPoolTokenCache()

    init(settings: AppSettings, transport: any HTTPTransport = defaultHTTPTransport()) {
        self.settings = settings
        self.transport = transport
    }

    /// Credentials are resolved inside `fetch` (settings Keychain / env).
    func isAvailable(environment: [String: String]) -> Bool {
        true
    }

    func fetch(environment: [String: String]) async throws -> ProviderSnapshot {
        let baseURL = await MainActor.run {
            Self.normalizedBaseURL(self.settings.grokPoolBaseURL)
        } ?? GrokPoolCredentialResolver.baseURL(environment: environment)
            ?? Self.defaultBaseURL
        let username = await MainActor.run {
            Self.trimmed(self.settings.grokPoolUsername)
        } ?? GrokPoolCredentialResolver.username(environment: environment)
        let password = await MainActor.run {
            Self.trimmed(self.settings.grokPoolPassword)
        } ?? GrokPoolCredentialResolver.password(environment: environment)
        guard let username, let password else {
            throw UsageError.grokPoolMissingCredentials
        }

        let token = try await ensureAccessToken(baseURL: baseURL, username: username, password: password)
        do {
            return try await loadDashboard(baseURL: baseURL, accessToken: token, username: username, password: password)
        } catch UsageError.grokPoolInvalidToken {
            // Access token was revoked or the session rotated; re-login once.
            invalidateTokenCache()
            let freshToken = try await login(baseURL: baseURL, username: username, password: password)
            return try await loadDashboard(baseURL: baseURL, accessToken: freshToken.token, username: username, password: password)
        }
    }

    // MARK: - Auth

    private func ensureAccessToken(baseURL: String, username: String, password: String) async throws -> String {
        if let token = tokenCache.validToken(margin: Self.accessTokenRefreshMargin) {
            return token
        }
        let login = try await login(baseURL: baseURL, username: username, password: password)
        tokenCache.store(token: login.token, expiresAt: login.expiresAt)
        return login.token
    }

    private func invalidateTokenCache() {
        tokenCache.invalidate()
    }

    /// Logs in as the gateway administrator and returns the Bearer access token.
    func login(baseURL: String, username: String, password: String) async throws -> GrokPoolLogin {
        let endpoint = try Self.endpoint(baseURL: baseURL, path: "/api/admin/v1/auth/login")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds
        let body = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
        ])
        request.httpBody = body

        let response = try await transport.response(for: request)
        if let error = Self.envelopeError(from: response) {
            throw error
        }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw UsageError.grokPoolInvalidToken
            }
            throw UsageError.apiError(statusCode: response.statusCode, message: "GrokPool admin login")
        }
        return try Self.decodeLogin(data: response.data)
    }

    // MARK: - Dashboard

    private func loadDashboard(
        baseURL: String, accessToken: String,
        username: String, password: String) async throws -> ProviderSnapshot
    {
        let dashboard = try await fetchDashboard(baseURL: baseURL, accessToken: accessToken)
        let summary = Self.makeSummary(dashboard)
        // The ring reflects request success: 0% used means everything
        // succeeded, so the remaining percent is the success rate itself.
        let window = UsageWindow(
            label: "24h",
            usedPercent: max(0, min(100, 100 - summary.successRate)),
            used: nil, total: nil, resetsAt: nil)
        let plan = PlanSnapshot(
            id: "grokpool",
            product: .grokPool,
            edition: nil,
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: [window],
            expiryDate: nil,
            errorMessage: nil,
            deepseek: nil,
            nebula: nil,
            grokPool: summary)
        return ProviderSnapshot(
            providerName: displayName,
            authMethod: "admin",
            plans: [plan],
            updatedAt: Date(),
            errorMessage: nil)
    }

    func fetchDashboard(baseURL: String, accessToken: String) async throws -> GrokPoolDashboardDTO {
        let endpoint = try Self.endpoint(baseURL: baseURL, path: "/api/admin/v1/dashboard")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw UsageError.networkError("Invalid GrokPool dashboard URL")
        }
        components.queryItems = [
            URLQueryItem(name: "period", value: "24h"),
        ]
        guard let url = components.url else {
            throw UsageError.networkError("Could not construct GrokPool dashboard URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await transport.response(for: request)
        if let error = Self.envelopeError(from: response) {
            throw error
        }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw UsageError.grokPoolInvalidToken
            }
            throw UsageError.apiError(statusCode: response.statusCode, message: "GrokPool dashboard")
        }
        return try Self.decodeDashboard(data: response.data)
    }

    /// Maps a grok2api `{"error":{code,message}}` envelope to a UsageError.
    /// `adminUnauthorized` / `adminInvalidToken` mean the access token is
    /// stale; everything else is a plain API error.
    private static func envelopeError(from response: HTTPResponse) -> UsageError? {
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let code = error["code"] as? String
        else {
            return nil
        }
        let message = (error["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lower = code.lowercased()
        if lower.contains("unauthorized")
            || lower.contains("invalidtoken")
            || lower.contains("expired")
            || lower.contains("notfound")
        {
            if lower.contains("notfound") {
                // Endpoint not found is a real API shape change, not auth.
                return .apiError(statusCode: response.statusCode, message: message.isEmpty ? code : message)
            }
            return .grokPoolInvalidToken
        }
        if !message.isEmpty {
            return .apiError(statusCode: response.statusCode, message: message)
        }
        return .apiError(statusCode: response.statusCode, message: code)
    }

    private static func endpoint(baseURL: String, path: String) throws -> URL {
        guard let url = URL(string: baseURL + path) else {
            throw UsageError.networkError("Invalid GrokPool base URL")
        }
        return url
    }

    static func normalizedBaseURL(_ raw: String) -> String? {
        let trimmed = trimmed(raw) ?? ""
        guard !trimmed.isEmpty else { return nil }
        var value = trimmed
        // Accept a trailing "/v1" (OpenAI-compatible base) or a trailing slash.
        if value.hasSuffix("/v1") { value = String(value.dropLast(3)) }
        while value.hasSuffix("/") { value = String(value.dropLast()) }
        return value
    }

    // MARK: - Decoding (static for tests)

    static func decodeLogin(data: Data) throws -> GrokPoolLogin {
        let envelope: GrokPoolEnvelope<GrokPoolLoginResponse>
        do {
            envelope = try JSONDecoder().decode(GrokPoolEnvelope<GrokPoolLoginResponse>.self, from: data)
        } catch {
            throw UsageError.parseFailed(error.localizedDescription)
        }
        if let errorBody = envelope.error {
            throw Self.error(from: errorBody)
        }
        guard let token = envelope.data?.accessToken, !token.isEmpty else {
            throw UsageError.parseFailed("Missing GrokPool login access token")
        }
        return GrokPoolLogin(
            token: token,
            expiresAt: parseExpiry(envelope.data?.accessTokenExpiresAt))
    }

    static func decodeDashboard(data: Data) throws -> GrokPoolDashboardDTO {
        let envelope: GrokPoolEnvelope<GrokPoolDashboardDTO>
        do {
            envelope = try JSONDecoder().decode(GrokPoolEnvelope<GrokPoolDashboardDTO>.self, from: data)
        } catch {
            throw UsageError.parseFailed(error.localizedDescription)
        }
        if let errorBody = envelope.error {
            throw Self.error(from: errorBody)
        }
        guard let dto = envelope.data else {
            throw UsageError.parseFailed("Missing GrokPool dashboard data")
        }
        return dto
    }

    private static func error(from body: GrokPoolErrorBody) -> UsageError {
        let code = body.code ?? ""
        let message = (body.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = code.lowercased()
        if lower.contains("unauthorized") || lower.contains("invalidtoken") || lower.contains("expired") {
            return .grokPoolInvalidToken
        }
        if !message.isEmpty {
            return .apiError(statusCode: 401, message: message)
        }
        return .apiError(statusCode: 401, message: code.isEmpty ? "GrokPool admin API" : code)
    }

    /// Builds the display summary from a dashboard DTO. Uses the 24-hour
    /// window the provider always requests; token totals are the input/output/
    /// reasoning split, and the top model is the highest-token model.
    static func makeSummary(_ dashboard: GrokPoolDashboardDTO) -> GrokPoolSummary {
        let usage = dashboard.usage
        let resources = dashboard.resources
        let requests = usage?.requests ?? 0
        let successRate = usage?.successRate
            ?? (requests > 0 ? Double(usage?.successfulRequests ?? 0) / Double(requests) * 100 : 0)
        let topModel = dashboard.topModels?
            .filter { $0.model != nil && !$0.model!.isEmpty }
            .max { a, b in
                let ta = a.tokens ?? 0
                let tb = b.tokens ?? 0
                if ta == tb { return (a.model ?? "") > (b.model ?? "") }
                return ta < tb
            }?.model
        return GrokPoolSummary(
            period: dashboard.period ?? "24h",
            requests: requests,
            successfulRequests: usage?.successfulRequests ?? 0,
            failedRequests: usage?.failedRequests ?? 0,
            successRate: successRate,
            inputTokens: usage?.inputTokens ?? 0,
            cachedInputTokens: usage?.cachedInputTokens ?? 0,
            outputTokens: usage?.outputTokens ?? 0,
            reasoningTokens: usage?.reasoningTokens ?? 0,
            tokens: usage?.tokens ?? 0,
            costUSD: usdTicksToValue(usage?.billedCostUsdTicks ?? 0),
            activeAccounts: resources?.activeAccounts ?? 0,
            totalAccounts: resources?.totalAccounts ?? 0,
            topModel: topModel)
    }

    /// 1 USD = 10^10 ticks (grok2api's `USD_TICKS`).
    static func usdTicksToValue(_ ticks: Int64) -> Double {
        Double(ticks) / usdTicksPerDollar
    }

    /// Parses a Go `time.Time` RFC3339 timestamp, tolerating optional
    /// fractional seconds. Returns nil for missing or malformed values (the
    /// caller then treats the token as expired and re-logins).
    private static func parseExpiry(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct GrokPoolLogin: Sendable, Equatable {
    let token: String
    let expiresAt: Date?
}

// MARK: - Token cache

/// Thread-safe cache for the short-lived admin access token (15-minute TTL).
/// `@unchecked Sendable` because the NSLock guards every access.
private final class GrokPoolTokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var expiresAt: Date?

    func validToken(margin: TimeInterval) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let token, let expiresAt,
              expiresAt > Date().addingTimeInterval(margin)
        else {
            return nil
        }
        return token
    }

    func store(token: String, expiresAt: Date?) {
        lock.lock()
        defer { lock.unlock() }
        self.token = token
        self.expiresAt = expiresAt
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        token = nil
        expiresAt = nil
    }
}

// MARK: - Credentials

/// Reads GrokPool administrator credentials from the environment. Settings
/// (Keychain) values take precedence; these are the fallback.
enum GrokPoolCredentialResolver {
    static let usernameKeys = ["GROKPOOL_USERNAME", "GROK_POOL_USERNAME"]
    static let passwordKeys = ["GROKPOOL_PASSWORD", "GROK_POOL_PASSWORD"]
    static let baseURLKeys = ["GROKPOOL_BASE_URL", "GROK_POOL_BASE_URL"]

    static func username(environment: [String: String]) -> String? {
        value(for: usernameKeys, environment: environment)
    }

    static func password(environment: [String: String]) -> String? {
        value(for: passwordKeys, environment: environment)
    }

    static func baseURL(environment: [String: String]) -> String? {
        value(for: baseURLKeys, environment: environment)
    }

    private static func value(for keys: [String], environment: [String: String]) -> String? {
        for key in keys {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                continue
            }
            var value = raw
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
