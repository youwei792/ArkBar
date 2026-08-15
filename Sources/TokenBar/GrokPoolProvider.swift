import Foundation

// MARK: - API response types

private struct GrokPoolUserSelfResponse: Decodable {
    let success: Bool?
    let message: String?
    let data: GrokPoolUserSelfData?

    enum CodingKeys: String, CodingKey {
        case success, message, data
    }
}

private struct GrokPoolUserSelfData: Decodable {
    let quota: Int?
    let usedQuota: Int?
    let username: String?

    enum CodingKeys: String, CodingKey {
        case quota
        case usedQuota = "used_quota"
        case username
    }
}

private struct GrokPoolLogResponse: Decodable {
    let success: Bool?
    let message: String?
    let data: GrokPoolLogData?

    enum CodingKeys: String, CodingKey {
        case success, message, data
    }
}

private struct GrokPoolLogData: Decodable {
    let items: [GrokPoolLogItem]?
    let total: Int?

    enum CodingKeys: String, CodingKey {
        case items, total
    }
}

struct GrokPoolLogItem: Decodable {
    let modelName: String?
    let promptTokens: Int?
    let completionTokens: Int?
    /// Consumed quota for this request (raw quota units).
    let quota: Int?
    /// Unix seconds.
    let createdAt: TimeInterval?
    /// JSON blob; cache-hit tokens live under `cache_tokens`.
    let other: String?

    enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case quota
        case createdAt = "created_at"
        case other
    }

    init(
        modelName: String?,
        promptTokens: Int?,
        completionTokens: Int?,
        quota: Int?,
        createdAt: TimeInterval?,
        other: String? = nil)
    {
        self.modelName = modelName
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.quota = quota
        self.createdAt = createdAt
        self.other = other
    }

    /// Cache-hit input tokens, from the `other` JSON blob (`cache_tokens`).
    func cacheTokens() -> Int {
        guard let other,
              let data = other.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["cache_tokens"] as? Int
        else {
            return 0
        }
        return value
    }
}

// MARK: - Provider

/// GrokPool (grok-farm gateway, new-api based) balance + consumption
/// monitoring.
///
/// The gateway fronts new-api with a key-checked proxy: every endpoint —
/// including the console APIs — takes the same gateway key as
/// `Authorization: Bearer <key>` that /v1 model calls use. Unlike the
/// APINebula tab there is no browser-session path; settings/env supply the
/// key, and state is fully isolated from every other provider tab.
final class GrokPoolProvider: UsageProvider {
    let displayName = "GrokPool"

    /// new-api default conversion: 500000 quota = 1 currency unit (USD).
    static let defaultQuotaPerUnit: Double = 500_000
    static let defaultBaseURL = "https://grok.axonlume.com"

    private static let pageSize = 100
    private static let maxPages = 20
    private static let timeoutSeconds: TimeInterval = 15

    private let settings: AppSettings
    private let transport: any HTTPTransport

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
        let apiKey = await MainActor.run {
            Self.trimmed(self.settings.grokPoolAPIKey)
        } ?? GrokPoolCredentialResolver.apiKey(environment: environment)
        guard let apiKey else {
            throw UsageError.grokPoolMissingCredentials
        }

        let user = try await fetchUserSelf(baseURL: baseURL, apiKey: apiKey)

        let quotaPerUnit = user.quotaPerUnit
        let balance = Double(user.quota) / quotaPerUnit
        let usedTotal = Double(user.usedQuota) / quotaPerUnit

        // Consumption log is optional: paging can be slow or rejected, and the
        // balance card must still render.
        var stats: GrokPoolUsageStats?
        do {
            stats = try await fetchMonthlyLogs(baseURL: baseURL, apiKey: apiKey)
        } catch {
            UsageStore.log("✗ GrokPool consumption log unavailable: \(error.localizedDescription)")
        }

        let summary = NebulaSummary(
            currency: "USD",
            quotaPerUnit: quotaPerUnit,
            balance: balance,
            usedTotal: usedTotal,
            todayCost: stats?.todayCost,
            currentMonthCost: stats?.currentMonthCost,
            todayTokens: stats?.todayTokens ?? 0,
            currentMonthTokens: stats?.currentMonthTokens ?? 0,
            requestCount: stats?.requestCount ?? 0,
            currentMonthRequestCount: stats?.currentMonthRequestCount ?? 0,
            topModel: stats?.topModel,
            promptTokens: stats?.promptTokens ?? 0,
            completionTokens: stats?.completionTokens ?? 0,
            cacheTokens: stats?.cacheTokens ?? 0,
            usageAvailable: stats != nil)

        // Ring: cumulative spend vs (spend + balance) — the gateway's own numbers.
        let usedPercent = Self.ringUsedPercent(balance: balance, usedTotal: usedTotal)
        let window = UsageWindow(label: "balance", usedPercent: usedPercent,
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
            authMethod: "apikey",
            plans: [plan],
            updatedAt: Date(),
            errorMessage: nil)
    }

    /// Used share of the ring from the gateway's cumulative numbers.
    static func ringUsedPercent(balance: Double, usedTotal: Double) -> Double {
        guard balance > 0 else { return 100 }
        let total = usedTotal + balance
        guard total > 0 else { return 100 }
        return min(100, max(0, usedTotal / total * 100))
    }

    // MARK: - Endpoints

    private func fetchUserSelf(baseURL: String, apiKey: String) async throws -> GrokPoolUserSelf {
        var request = URLRequest(url: try Self.endpoint(baseURL: baseURL, path: "/api/user/self"))
        request.httpMethod = "GET"
        Self.apply(apiKey: apiKey, to: &request)
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await transport.response(for: request)
        if let bodyError = Self.consoleAPIError(from: response) {
            throw bodyError
        }
        guard response.statusCode == 200 else {
            // The gateway proxy rejects bad keys with a plain HTML 401 before
            // new-api ever sees the request.
            if response.statusCode == 401 || response.statusCode == 403 {
                throw UsageError.grokPoolInvalidToken
            }
            throw UsageError.apiError(statusCode: response.statusCode, message: "GrokPool user/self")
        }
        return try Self.decodeUserSelf(data: response.data)
    }

    /// Pulls the current month's consumption log page by page until the relay
    /// stops returning entries (or the page cap is hit).
    private func fetchMonthlyLogs(baseURL: String, apiKey: String) async throws -> GrokPoolUsageStats {
        let calendar = Calendar.current
        let now = Date()
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let startTimestamp = Int(startOfMonth.timeIntervalSince1970)
        let endTimestamp = Int(now.timeIntervalSince1970)

        var allItems: [GrokPoolLogItem] = []
        for page in 1 ... Self.maxPages {
            let items = try await fetchLogPage(
                baseURL: baseURL, apiKey: apiKey, page: page,
                startTimestamp: startTimestamp, endTimestamp: endTimestamp)
            if items.isEmpty { break }
            allItems.append(contentsOf: items)
        }
        return Self.aggregate(items: allItems, now: now, calendar: calendar)
    }

    private func fetchLogPage(
        baseURL: String, apiKey: String, page: Int,
        startTimestamp: Int, endTimestamp: Int) async throws -> [GrokPoolLogItem]
    {
        let endpoint = try Self.endpoint(baseURL: baseURL, path: "/api/log/self")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw UsageError.networkError("Invalid GrokPool log URL")
        }
        // new-api accepts both `p` and `page`; send both for compatibility.
        components.queryItems = [
            URLQueryItem(name: "p", value: String(page)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(Self.pageSize)),
            URLQueryItem(name: "start_timestamp", value: String(startTimestamp)),
            URLQueryItem(name: "end_timestamp", value: String(endTimestamp)),
        ]
        guard let url = components.url else {
            throw UsageError.networkError("Could not construct GrokPool log URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        Self.apply(apiKey: apiKey, to: &request)
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await transport.response(for: request)
        if let bodyError = Self.consoleAPIError(from: response) {
            throw bodyError
        }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw UsageError.grokPoolInvalidToken
            }
            throw UsageError.apiError(statusCode: response.statusCode, message: "GrokPool log/self")
        }
        return try Self.decodeLogPage(data: response.data)
    }

    private static func apply(apiKey: String, to request: inout URLRequest) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    /// new-api reports auth failures as `{"success":false,"message":...}`;
    /// the gateway proxy reports them as HTML bodies, which are ignored here
    /// and handled by the HTTP status check instead.
    private static func consoleAPIError(from response: HTTPResponse) -> UsageError? {
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            return nil
        }
        if let success = object["success"] as? Bool, success == false {
            let message = (object["message"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let lower = message.lowercased()
            if lower.contains("unauthorized")
                || lower.contains("invalid access token")
                || lower.contains("not logged in")
                || lower.contains("access token")
                || lower.contains("api key")
            {
                return .grokPoolInvalidToken
            }
            if !message.isEmpty {
                return .apiError(statusCode: response.statusCode, message: message)
            }
        }
        return nil
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

    static func decodeUserSelf(data: Data) throws -> GrokPoolUserSelf {
        let decoded: GrokPoolUserSelfResponse
        do {
            decoded = try JSONDecoder().decode(GrokPoolUserSelfResponse.self, from: data)
        } catch {
            throw UsageError.parseFailed(error.localizedDescription)
        }
        if decoded.success == false {
            let message = decoded.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let lower = message.lowercased()
            if lower.contains("unauthorized")
                || lower.contains("invalid access token")
                || lower.contains("not logged in")
                || lower.contains("api key")
            {
                throw UsageError.grokPoolInvalidToken
            }
            throw UsageError.apiError(statusCode: 401, message: message.isEmpty ? "GrokPool user/self" : message)
        }
        guard let userData = decoded.data else {
            throw UsageError.parseFailed("Missing GrokPool user/self data")
        }
        return GrokPoolUserSelf(
            quota: userData.quota ?? 0,
            usedQuota: userData.usedQuota ?? 0,
            quotaPerUnit: Self.defaultQuotaPerUnit)
    }

    static func decodeLogPage(data: Data) throws -> [GrokPoolLogItem] {
        let decoded: GrokPoolLogResponse
        do {
            decoded = try JSONDecoder().decode(GrokPoolLogResponse.self, from: data)
        } catch {
            throw UsageError.parseFailed(error.localizedDescription)
        }
        if decoded.success == false {
            let message = decoded.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let lower = message.lowercased()
            if lower.contains("unauthorized")
                || lower.contains("invalid access token")
                || lower.contains("not logged in")
                || lower.contains("api key")
            {
                throw UsageError.grokPoolInvalidToken
            }
            throw UsageError.apiError(statusCode: 401, message: message.isEmpty ? "GrokPool log/self" : message)
        }
        guard let items = decoded.data?.items else {
            throw UsageError.parseFailed("Missing GrokPool log/self data")
        }
        return items
    }

    static func aggregate(items: [GrokPoolLogItem], now: Date, calendar: Calendar) -> GrokPoolUsageStats {
        var todayTokens = 0
        var monthTokens = 0
        var todayCost: Double = 0
        var monthCost: Double = 0
        var todayRequests = 0
        var monthRequests = 0
        var monthPromptTokens = 0
        var monthCompletionTokens = 0
        var monthCacheTokens = 0
        var modelTokens: [String: Int] = [:]

        let todayStart = calendar.startOfDay(for: now)
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now

        for item in items {
            let createdAt = Date(timeIntervalSince1970: item.createdAt ?? 0)
            let prompt = item.promptTokens ?? 0
            let completion = item.completionTokens ?? 0
            let tokens = prompt + completion
            let cost = Double(item.quota ?? 0) / Self.defaultQuotaPerUnit

            if createdAt >= todayStart {
                todayTokens += tokens
                todayCost += cost
                todayRequests += 1
            }
            if createdAt >= monthStart {
                monthTokens += tokens
                monthCost += cost
                monthRequests += 1
                monthPromptTokens += prompt
                monthCompletionTokens += completion
                monthCacheTokens += item.cacheTokens()
                if let model = item.modelName {
                    modelTokens[model, default: 0] += tokens
                }
            }
        }

        let topModel = modelTokens.max {
            if $0.value == $1.value { return $0.key > $1.key }
            return $0.value < $1.value
        }?.key

        return GrokPoolUsageStats(
            todayTokens: todayTokens,
            currentMonthTokens: monthTokens,
            todayCost: todayCost,
            currentMonthCost: monthCost,
            requestCount: todayRequests,
            currentMonthRequestCount: monthRequests,
            topModel: topModel,
            promptTokens: monthPromptTokens,
            completionTokens: monthCompletionTokens,
            cacheTokens: monthCacheTokens)
    }

    private static func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Parsed domain values

struct GrokPoolUserSelf: Sendable, Equatable {
    /// Remaining quota in raw quota units.
    let quota: Int
    /// Cumulative consumed quota in raw quota units.
    let usedQuota: Int
    let quotaPerUnit: Double
}

struct GrokPoolUsageStats: Sendable, Equatable {
    let todayTokens: Int
    let currentMonthTokens: Int
    let todayCost: Double?
    let currentMonthCost: Double?
    let requestCount: Int
    let currentMonthRequestCount: Int
    let topModel: String?
    /// Current-month input (prompt) and output (completion) tokens.
    let promptTokens: Int
    let completionTokens: Int
    /// Current-month cache-hit input tokens (from the log's `other` blob).
    let cacheTokens: Int
}

// MARK: - Credentials

/// Reads GrokPool gateway credentials from the environment. Settings
/// (Keychain) values take precedence; these are the fallback.
enum GrokPoolCredentialResolver {
    static let apiKeyKeys = ["GROKPOOL_API_KEY", "GROK_POOL_API_KEY", "GROKFARM_API_KEY"]
    static let baseURLKeys = ["GROKPOOL_BASE_URL", "GROK_POOL_BASE_URL"]

    static func apiKey(environment: [String: String]) -> String? {
        value(for: apiKeyKeys, environment: environment)
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
