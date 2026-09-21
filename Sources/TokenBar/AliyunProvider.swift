import Foundation

// MARK: - Console

/// Bailian console destinations for the Coding Plan product.
enum AliyunConsole {
    /// Usage dashboard; also where the dedicated `sk-sp-…` API key is issued.
    static let dashboardURL = URL(
        string: "https://bailian.console.aliyun.com/cn-beijing/subscription/coding-plan")!
}

// MARK: - Credentials

/// Reads the dedicated Coding Plan API key from the environment. Settings
/// (Keychain) values take precedence; this is the fallback.
enum AliyunCredentialResolver {
    static let apiKeyKeys = ["ALIYUN_CODING_PLAN_API_KEY"]

    static func apiKey(environment: [String: String]) -> String? {
        for key in apiKeyKeys {
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

// MARK: - Parsed model

/// One quota window of the Coding Plan. The Pro plan exposes three: a rolling
/// 5-hour window (6,000 requests), a weekly window (45,000, Monday reset) and
/// a monthly window (90,000, reset on the subscription day).
struct AliyunWindowEntry: Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable {
        case fiveHour = "five_hour"
        case weekly
        case monthly

        /// Canonical UsageWindow label so the rings, legend and sortRank line
        /// up with every other provider.
        var windowLabel: String {
            switch self {
            case .fiveHour: "5-hour"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            }
        }
    }

    let kind: Kind
    let usedPercent: Double
    let used: Int?
    let total: Int?
    let resetsAt: Date?
}

/// Parsed Alibaba Cloud Coding Plan usage, before mapping to ArkBar models.
struct AliyunUsageSnapshot: Sendable, Equatable {
    let planName: String?
    /// Verified subscription expiry when the source exposes it.
    let expiryDate: Date?
    let windows: [AliyunWindowEntry]
}

// MARK: - Provider

/// Alibaba Cloud (阿里云百炼) Coding Plan usage.
///
/// Stage 1 (skeleton): the plan is bought but not yet activated, and Alibaba
/// documents no public quota API — the console Coding Plan page is the only
/// usage view. The provider therefore validates the `sk-sp-…` key and then
/// fails honestly with `aliyunNotActivated` instead of guessing an endpoint.
/// Stage 2 (after activation) replaces `fetchUsage` with the real request:
/// open the console page, capture the usage XHR in devtools, and map it onto
/// `AliyunUsageSnapshot` — see docs/aliyun-handoff.md.
final class AliyunProvider: UsageProvider {
    let displayName = "阿里云"

    private let settings: AppSettings
    private let transport: any HTTPTransport

    init(settings: AppSettings, transport: any HTTPTransport = defaultHTTPTransport()) {
        self.settings = settings
        self.transport = transport
    }

    /// Credentials are resolved inside `fetch` (settings/Keychain -> environment).
    func isAvailable(environment: [String: String]) -> Bool { true }

    func fetch(environment: [String: String]) async throws -> ProviderSnapshot {
        let apiKey = await MainActor.run { Self.trimmed(self.settings.aliyunAPIKey) }
            ?? AliyunCredentialResolver.apiKey(environment: environment)

        guard let apiKey, !apiKey.isEmpty else {
            throw UsageError.aliyunMissingCredentials
        }

        let usage = try await fetchUsage(apiKey: apiKey)
        return Self.makeSnapshot(from: usage)
    }

    /// Stage 2 replaces this body with the real console/API request. The
    /// `sk-sp-…` key authenticates the dedicated gateway
    /// (`https://coding.dashscope.aliyuncs.com/v1`); whether it also
    /// authorizes a quota endpoint is exactly what the activation spike must
    /// confirm.
    private func fetchUsage(apiKey: String) async throws -> AliyunUsageSnapshot {
        throw UsageError.aliyunNotActivated
    }

    // MARK: - Mapping (static for tests)

    static func makeSnapshot(from usage: AliyunUsageSnapshot) -> ProviderSnapshot {
        let windows = usage.windows
            .sorted { $0.kind.windowRank < $1.kind.windowRank }
            .map {
                UsageWindow(
                    label: $0.kind.windowLabel,
                    usedPercent: min(100, max(0, $0.usedPercent)),
                    used: $0.used,
                    total: $0.total,
                    resetsAt: $0.resetsAt)
            }
        let plan = PlanSnapshot(
            id: "aliyun-coding-plan",
            product: .aliyunCodingPlan,
            edition: usage.planName ?? "Coding Plan",
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: windows,
            expiryDate: usage.expiryDate,
            errorMessage: nil)
        return ProviderSnapshot(
            providerName: "阿里云",
            authMethod: "apikey",
            plans: [plan],
            updatedAt: Date(),
            errorMessage: nil)
    }

    private static func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Decoding (static for tests)

    /// Parses a usage payload into `AliyunUsageSnapshot`.
    ///
    /// PLACEHOLDER CONTRACT — written before the plan's activation, tolerant
    /// on purpose. Field names are best guesses (with common aliases) and
    /// must be reconciled with the response captured from the console page
    /// during the stage-2 spike; the mapping layer above does not change.
    static func parse(data: Data) throws -> AliyunUsageSnapshot {
        guard !data.isEmpty else {
            throw UsageError.parseFailed("Empty Alibaba Cloud response body")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UsageError.parseFailed("Alibaba Cloud: \(error.localizedDescription)")
        }
        guard let root = object as? [String: Any] else {
            throw UsageError.parseFailed("Alibaba Cloud: expected a JSON object")
        }

        let planName = [root["plan"], root["planName"], root["planType"]]
            .compactMap { $0 as? String }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let expiryDate = ["expiresAt", "expireTime", "expiryDate"]
            .compactMap { root[$0] }
            .compactMap { Self.dateValue($0) }
            .first

        guard let rawWindows = root["windows"] as? [[String: Any]] else {
            throw UsageError.parseFailed("Alibaba Cloud: missing usage windows")
        }

        var windows: [AliyunWindowEntry] = []
        for raw in rawWindows {
            guard let kind = Self.windowKind(raw["kind"] ?? raw["window"] ?? raw["type"]) else {
                continue
            }
            let usedPercent = ["usedPercent", "percent", "usagePercent"]
                .compactMap { raw[$0] }
                .compactMap { Self.doubleValue($0) }
                .first ?? 0
            let used = ["used", "usedCount", "currentValue"]
                .compactMap { raw[$0] }
                .compactMap { Self.intValue($0) }
                .first
            let total = ["total", "limit", "quota"]
                .compactMap { raw[$0] }
                .compactMap { Self.intValue($0) }
                .first
            let resetsAt = ["resetAt", "resetsAt", "resetTime", "nextResetTime"]
                .compactMap { raw[$0] }
                .compactMap { Self.dateValue($0) }
                .first
            windows.append(AliyunWindowEntry(
                kind: kind,
                usedPercent: min(100, max(0, usedPercent)),
                used: used,
                total: total,
                resetsAt: resetsAt))
        }

        if windows.isEmpty {
            throw UsageError.parseFailed("Alibaba Cloud: no recognizable usage windows")
        }
        return AliyunUsageSnapshot(planName: planName, expiryDate: expiryDate, windows: windows)
    }

    private static func windowKind(_ value: Any?) -> AliyunWindowEntry.Kind? {
        guard let string = value as? String else { return nil }
        switch string.lowercased() {
        case "five_hour", "five-hour", "5h", "session", "hourly":
            return .fiveHour
        case "weekly", "week":
            return .weekly
        case "monthly", "month":
            return .monthly
        default:
            return nil
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string)
        default: return nil
        }
    }

    private static func dateValue(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            let interval = number.doubleValue
            // Heuristic: > 1e12 is milliseconds since 1970.
            return Date(timeIntervalSince1970: interval > 1_000_000_000_000 ? interval / 1000 : interval)
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let interval = Double(trimmed) {
                return Date(timeIntervalSince1970: interval > 1_000_000_000_000 ? interval / 1000 : interval)
            }
            if let date = ISO8601DateFormatter().date(from: trimmed) { return date }
            let fallback = DateFormatter()
            fallback.locale = Locale(identifier: "en_US_POSIX")
            fallback.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return fallback.date(from: trimmed)
        default:
            return nil
        }
    }
}

private extension AliyunWindowEntry.Kind {
    /// Canonical ordering: 5-hour < weekly < monthly.
    var windowRank: Int {
        switch self {
        case .fiveHour: 0
        case .weekly: 1
        case .monthly: 2
        }
    }
}
