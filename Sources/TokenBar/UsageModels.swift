import Foundation

// MARK: - Core usage model

/// A single rate-limit window for a plan (session / 5h / weekly / monthly).
struct UsageWindow: Sendable, Equatable {
    /// Display label, e.g. "Session", "5-hour", "Weekly", "Monthly".
    let label: String
    /// Used percent 0–100 (from arkcli `percent`, which is *used*, not remaining).
    let usedPercent: Double
    /// Optional absolute used value (AgentPlan only; CodingPlan backend omits it).
    let used: Int?
    /// Optional absolute total value (AgentPlan only).
    let total: Int?
    /// Next reset time, if known.
    let resetsAt: Date?

    var remainingPercent: Double { max(0, 100 - usedPercent) }

    /// Canonical sort rank so session < 5h < weekly < monthly regardless of locale.
    var sortRank: Int {
        switch self.label.lowercased() {
        case "session", "5h", "5-hour", "five_hour", "balance", "24h": 0
        case "weekly", "week": 1
        case "monthly", "month": 2
        default: 3
        }
    }

    var displayName: String { L10n.shared.windowName(label) }
}

/// DeepSeek balance + usage breakdown shown on the DeepSeek card. Mirrors the
/// fields CodexBar exposes for the DeepSeek platform (API-key balance plus
/// platform-session today/month token/cost/request counts).
struct DeepSeekSummary: Sendable, Equatable {
    let currency: String
    let totalBalance: Double
    let grantedBalance: Double
    let toppedUpBalance: Double
    let todayTokens: Int
    let currentMonthTokens: Int
    let todayCost: Double?
    let currentMonthCost: Double?
    let requestCount: Int
    let currentMonthRequestCount: Int
    let topModel: String?
    /// Current-month token split by category (cache hit / cache miss / output).
    let promptCacheHitTokens: Int
    let promptCacheMissTokens: Int
    let responseTokens: Int
    /// True when a platform session supplied today/monthly usage; false when
    /// only the API-key balance is available.
    let usageAvailable: Bool
}

/// Nebula (new-api relay) balance + usage breakdown. Balance and total spend
/// come from `/api/user/self`; today/month numbers are aggregated from the
/// consumption log (`/api/log/self`) using the API key as an access token.
struct NebulaSummary: Sendable, Equatable {
    /// Currency code of the relay (CNY by default).
    let currency: String
    /// Quota units per one unit of currency (new-api `quota_per_unit`).
    let quotaPerUnit: Double
    /// Remaining balance in currency units.
    let balance: Double
    /// Cumulative spend in currency units.
    let usedTotal: Double
    let todayCost: Double?
    let currentMonthCost: Double?
    let todayTokens: Int
    let currentMonthTokens: Int
    let requestCount: Int
    let currentMonthRequestCount: Int
    let topModel: String?
    /// Current-month input (prompt) and output (completion) tokens.
    let promptTokens: Int
    let completionTokens: Int
    /// Current-month cache-hit input tokens.
    let cacheTokens: Int
    /// True when the consumption log was available for today/month numbers.
    let usageAvailable: Bool
}

/// GrokPool (grok2api admin gateway) 24-hour operational summary. Unlike the
/// balance-based relays there is no money balance: the ring reflects the
/// active-account availability rate and the status item can show the billed cost.
struct GrokPoolSummary: Sendable, Equatable {
    /// Dashboard period, always "24h" for now.
    let period: String
    let requests: Int
    let successfulRequests: Int
    let failedRequests: Int
    /// Request success rate as a 0–100 percentage (kept for the DTO, not shown
    /// in the UI — the ring displays `availabilityRate` instead).
    let successRate: Double
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    /// Total tokens (input + cached input + output + reasoning).
    let tokens: Int
    /// Billed cost in USD over the window.
    let costUSD: Double
    let activeAccounts: Int
    let totalAccounts: Int
    let topModel: String?

    /// Active-account availability as a 0–100 percentage. This is what the
    /// GrokPool ring and status item show (there is no money balance).
    var availabilityRate: Double {
        guard totalAccounts > 0 else { return 0 }
        return min(100, max(0, Double(activeAccounts) / Double(totalAccounts) * 100))
    }
}

/// LongCat (longcat.chat) token-resource-package quota. Unlike the balance-based
/// relays there is no money balance: the ring reflects the remaining-token
/// percentage of the quota (总额度). Fuel packs (加油包) are tracked separately
/// and expire independently.
struct LongCatSummary: Sendable, Equatable {
    /// Total token quota in the resource package.
    let totalToken: Double
    /// Consumed tokens.
    let usedToken: Double
    /// Remaining tokens (may be inferred from total - used if omitted).
    let availableToken: Double
    /// Combined fuel-pack quota, if any.
    let fuelPackTotal: Double?
    /// Remaining fuel-pack tokens.
    let fuelPackRemaining: Double?
    /// Nearest fuel-pack expiry date.
    let nearestFuelExpiry: Date?
    /// Account display name, if resolved.
    let accountName: String?

    /// Token consumption as a 0–100 percentage.
    var usedPercent: Double {
        guard totalToken > 0 else { return 0 }
        return min(100, max(0, usedToken / totalToken * 100))
    }

    /// Remaining quota as a 0–100 percentage — what the ring shows.
    var remainingPercent: Double {
        guard totalToken > 0 else { return 0 }
        return min(100, max(0, availableToken / totalToken * 100))
    }
}

/// One subscribed product (e.g. personal Coding Plan, team Agent Plan).
struct PlanSnapshot: Sendable, Equatable, Identifiable {
    enum Product: String, Sendable, Equatable {
        case codingPlan = "coding-plan"
        case agentPlan = "agent-plan"
        case codingPlanTeam = "coding-plan-team"
        case agentPlanTeam = "agent-plan-team"
        case openCodeGo = "opencode-go"
        case deepseek = "deepseek"
        case nebula = "nebula"
        case grokPool = "grok-pool"
        case longcat = "longcat"

        var displayName: String {
            L10n.shared.productName(self)
        }

        /// True for the `*-team` variants.
        var isTeam: Bool {
            switch self {
            case .codingPlanTeam, .agentPlanTeam: true
            case .codingPlan, .agentPlan, .openCodeGo, .deepseek, .nebula, .grokPool, .longcat: false
            }
        }
    }

    let id: String
    let product: Product
    let edition: String?
    let tier: String?
    let seatID: String?
    let subscribed: Bool
    let windows: [UsageWindow]
    /// Verified order expiry date. nil when the provider does not expose one.
    let expiryDate: Date?
    /// Per-bucket error message from arkcli (e.g. "no seat bound to caller").
    let errorMessage: String?
    /// DeepSeek-specific balance/usage breakdown (nil for every other provider).
    var deepseek: DeepSeekSummary? = nil
    /// Nebula (new-api relay) balance/usage breakdown (nil for other providers).
    var nebula: NebulaSummary? = nil
    /// GrokPool (grok2api admin gateway) operational summary (nil for other
    /// providers). Fully isolated from the Nebula tab's data.
    var grokPool: GrokPoolSummary? = nil
    /// LongCat (longcat.chat) token-resource-package quota (nil for other
    /// providers). The ring shows the remaining-token percentage.
    var longcat: LongCatSummary? = nil

    /// The tightest window (highest used percent) — what the bar icon reflects.
    var tightestWindow: UsageWindow? {
        windows.max(by: { $0.usedPercent < $1.usedPercent })
    }

    /// Days until the plan expires/renews. nil if unknown.
    var daysUntilExpiry: Int? {
        guard let expiryDate else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.startOfDay(for: expiryDate)
        return cal.dateComponents([.day], from: start, to: end).day
    }
}

/// Aggregated snapshot returned by a provider for the current identity.
struct ProviderSnapshot: Sendable, Equatable {
    /// Provider label, e.g. "arkcli", "Ark API Key".
    let providerName: String
    /// How the request was authenticated, for display ("sso", "aksk", "apikey").
    let authMethod: String?
    /// Active plans. Empty if nothing subscribed or fetch failed softly.
    let plans: [PlanSnapshot]
    /// Last successful update time.
    let updatedAt: Date
    /// Soft per-provider error (still render the icon dimmed + show reason).
    let errorMessage: String?

    /// Tightest window across all plans — drives the menu bar icon.
    var tightestWindow: UsageWindow? {
        plans.compactMap(\.tightestWindow).max(by: { $0.usedPercent < $1.usedPercent })
    }

    /// The immediate Session / 5-hour allowance is the single, stable metric
    /// shown in the menu-bar status item. This avoids silently substituting a
    /// monthly percentage for the session number users expect to see there.
    var sessionWindow: UsageWindow? {
        if let codingSession = plans.first(where: {
            $0.product == .codingPlan || $0.product == .codingPlanTeam
        })?.windows.first(where: { $0.sortRank == 0 }) {
            return codingSession
        }
        return plans.lazy
            .flatMap(\.windows)
            .first { $0.sortRank == 0 }
    }

    /// Menu-bar metric using CodexBar's combined-display rule: normally the
    /// Session / 5-hour number, but a longer-cadence window (weekly / monthly)
    /// with zero remaining overrides it — an exhausted pool blocks every request
    /// even while the freshly-reset session ring still reads 100%.
    var menuBarWindow: UsageWindow? {
        if let exhausted = plans.flatMap(\.windows)
            .filter({ $0.sortRank > 0 && $0.remainingPercent <= 0 })
            .min(by: { $0.sortRank < $1.sortRank })
        {
            return exhausted
        }
        return sessionWindow
    }
}

// MARK: - Provider protocol

/// A source of usage data. Add new subscriptions/plans by implementing this.
protocol UsageProvider: AnyObject, Sendable {
    var displayName: String { get }
    /// Whether the provider has the credentials/state needed to attempt a fetch.
    func isAvailable(environment: [String: String]) -> Bool
    func fetch(environment: [String: String]) async throws -> ProviderSnapshot
}

// MARK: - Fetch errors

enum UsageError: LocalizedError, Sendable {
    case arkcliNotFound
    case arkcliNotAuthenticated
    case arkcliTimedOut
    case arkcliFailed(exitCode: Int32, message: String)
    case missingCredentials
    case networkError(String)
    case apiError(statusCode: Int, message: String)
    case parseFailed(String)
    case noPlanUsage(String?)
    case openCodeCookieMissing
    case openCodeCookieInvalid
    case openCodeBrowserSessionMissing(String)
    case deepSeekMissingCredentials
    case deepSeekInvalidPlatformToken
    case nebulaMissingCredentials
    case nebulaInvalidToken
    case nebulaBrowserSessionMissing(String)
    case zaiMissingCredentials
    case zaiInvalidToken
    case kimiMissingCredentials
    case kimiInvalidToken
    case grokPoolMissingCredentials
    case grokPoolInvalidToken
    case longcatMissingCredentials
    case longcatInvalidSession

    var errorDescription: String? {
        switch self {
        case .arkcliNotFound:
            L(.errorArkcliNotFound)
        case .arkcliNotAuthenticated:
            L(.errorArkcliNotAuthenticated)
        case .arkcliTimedOut:
            L(.errorArkcliTimedOut)
        case let .arkcliFailed(code, message):
            String(format: L(.errorArkcliFailed), code, message)
        case .missingCredentials:
            L(.errorMissingCredentials)
        case let .networkError(message):
            String(format: L(.errorNetwork), message)
        case let .apiError(code, message):
            String(format: L(.errorAPI), code, message)
        case let .parseFailed(message):
            String(format: L(.errorParse), message)
        case let .noPlanUsage(message):
            if let message, !message.isEmpty {
                String(format: L(.errorNoPlan), message)
            } else {
                String(format: L(.errorNoPlan), "-")
            }
        case .openCodeCookieMissing:
            L(.errorOpenCodeCookieMissing)
        case .openCodeCookieInvalid:
            L(.errorOpenCodeCookieInvalid)
        case let .openCodeBrowserSessionMissing(message):
            message
        case .deepSeekMissingCredentials:
            L(.errorDeepSeekMissingCredentials)
        case .deepSeekInvalidPlatformToken:
            L(.errorDeepSeekInvalidPlatformToken)
        case .nebulaMissingCredentials:
            L(.errorNebulaMissingCredentials)
        case .nebulaInvalidToken:
            L(.errorNebulaInvalidToken)
        case let .nebulaBrowserSessionMissing(message):
            message
        case .zaiMissingCredentials:
            L(.errorZaiMissingCredentials)
        case .zaiInvalidToken:
            L(.errorZaiInvalidToken)
        case .kimiMissingCredentials:
            L(.errorKimiMissingCredentials)
        case .kimiInvalidToken:
            L(.errorKimiInvalidToken)
        case .grokPoolMissingCredentials:
            L(.errorGrokPoolMissingCredentials)
        case .grokPoolInvalidToken:
            L(.errorGrokPoolInvalidToken)
        case .longcatMissingCredentials:
            L(.errorLongcatMissingCredentials)
        case .longcatInvalidSession:
            L(.errorLongcatInvalidSession)
        }
    }
}
