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
        case "session", "5h", "5-hour", "five_hour": 0
        case "weekly", "week": 1
        case "monthly", "month": 2
        default: 3
        }
    }

    var displayName: String { L10n.shared.windowName(label) }
}

/// One subscribed product (e.g. personal Coding Plan, team Agent Plan).
struct PlanSnapshot: Sendable, Equatable, Identifiable {
    enum Product: String, Sendable, Equatable {
        case codingPlan = "coding-plan"
        case agentPlan = "agent-plan"
        case codingPlanTeam = "coding-plan-team"
        case agentPlanTeam = "agent-plan-team"

        var displayName: String {
            L10n.shared.productName(self)
        }

        /// True for the `*-team` variants.
        var isTeam: Bool {
            switch self {
            case .codingPlanTeam, .agentPlanTeam: true
            default: false
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
        }
    }
}
