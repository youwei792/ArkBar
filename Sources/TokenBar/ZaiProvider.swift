import Foundation

// MARK: - API region

/// Z.ai has two portals with separate hosts and API keys. The region is a
/// user preference (Settings) that selects the quota endpoint and the
/// "Open usage dashboard" action target.
enum ZaiAPIRegion: String, CaseIterable, Sendable {
    case global
    case bigmodelCN = "bigmodel-cn"

    private static let quotaPath = "api/monitor/usage/quota/limit"
    /// Console subscription orders — the same API key that authenticates the
    /// quota endpoint also authenticates this one, so no browser session is
    /// needed to read the plan's end date.
    private static let subscriptionListPath = "api/biz/subscription/list?pageNum=1&pageSize=9999"

    var displayName: String {
        switch self {
        case .global: "Global (api.z.ai)"
        case .bigmodelCN: "BigModel CN (open.bigmodel.cn)"
        }
    }

    var baseURLString: String {
        switch self {
        case .global: "https://api.z.ai"
        case .bigmodelCN: "https://open.bigmodel.cn"
        }
    }

    var quotaLimitURL: URL {
        URL(string: baseURLString)!.appendingPathComponent(Self.quotaPath)
    }

    var subscriptionListURL: URL {
        URL(string: baseURLString + "/" + Self.subscriptionListPath)!
    }

    /// Personal Coding Plan usage dashboard, opened by the menu action.
    var dashboardURL: URL {
        switch self {
        case .global:
            URL(string: "https://z.ai/manage-apikey/coding-plan/personal/my-plan")!
        case .bigmodelCN:
            URL(string: "https://bigmodel.cn/coding-plan/personal/usage")!
        }
    }
}

// MARK: - Credentials

/// Reads a Z.ai API token from the environment. Settings (Keychain) values
/// take precedence; this is the fallback.
enum ZaiCredentialResolver {
    static let apiKeyKeys = ["Z_AI_API_KEY"]

    static func apiKey(environment: [String: String]) -> String? {
        value(for: apiKeyKeys, environment: environment)
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

// MARK: - API response types

private struct ZaiQuotaLimitResponse: Decodable {
    let code: Int
    let msg: String?
    let data: ZaiQuotaLimitData?
    let success: Bool

    var isSuccess: Bool { success && code == 200 }

    var errorMessage: String {
        let message = msg?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty { return message }
        return "Z.ai quota API returned code \(code)"
    }
}

private struct ZaiQuotaLimitData: Decodable {
    let limits: [ZaiLimitRaw]
    let planName: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.limits = try container.decodeIfPresent([ZaiLimitRaw].self, forKey: .limits) ?? []
        // The plan name lives under any of several keys across regions/releases.
        let rawPlan = try [
            container.decodeIfPresent(String.self, forKey: .planName),
            container.decodeIfPresent(String.self, forKey: .plan),
            container.decodeIfPresent(String.self, forKey: .planType),
            container.decodeIfPresent(String.self, forKey: .packageName),
            // BigModel CN returns the plan tier (e.g. "lite") under `level`.
            container.decodeIfPresent(String.self, forKey: .level),
        ].compactMap(\.self).first
        let trimmed = rawPlan?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.planName = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case limits
        case planName
        case plan
        case planType = "plan_type"
        case packageName
        case level
    }
}

private struct ZaiLimitRaw: Decodable {
    let type: String
    let unit: Int
    let number: Int
    let usage: Int?
    let currentValue: Int?
    let remaining: Int?
    let percentage: Int
    let nextResetTime: Int?
}

// MARK: - Subscription orders

private struct ZaiSubscriptionListResponse: Decodable {
    let code: Int
    let data: [ZaiSubscriptionRaw]?
    let success: Bool

    var isSuccess: Bool { success && code == 200 }
}

/// One subscription order from the console's `subscription/list` action.
///
/// `nextRenewTime` is what the console labels 有效期至: the end of the paid
/// period, whether or not auto-renew is on.
private struct ZaiSubscriptionRaw: Decodable {
    let status: String?
    let nextRenewTime: String?
    let valid: String?
}

/// A Z.ai Coding Plan order, before the reminder engine filters by status.
struct ZaiSubscription: Sendable, Equatable {
    let status: String?
    let expiryDate: Date?

    var isActive: Bool {
        status?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "VALID"
    }
}

// MARK: - Parsed limit

/// Limit type and unit enums mirror CodexBar's ZaiLimitType / ZaiLimitUnit,
/// extended with CREDIT_LIMIT which newer Z.ai Coding Plans return instead of
/// TOKENS_LIMIT/TIME_LIMIT.
enum ZaiLimitType: String {
    case tokensLimit = "TOKENS_LIMIT"
    case creditLimit = "CREDIT_LIMIT"
    case timeLimit = "TIME_LIMIT"

    /// Whether this limit is a token/credit window (drives the session ring)
    /// rather than an MCP time window.
    var isTokenLike: Bool {
        switch self {
        case .tokensLimit, .creditLimit: true
        case .timeLimit: false
        }
    }
}

enum ZaiLimitUnit: Int {
    case unknown = 0
    case days = 1
    case hours = 3
    case minutes = 5
    case weeks = 6
}

/// A single parsed limit entry from the Z.ai quota API.
struct ZaiLimitEntry {
    let type: ZaiLimitType
    let unit: ZaiLimitUnit
    let number: Int
    let usage: Int?
    let currentValue: Int?
    let remaining: Int?
    let percentage: Double
    let nextResetTime: Date?

    /// Used percent, preferring the value computed from absolute quota fields
    /// (which the API keeps fresher than the pre-baked `percentage`).
    var usedPercent: Double {
        if let computed = computedUsedPercent { return computed }
        return percentage
    }

    private var computedUsedPercent: Double? {
        guard let limit = usage, limit > 0 else { return nil }
        // z.ai sometimes omits quota fields; don't invent zeros (can yield 100% used incorrectly).
        var usedRaw: Int?
        if let remaining {
            let usedFromRemaining = limit - remaining
            if let currentValue {
                usedRaw = max(usedFromRemaining, currentValue)
            } else {
                usedRaw = usedFromRemaining
            }
        } else if let currentValue {
            usedRaw = currentValue
        }
        guard let usedRaw else { return nil }
        let used = max(0, min(limit, usedRaw))
        return min(100, max(0, Double(used) / Double(limit) * 100))
    }

    var windowMinutes: Int? {
        guard number > 0 else { return nil }
        switch unit {
        case .minutes: return number
        case .hours: return number * 60
        case .days: return number * 24 * 60
        case .weeks: return number * 7 * 24 * 60
        case .unknown: return nil
        }
    }
}

// MARK: - Parsed snapshot

/// Parsed Z.ai personal Coding Plan usage, before mapping to ArkBar models.
struct ZaiUsageSnapshot {
    let tokenLimit: ZaiLimitEntry?
    let sessionTokenLimit: ZaiLimitEntry?
    let timeLimit: ZaiLimitEntry?
    let planName: String?

    var isValid: Bool { tokenLimit != nil || timeLimit != nil }
}

// MARK: - Provider

/// Z.ai (智谱 GLM) personal Coding Plan usage via the quota/limit API.
///
/// Mirrors CodexBar's ZaiUsageFetcher (personal scope only): one API token,
/// one GET to `api/monitor/usage/quota/limit`, returning a 5-hour token window
/// and a monthly MCP (time) window. No browser session, no team headers.
final class ZaiProvider: UsageProvider {
    let displayName = "智谱"

    private static let timeoutSeconds: TimeInterval = 15

    private let settings: AppSettings
    private let transport: any HTTPTransport
    /// Order end dates move at day granularity; the subscription list is
    /// fetched at most once per TTL (and re-fetched when region or key
    /// changes).
    private let subscriptionCache = TTLCache<(
        region: ZaiAPIRegion,
        apiKey: String,
        list: [ZaiSubscription])>(ttl: 12 * 60 * 60)

    init(settings: AppSettings, transport: any HTTPTransport = defaultHTTPTransport()) {
        self.settings = settings
        self.transport = transport
    }

    /// Credentials are resolved inside `fetch` (settings/Keychain -> environment).
    func isAvailable(environment: [String: String]) -> Bool { true }

    func fetch(environment: [String: String]) async throws -> ProviderSnapshot {
        let region = await MainActor.run { self.settings.zaiRegion }
        let apiKey = await MainActor.run { Self.trimmed(self.settings.zaiAPIKey) }
            ?? ZaiCredentialResolver.apiKey(environment: environment)

        guard let apiKey, !apiKey.isEmpty else {
            throw UsageError.zaiMissingCredentials
        }

        let snapshot = try await fetchQuota(region: region, apiKey: apiKey)
        // The quota endpoint reports window resets only; the order's end date
        // comes from the console subscription list. Best effort — a failure
        // here keeps the rings rendering and only drops the expiry badge.
        let subscriptions: [ZaiSubscription]
        if let cached = subscriptionCache.validValue(),
           cached.region == region, cached.apiKey == apiKey
        {
            subscriptions = cached.list
        } else {
            subscriptions = await fetchSubscriptions(region: region, apiKey: apiKey)
            subscriptionCache.store((region: region, apiKey: apiKey, list: subscriptions))
        }

        // Map Z.ai limits into ArkBar's UsageWindow, reusing the canonical
        // labels the Ark providers use so the ring tones and legend line up.
        // Z.ai's personal Coding Plan exposes a 5-hour token window plus a
        // second, longer token/credit window (weekly ring); some plans also
        // return a monthly MCP time window.
        var windows: [UsageWindow] = []
        if let session = snapshot.sessionTokenLimit {
            windows.append(Self.window(from: session, label: "5-hour"))
        }
        if let token = snapshot.tokenLimit {
            // With two TOKENS_LIMIT entries the shorter (session) is already
            // added above; the longer one fills the weekly slot. With a single
            // entry it is the 5-hour window itself.
            let label = snapshot.sessionTokenLimit == nil ? "5-hour" : "Weekly"
            windows.append(Self.window(from: token, label: label))
        }
        if let time = snapshot.timeLimit {
            windows.append(Self.window(from: time, label: "Monthly"))
        }

        let plan = PlanSnapshot(
            id: "zai-coding-plan",
            product: .codingPlan,
            edition: snapshot.planName ?? "personal",
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: windows,
            expiryDate: Self.expiryDate(in: subscriptions),
            errorMessage: nil)

        return ProviderSnapshot(
            providerName: displayName,
            authMethod: "apikey",
            plans: [plan],
            updatedAt: Date(),
            errorMessage: nil)
    }

    private func fetchQuota(region: ZaiAPIRegion, apiKey: String) async throws -> ZaiUsageSnapshot {
        var request = URLRequest(url: region.quotaLimitURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw UsageError.zaiInvalidToken
            }
            let body = String(data: response.data, encoding: .utf8) ?? ""
            throw UsageError.apiError(statusCode: response.statusCode, message: "Z.ai quota: \(body)")
        }
        // Some upstream issues (wrong endpoint/region/proxy) can yield HTTP 200
        // with an empty body. Surface a clear parse error rather than an opaque
        // Cocoa "data is missing".
        guard !response.data.isEmpty else {
            throw UsageError.parseFailed(
                "Empty Z.ai response. Check the API region (Global vs BigModel CN) and your API key.")
        }
        return try Self.parse(data: response.data)
    }

    /// Reads the console's subscription orders. Returns an empty list on any
    /// failure so the quota view never depends on it.
    private func fetchSubscriptions(region: ZaiAPIRegion, apiKey: String) async -> [ZaiSubscription] {
        var request = URLRequest(url: region.subscriptionListURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = Self.timeoutSeconds
        guard let response = try? await transport.response(for: request),
              response.statusCode == 200
        else {
            return []
        }
        return Self.parseSubscriptions(from: response.data)
    }

    /// The plan's expiry: the furthest end date among active orders.
    static func expiryDate(in subscriptions: [ZaiSubscription]) -> Date? {
        subscriptions.filter(\.isActive).compactMap(\.expiryDate).max()
    }

    static func parseSubscriptions(from data: Data) -> [ZaiSubscription] {
        guard let payload = try? JSONDecoder().decode(
            ZaiSubscriptionListResponse.self, from: data),
            payload.isSuccess
        else { return [] }
        return (payload.data ?? []).map { order in
            ZaiSubscription(
                status: order.status,
                expiryDate: parsePlanDate(order.nextRenewTime) ?? lastDate(in: order.valid))
        }
    }

    /// Z.ai ships plan dates as local calendar strings; the Global site uses
    /// `2026-10-18` while BigModel CN renders `2026年10月18日`, and the order's
    /// `valid` range carries full timestamps. All of them mean "that day".
    static func parsePlanDate(_ raw: String?) -> Date? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        let formats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "yyyy年MM月dd日"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        // Numeric epoch (seconds or milliseconds), as a string or a bare number.
        if let epoch = Double(value), epoch > 0 {
            let seconds = epoch >= 1e11 ? epoch / 1000 : epoch
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    /// The console falls back to the *end* of the order's `valid` range when
    /// `nextRenewTime` is absent, so the last date in the string is the one
    /// that matters.
    private static func lastDate(in range: String?) -> Date? {
        guard let value = range?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let expression = try? NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#)
        else { return nil }
        let nsValue = value as NSString
        let matches = expression.matches(
            in: value, range: NSRange(location: 0, length: nsValue.length))
        guard let last = matches.last else { return nil }
        return parsePlanDate(nsValue.substring(with: last.range))
    }

    private static func window(from entry: ZaiLimitEntry, label: String) -> UsageWindow {
        UsageWindow(
            label: label,
            usedPercent: entry.usedPercent,
            used: nil,
            total: nil,
            resetsAt: entry.nextResetTime)
    }

    private static func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Decoding (static for tests)

    static func parse(data: Data) throws -> ZaiUsageSnapshot {
        guard !data.isEmpty else {
            throw UsageError.parseFailed("Empty Z.ai response body")
        }
        let apiResponse: ZaiQuotaLimitResponse
        do {
            apiResponse = try JSONDecoder().decode(ZaiQuotaLimitResponse.self, from: data)
        } catch {
            throw UsageError.parseFailed("Z.ai: \(error.localizedDescription)")
        }
        guard apiResponse.isSuccess else {
            throw UsageError.apiError(statusCode: apiResponse.code, message: apiResponse.errorMessage)
        }
        guard let responseData = apiResponse.data else {
            throw UsageError.parseFailed("Missing Z.ai quota data")
        }

        var tokenLimits: [ZaiLimitEntry] = []
        var timeLimit: ZaiLimitEntry?

        for raw in responseData.limits {
            guard let type = ZaiLimitType(rawValue: raw.type) else { continue }
            let unit = ZaiLimitUnit(rawValue: raw.unit) ?? .unknown
            let nextReset = raw.nextResetTime.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1000)
            }
            let entry = ZaiLimitEntry(
                type: type,
                unit: unit,
                number: raw.number,
                usage: raw.usage,
                currentValue: raw.currentValue,
                remaining: raw.remaining,
                percentage: Double(raw.percentage),
                nextResetTime: nextReset)
            // Newer plans report token windows as CREDIT_LIMIT; both drive the
            // token/credit rings, only TIME_LIMIT marks the MCP time window.
            if type.isTokenLike {
                tokenLimits.append(entry)
            } else {
                timeLimit = entry
            }
        }

        // Multiple TOKENS_LIMIT entries: shortest window -> session (tertiary),
        // longest -> primary. Matches CodexBar's split.
        let tokenLimit: ZaiLimitEntry?
        let sessionTokenLimit: ZaiLimitEntry?
        if tokenLimits.count >= 2 {
            let sorted = tokenLimits.sorted {
                ($0.windowMinutes ?? Int.max) < ($1.windowMinutes ?? Int.max)
            }
            sessionTokenLimit = sorted.first
            tokenLimit = sorted.last
        } else {
            tokenLimit = tokenLimits.first
            sessionTokenLimit = nil
        }

        return ZaiUsageSnapshot(
            tokenLimit: tokenLimit,
            sessionTokenLimit: sessionTokenLimit,
            timeLimit: timeLimit,
            planName: responseData.planName)
    }
}
