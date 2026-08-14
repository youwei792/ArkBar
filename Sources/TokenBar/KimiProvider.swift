import Foundation

// MARK: - Credentials

/// Reads a Kimi Code API key or web `kimi-auth` token from the environment.
/// Settings (Keychain) values take precedence; these are the fallback.
enum KimiCredentialResolver {
    static let apiKeyKeys = ["KIMI_CODE_API_KEY"]
    static let authTokenKeys = ["KIMI_AUTH_TOKEN"]

    static func apiKey(environment: [String: String]) -> String? {
        value(for: apiKeyKeys, environment: environment)
    }

    static func authToken(environment: [String: String]) -> String? {
        value(for: authTokenKeys, environment: environment)
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

private struct KimiCodeAPIUsageResponse: Decodable {
    let usage: KimiUsageDetail
    let limits: [KimiRateLimit]?
}

struct KimiUsageDetail: Decodable {
    let limit: String
    let used: String?
    let remaining: String?
    let resetTime: String?

    /// Convenience initializer for building windows from a 0–100 ratio.
    init(limit: String, used: String?, remaining: String?, resetTime: String?) {
        self.limit = limit
        self.used = used
        self.remaining = remaining
        self.resetTime = resetTime
    }

    private enum CodingKeys: String, CodingKey {
        case limit
        case used
        case remaining
        case resetTime
        case resetAt
        case resetTimeSnake = "reset_time"
        case resetAtSnake = "reset_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The API sends limit/used/remaining as strings, but a numeric response
        // must not break decoding.
        guard let limit = Self.stringValue(in: container, forKey: .limit) else {
            throw DecodingError.keyNotFound(
                CodingKeys.limit,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Kimi usage limit is missing"))
        }
        self.limit = limit
        self.used = Self.stringValue(in: container, forKey: .used)
        self.remaining = Self.stringValue(in: container, forKey: .remaining)
        self.resetTime =
            Self.stringValue(in: container, forKey: .resetTime) ??
            Self.stringValue(in: container, forKey: .resetAt) ??
            Self.stringValue(in: container, forKey: .resetTimeSnake) ??
            Self.stringValue(in: container, forKey: .resetAtSnake)
    }

    private static func stringValue(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys) -> String?
    {
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            if value.rounded(.towardZero) == value,
               value >= Double(Int64.min),
               value <= Double(Int64.max)
            {
                return String(Int64(value))
            }
            return String(value)
        }
        return nil
    }
}

private struct KimiRateLimit: Decodable {
    let window: KimiWindow
    let detail: KimiUsageDetail
}

private struct KimiWindow: Decodable {
    let duration: Int
    let timeUnit: String
}

private struct KimiUsageResponse: Decodable {
    let usages: [KimiUsage]
}

private struct KimiUsage: Decodable {
    let scope: String
    let detail: KimiUsageDetail
    let limits: [KimiRateLimit]?
}

/// Shared membership pool + Code 7-day window from the www.kimi.com
/// `GetSubscriptionStats` console endpoint.
struct KimiSubscriptionStatsResponse: Decodable {
    let subscriptionBalance: KimiSubscriptionBalance?
    let ratelimitCode7d: KimiSubscriptionRateLimit?
}

/// The shared subscription pool (`amountUsedRatio` is the whole-pool used
/// ratio, including Work; `kimiCodeUsedRatio` is the Code-only share).
struct KimiSubscriptionBalance: Decodable {
    let feature: String?
    let type: String?
    let amountUsedRatio: Double?
    let kimiCodeUsedRatio: Double?
    let expireTime: String?
}

struct KimiSubscriptionRateLimit: Decodable {
    let ratio: Double?
    let enabled: Bool?
    let resetTime: String?
}

// MARK: - Parsed snapshot

/// Parsed Kimi Code usage, before mapping to ArkBar models. `weekly` is the
/// membership quota (CodexBar's `usage`), `rateLimit` the 5-hour rate-limit
/// window. When the web session is available, `sharedPool` and
/// `codeWeeklyLimit` come from the membership console and expose the shared
/// (Work + Code) pool and the Code 7-day limit.
struct KimiUsageSnapshot {
    let weekly: KimiUsageDetail
    let rateLimit: KimiUsageDetail?
    let sharedPool: KimiSubscriptionBalance?
    let codeWeeklyLimit: KimiSubscriptionRateLimit?
}

// MARK: - Provider

/// Kimi (Kimi For Coding) membership usage via the Code API `usages` endpoint.
///
/// Mirrors CodexBar's KimiUsageFetcher Code API path (the API-key route): one
/// GET to `https://api.kimi.com/coding/v1/usages` returning the weekly
/// membership quota plus a 5-hour rate-limit window. No browser cookie import,
/// no CLI credential reuse.
final class KimiProvider: UsageProvider {
    let displayName = "Kimi"

    private static let timeoutSeconds: TimeInterval = 15

    private static let baseURL = URL(string: "https://api.kimi.com")!
    private static let usagePath = "coding/v1/usages"

    private let settings: AppSettings
    private let transport: any HTTPTransport

    init(settings: AppSettings, transport: any HTTPTransport = defaultHTTPTransport()) {
        self.settings = settings
        self.transport = transport
    }

    /// Credentials are resolved inside `fetch` (settings/Keychain -> environment).
    func isAvailable(environment: [String: String]) -> Bool { true }

    /// Whether the last web-session call (GetUsages / GetSubscriptionStats) was
    /// rejected with 401. Persisted so the settings pane can show a clear hint.
    static var webSessionInvalid: Bool {
        get { UserDefaults.standard.bool(forKey: Self.webSessionInvalidKey) }
        set {
            if newValue {
                UserDefaults.standard.set(true, forKey: Self.webSessionInvalidKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.webSessionInvalidKey)
            }
        }
    }

    private static let webSessionInvalidKey = "tokenbar.kimiWebSessionInvalid"

    func fetch(environment: [String: String]) async throws -> ProviderSnapshot {
        let apiKey = await MainActor.run { Self.trimmed(self.settings.kimiAPIKey) }
            ?? KimiCredentialResolver.apiKey(environment: environment)
        let authToken = await MainActor.run { Self.trimmed(self.settings.kimiAuthToken) }
            ?? KimiCredentialResolver.authToken(environment: environment)

        guard let apiKey, !apiKey.isEmpty else {
            // No API key: the web session alone still reports Code usage plus the
            // shared pool and Code 7-day windows from the membership console.
            guard let authToken, !authToken.isEmpty else {
                throw UsageError.kimiMissingCredentials
            }
            let snapshot = try await fetchWebSession(authToken: authToken)
            return Self.makeProviderSnapshot(from: snapshot)
        }

        let snapshot = try await fetchUsage(apiKey: apiKey)
        // Enrich with the shared-pool / Code 7-day windows when a web session is
        // cached or in the environment. Best-effort: a failed stats call never
        // fails the whole refresh.
        if let authToken, !authToken.isEmpty {
            if let enriched = try? await fetchWebSession(authToken: authToken) {
                return Self.makeProviderSnapshot(from: enriched)
            }
        }
        return Self.makeProviderSnapshot(from: snapshot)
    }

    static func makeWindows(from snapshot: KimiUsageSnapshot) -> [UsageWindow] {
        // Map Kimi usage into ArkBar's UsageWindow using the canonical labels so
        // the ring tones and legend line up:
        // - 5-hour rate limit  -> session ring
        // - Code 7-day limit   -> weekly ring (when the web session is present)
        // - shared pool        -> monthly ring (Work + Code, from the console)
        // - Code weekly quota  -> weekly ring (API-key fallback)
        // All use the API's *used* share, which `remainingPercent` inverts.
        var windows: [UsageWindow] = []
        if let rateLimit = snapshot.rateLimit {
            windows.append(Self.window(from: rateLimit, label: "5-hour", windowMinutes: 300))
        }
        // Weekly ring always shows Kimi Code's own weekly quota; the shared pool
        // (Work + Code billed together) fills the monthly ring when the web
        // session exposes it. The Code 7-day rate limit is intentionally not
        // mapped: ArkBar's three rings leave no slot for it, and it overlaps
        // with the weekly quota semantically.
        windows.append(Self.window(from: snapshot.weekly, label: "Weekly", windowMinutes: nil))
        if let sharedPool = snapshot.sharedPool,
           sharedPool.feature == nil || sharedPool.feature == "FEATURE_OMNI",
           sharedPool.type == nil || sharedPool.type == "SUBSCRIPTION",
           let ratio = sharedPool.amountUsedRatio, ratio.isFinite
        {
            windows.append(Self.ratioWindow(
                usedPercent: Self.clampedPercent(ratio * 100),
                resetsAt: Self.parseDate(sharedPool.expireTime),
                label: "Monthly", windowMinutes: nil))
        }
        return windows
    }

    /// Builds a 0–100 percent window directly from a ratio, avoiding the
    /// integer truncation that would occur if routed through a string quota.
    private static func ratioWindow(usedPercent: Double, resetsAt: Date?, label: String, windowMinutes: Int?) -> UsageWindow {
        UsageWindow(
            label: label,
            usedPercent: usedPercent,
            used: Int((usedPercent / 100).rounded()),
            total: 100,
            resetsAt: resetsAt)
    }

    private static func makeProviderSnapshot(from snapshot: KimiUsageSnapshot) -> ProviderSnapshot {
        let windows = makeWindows(from: snapshot)

        let plan = PlanSnapshot(
            id: "kimi-coding-plan",
            product: .codingPlan,
            edition: "Kimi For Coding",
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: windows,
            expiryDate: nil,
            errorMessage: nil)

        return ProviderSnapshot(
            providerName: "Kimi",
            authMethod: "apikey",
            plans: [plan],
            updatedAt: Date(),
            errorMessage: nil)
    }

    private func fetchUsage(apiKey: String) async throws -> KimiUsageSnapshot {
        let url = Self.baseURL.appendingPathComponent(Self.usagePath)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw UsageError.kimiInvalidToken
            }
            let body = String(data: response.data, encoding: .utf8) ?? ""
            throw UsageError.apiError(statusCode: response.statusCode, message: "Kimi Code API: \(body)")
        }
        guard !response.data.isEmpty else {
            throw UsageError.parseFailed(
                "Empty Kimi response. Check the API key and that the plan is active.")
        }
        return try Self.parse(data: response.data)
    }

    /// Full web path: Code usage (GetUsages) plus the shared-pool / Code 7-day
    /// windows (GetSubscriptionStats), authenticated with the `kimi-auth` JWT.
    private func fetchWebSession(authToken: String) async throws -> KimiUsageSnapshot {
        let usage = try await fetchWebUsage(authToken: authToken)
        let stats = try? await fetchSubscriptionStats(authToken: authToken)
        return KimiUsageSnapshot(
            weekly: usage.detail,
            rateLimit: usage.limits?.first?.detail,
            sharedPool: stats?.subscriptionBalance,
            codeWeeklyLimit: stats?.ratelimitCode7d)
    }

    private func fetchWebUsage(authToken: String) async throws -> KimiUsage {
        var request = Self.webRequest(path: "apiv2/kimi.gateway.billing.v1.BillingService/GetUsages", authToken: authToken)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["scope": ["FEATURE_CODING"]])
        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                Self.webSessionInvalid = true
                throw UsageError.kimiInvalidToken
            }
            let body = String(data: response.data, encoding: .utf8) ?? ""
            throw UsageError.apiError(statusCode: response.statusCode, message: "Kimi web usage: \(body)")
        }
        Self.webSessionInvalid = false
        let usageResponse = try JSONDecoder().decode(KimiUsageResponse.self, from: response.data)
        guard let codingUsage = usageResponse.usages.first(where: { $0.scope == "FEATURE_CODING" }) else {
            throw UsageError.parseFailed("FEATURE_CODING scope not found in Kimi usage response")
        }
        return codingUsage
    }

    private func fetchSubscriptionStats(authToken: String) async throws -> KimiSubscriptionStatsResponse {
        var request = Self.webRequest(path: "apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats", authToken: authToken)
        request.httpBody = Data("{}".utf8)
        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                Self.webSessionInvalid = true
                throw UsageError.kimiInvalidToken
            }
            let body = String(data: response.data, encoding: .utf8) ?? ""
            throw UsageError.apiError(statusCode: response.statusCode, message: "Kimi subscription stats: \(body)")
        }
        Self.webSessionInvalid = false
        return try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: response.data)
    }

    /// Mirrors CodexBar's `KimiUsageFetcher.webRequest`: the console endpoints
    /// need the JWT as both Bearer and `kimi-auth` cookie plus browser headers.
    private static func webRequest(path: String, authToken: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://www.kimi.com")!.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi-auth=\(authToken)", forHTTPHeaderField: "Cookie")
        request.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.kimi.com/code/console", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("en-US", forHTTPHeaderField: "x-language")
        request.setValue("web", forHTTPHeaderField: "x-msh-platform")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "r-timezone")
        request.timeoutInterval = Self.timeoutSeconds
        return request
    }

    private static func window(from detail: KimiUsageDetail, label: String, windowMinutes: Int?) -> UsageWindow {
        let limit = Int(detail.limit) ?? 0
        let remaining = Int(detail.remaining ?? "")
        let used = Int(detail.used ?? "") ?? {
            guard let remaining else { return 0 }
            return max(0, limit - remaining)
        }()
        let usedPercent = limit > 0 ? Self.clampedPercent(Double(used) / Double(limit) * 100) : 0
        return UsageWindow(
            label: label,
            usedPercent: usedPercent,
            used: used,
            total: limit,
            resetsAt: Self.parseDate(detail.resetTime))
    }

    private static func parseDate(_ dateString: String?) -> Date? {
        guard let dateString else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: dateString)
    }

    private static func clampedPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Decoding (static for tests)

    static func parse(data: Data) throws -> KimiUsageSnapshot {
        guard !data.isEmpty else {
            throw UsageError.parseFailed("Empty Kimi response body")
        }
        let response: KimiCodeAPIUsageResponse
        do {
            response = try JSONDecoder().decode(KimiCodeAPIUsageResponse.self, from: data)
        } catch {
            throw UsageError.parseFailed("Kimi: \(error.localizedDescription)")
        }
        return KimiUsageSnapshot(
            weekly: response.usage,
            rateLimit: response.limits?.first?.detail,
            sharedPool: nil,
            codeWeeklyLimit: nil)
    }
}
