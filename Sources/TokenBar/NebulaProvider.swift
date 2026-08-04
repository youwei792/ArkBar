import Foundation

// MARK: - API response types

private struct NebulaUserSelfResponse: Decodable {
    let success: Bool?
    let message: String?
    let data: NebulaUserSelfData?

    enum CodingKeys: String, CodingKey {
        case success, message, data
    }
}

private struct NebulaUserSelfData: Decodable {
    let quota: Int?
    let usedQuota: Int?
    let username: String?

    enum CodingKeys: String, CodingKey {
        case quota
        case usedQuota = "used_quota"
        case username
    }
}

private struct NebulaLogResponse: Decodable {
    let success: Bool?
    let message: String?
    let data: NebulaLogData?

    enum CodingKeys: String, CodingKey {
        case success, message, data
    }
}

private struct NebulaLogData: Decodable {
    let items: [NebulaLogItem]?
    let total: Int?

    enum CodingKeys: String, CodingKey {
        case items, total
    }
}

struct NebulaLogItem: Decodable {
    let modelName: String?
    let promptTokens: Int?
    let completionTokens: Int?
    /// Consumed quota for this request (raw quota units).
    let quota: Int?
    /// Unix seconds.
    let createdAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case quota
        case createdAt = "created_at"
    }

    init(
        modelName: String?,
        promptTokens: Int?,
        completionTokens: Int?,
        quota: Int?,
        createdAt: TimeInterval?)
    {
        self.modelName = modelName
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.quota = quota
        self.createdAt = createdAt
    }
}

// MARK: - Auth

private enum NebulaAuth: Sendable {
    case cookie(cookie: String, userId: String?)
    case apiKey(String)

    var label: String {
        switch self {
        case .cookie: "browser"
        case .apiKey: "apikey"
        }
    }
}

// MARK: - Provider

/// Nebula API relay (new-api based) balance + consumption monitoring.
///
/// Official docs only document model-call credentials (`/v1` + API key). The
/// balance/usage-log endpoints (`/api/user/self`, `/api/log/self`) are console
/// APIs. TokenBar therefore prefers the browser console session cookie, and
/// only falls back to the API key when the console endpoints accept it.
final class NebulaProvider: UsageProvider {
    let displayName = "APINebula"

    /// Verified against https://apinebula.ai/api/status: 1 currency unit = 500000 quota.
    static let defaultQuotaPerUnit: Double = 500_000
    static let defaultBaseURL = "https://apinebula.ai"

    private static let pageSize = 100
    private static let maxPages = 20
    private static let timeoutSeconds: TimeInterval = 15

    private let settings: AppSettings
    private let transport: any HTTPTransport

    init(settings: AppSettings, transport: any HTTPTransport = defaultHTTPTransport()) {
        self.settings = settings
        self.transport = transport
    }

    /// Credentials are resolved inside `fetch` (browser cookie / settings / env).
    func isAvailable(environment: [String: String]) -> Bool {
        true
    }

    func fetch(environment: [String: String]) async throws -> ProviderSnapshot {
        let baseURL = await MainActor.run {
            Self.normalizedBaseURL(self.settings.nebulaBaseURL)
        } ?? NebulaCredentialResolver.baseURL(environment: environment)
            ?? Self.defaultBaseURL
        let apiKey = await MainActor.run {
            Self.trimmed(self.settings.nebulaAPIKey)
        } ?? NebulaCredentialResolver.apiKey(environment: environment)
        let browserSession = NebulaBrowserSession.cachedSession()

        // Prefer console session cookie. Official docs' API key is for /v1 model
        // calls; console balance endpoints usually need browser login state.
        var authAttempts: [NebulaAuth] = []
        if let session = browserSession {
            authAttempts.append(.cookie(cookie: session.cookieHeader, userId: session.userId))
        }
        if let apiKey {
            authAttempts.append(.apiKey(apiKey))
        }
        guard !authAttempts.isEmpty else {
            throw UsageError.nebulaMissingCredentials
        }

        var lastError: Error = UsageError.nebulaMissingCredentials
        var user: NebulaUserSelf?
        var usedAuth: NebulaAuth?
        for auth in authAttempts {
            do {
                user = try await fetchUserSelf(baseURL: baseURL, auth: auth)
                usedAuth = auth
                break
            } catch {
                lastError = error
                UsageStore.log("✗ Nebula auth \(auth.label) failed for user/self: \(error.localizedDescription)")
            }
        }
        guard let user, let usedAuth else {
            throw lastError
        }

        let quotaPerUnit = user.quotaPerUnit
        let balance = Double(user.quota) / quotaPerUnit
        let usedTotal = Double(user.usedQuota) / quotaPerUnit

        // Consumption log is optional: paging can be slow or rejected, and the
        // balance card must still render.
        var stats: NebulaUsageStats?
        do {
            stats = try await fetchMonthlyLogs(baseURL: baseURL, auth: usedAuth)
        } catch {
            UsageStore.log("✗ Nebula consumption log unavailable: \(error.localizedDescription)")
        }

        let summary = NebulaSummary(
            currency: "CNY",
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
            usageAvailable: stats != nil)

        // Ring: cumulative spend vs (spend + balance) — the relay's own numbers.
        let usedPercent = Self.ringUsedPercent(balance: balance, usedTotal: usedTotal)
        let window = UsageWindow(label: "balance", usedPercent: usedPercent,
                                 used: nil, total: nil, resetsAt: nil)
        let plan = PlanSnapshot(
            id: "nebula",
            product: .nebula,
            edition: nil,
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: [window],
            expiryDate: nil,
            errorMessage: nil,
            deepseek: nil,
            nebula: summary)
        let authMethod: String = switch usedAuth {
        case .cookie:
            if let source = browserSession?.sourceLabel, !source.isEmpty {
                "browser · \(source)"
            } else {
                "browser"
            }
        case .apiKey:
            "apikey"
        }
        return ProviderSnapshot(
            providerName: displayName,
            authMethod: authMethod,
            plans: [plan],
            updatedAt: Date(),
            errorMessage: nil)
    }

    /// Used share of the ring from the relay's cumulative numbers.
    static func ringUsedPercent(balance: Double, usedTotal: Double) -> Double {
        guard balance > 0 else { return 100 }
        let total = usedTotal + balance
        guard total > 0 else { return 100 }
        return min(100, max(0, usedTotal / total * 100))
    }

    // MARK: - Endpoints

    private func fetchUserSelf(baseURL: String, auth: NebulaAuth) async throws -> NebulaUserSelf {
        var request = URLRequest(url: try Self.endpoint(baseURL: baseURL, path: "/api/user/self"))
        request.httpMethod = "GET"
        Self.apply(auth: auth, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await transport.response(for: request)
        if let bodyError = Self.consoleAPIError(from: response) {
            throw bodyError
        }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw UsageError.nebulaInvalidToken
            }
            throw UsageError.apiError(statusCode: response.statusCode, message: "Nebula user/self")
        }
        return try Self.decodeUserSelf(data: response.data)
    }

    /// Pulls the current month's consumption log page by page until the relay
    /// stops returning entries (or the page cap is hit).
    private func fetchMonthlyLogs(baseURL: String, auth: NebulaAuth) async throws -> NebulaUsageStats {
        let calendar = Calendar.current
        let now = Date()
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let startTimestamp = Int(startOfMonth.timeIntervalSince1970)
        let endTimestamp = Int(now.timeIntervalSince1970)

        var allItems: [NebulaLogItem] = []
        for page in 1 ... Self.maxPages {
            let items = try await fetchLogPage(
                baseURL: baseURL, auth: auth, page: page,
                startTimestamp: startTimestamp, endTimestamp: endTimestamp)
            if items.isEmpty { break }
            allItems.append(contentsOf: items)
        }
        return Self.aggregate(items: allItems, now: now, calendar: calendar)
    }

    private func fetchLogPage(
        baseURL: String, auth: NebulaAuth, page: Int,
        startTimestamp: Int, endTimestamp: Int) async throws -> [NebulaLogItem]
    {
        let endpoint = try Self.endpoint(baseURL: baseURL, path: "/api/log/self")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw UsageError.networkError("Invalid Nebula log URL")
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
            throw UsageError.networkError("Could not construct Nebula log URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        Self.apply(auth: auth, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await transport.response(for: request)
        if let bodyError = Self.consoleAPIError(from: response) {
            throw bodyError
        }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw UsageError.nebulaInvalidToken
            }
            throw UsageError.apiError(statusCode: response.statusCode, message: "Nebula log/self")
        }
        return try Self.decodeLogPage(data: response.data)
    }

    private static func apply(auth: NebulaAuth, to request: inout URLRequest) {
        switch auth {
        case let .cookie(cookie, userId):
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            // new-api console APIs check New-Api-User against the session id.
            if let userId, !userId.isEmpty {
                request.setValue(userId, forHTTPHeaderField: "New-Api-User")
            }
        case let .apiKey(apiKey):
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

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
            {
                return .nebulaInvalidToken
            }
            if !message.isEmpty {
                return .apiError(statusCode: response.statusCode, message: message)
            }
        }
        return nil
    }

    private static func endpoint(baseURL: String, path: String) throws -> URL {
        guard let url = URL(string: baseURL + path) else {
            throw UsageError.networkError("Invalid Nebula base URL")
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

    static func decodeUserSelf(data: Data) throws -> NebulaUserSelf {
        let decoded: NebulaUserSelfResponse
        do {
            decoded = try JSONDecoder().decode(NebulaUserSelfResponse.self, from: data)
        } catch {
            throw UsageError.parseFailed(error.localizedDescription)
        }
        if decoded.success == false {
            let message = decoded.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let lower = message.lowercased()
            if lower.contains("unauthorized")
                || lower.contains("invalid access token")
                || lower.contains("not logged in")
            {
                throw UsageError.nebulaInvalidToken
            }
            throw UsageError.apiError(statusCode: 401, message: message.isEmpty ? "Nebula user/self" : message)
        }
        guard let userData = decoded.data else {
            throw UsageError.parseFailed("Missing Nebula user/self data")
        }
        return NebulaUserSelf(
            quota: userData.quota ?? 0,
            usedQuota: userData.usedQuota ?? 0,
            quotaPerUnit: Self.defaultQuotaPerUnit)
    }

    static func decodeLogPage(data: Data) throws -> [NebulaLogItem] {
        let decoded: NebulaLogResponse
        do {
            decoded = try JSONDecoder().decode(NebulaLogResponse.self, from: data)
        } catch {
            throw UsageError.parseFailed(error.localizedDescription)
        }
        if decoded.success == false {
            let message = decoded.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let lower = message.lowercased()
            if lower.contains("unauthorized")
                || lower.contains("invalid access token")
                || lower.contains("not logged in")
            {
                throw UsageError.nebulaInvalidToken
            }
            throw UsageError.apiError(statusCode: 401, message: message.isEmpty ? "Nebula log/self" : message)
        }
        guard let items = decoded.data?.items else {
            throw UsageError.parseFailed("Missing Nebula log/self data")
        }
        return items
    }

    static func aggregate(items: [NebulaLogItem], now: Date, calendar: Calendar) -> NebulaUsageStats {
        var todayTokens = 0
        var monthTokens = 0
        var todayCost: Double = 0
        var monthCost: Double = 0
        var todayRequests = 0
        var monthRequests = 0
        var monthPromptTokens = 0
        var monthCompletionTokens = 0
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
                if let model = item.modelName {
                    modelTokens[model, default: 0] += tokens
                }
            }
        }

        let topModel = modelTokens.max {
            if $0.value == $1.value { return $0.key > $1.key }
            return $0.value < $1.value
        }?.key

        return NebulaUsageStats(
            todayTokens: todayTokens,
            currentMonthTokens: monthTokens,
            todayCost: todayCost,
            currentMonthCost: monthCost,
            requestCount: todayRequests,
            currentMonthRequestCount: monthRequests,
            topModel: topModel,
            promptTokens: monthPromptTokens,
            completionTokens: monthCompletionTokens)
    }

    private static func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Parsed domain values

struct NebulaUserSelf: Sendable, Equatable {
    /// Remaining quota in raw quota units.
    let quota: Int
    /// Cumulative consumed quota in raw quota units.
    let usedQuota: Int
    let quotaPerUnit: Double
}

struct NebulaUsageStats: Sendable, Equatable {
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
}

// MARK: - Credentials

/// Reads Nebula relay credentials from the environment. Settings (Keychain)
/// values take precedence; these are the fallback.
enum NebulaCredentialResolver {
    static let apiKeyKeys = ["NEBULA_API_KEY", "APINEBULA_API_KEY"]
    static let baseURLKeys = ["NEBULA_BASE_URL", "APINEBULA_BASE_URL"]

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
