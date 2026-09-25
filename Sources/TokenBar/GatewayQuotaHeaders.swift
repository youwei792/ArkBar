import Foundation

/// Shared parser for quota information carried in model-gateway response
/// headers. Several coding-plan gateways expose the rolling window limits as
/// `x-ratelimit-*` / `x-quota-*` / `x-credit-*` headers on ordinary API calls;
/// a zero-cost `GET /v1/models` probe reads them without consuming quota.
///
/// Header names vary per vendor, so the parser is deliberately broad: it
/// recognizes common spellings and dumps every header it saw into a diagnostic
/// so a new vendor's contract can be confirmed from one real response.
enum GatewayQuotaHeaders {
    struct Window: Equatable {
        let label: String
        let used: Double
        let total: Double
        let resetsAt: Date?

        var usedPercent: Double {
            total > 0 ? min(100, max(0, used / total * 100)) : 0
        }
    }

    struct Quota: Equatable {
        var windows: [Window] = []
        var expiryDate: Date?
    }

    /// Parses recognized quota headers. `now` anchors relative resets.
    static func parse(_ headers: [String: String], now: Date = Date()) -> Quota {
        // HTTP headers are case-insensitive; normalize to lowercase keys.
        var flat: [String: String] = [:]
        for (key, value) in headers {
            flat[key.lowercased()] = value
        }

        var quota = Quota()

        // Expiry headers.
        for key in ["x-subscription-expires-at", "x-plan-expires-at", "x-quota-expires-at"] {
            if let value = flat[key], let date = parseDate(value) {
                quota.expiryDate = date
                break
            }
        }

        // Remaining/limit pairs, tried in a stable order so the same vendor
        // always yields the same window labels.
        let pairs: [(label: String, remainingKey: String, limitKey: String, resetKey: String)] = [
            ("5-hour", "x-ratelimit-remaining-requests", "x-ratelimit-limit-requests", "x-ratelimit-reset-requests"),
            ("5-hour", "x-request-remaining", "x-request-limit", "x-request-reset"),
            ("5-hour", "x-ratelimit-remaining", "x-ratelimit-limit", "x-ratelimit-reset"),
            ("Weekly", "x-ratelimit-remaining-tokens", "x-ratelimit-limit-tokens", "x-ratelimit-reset-tokens"),
            ("5-hour", "x-quota-remaining-requests", "x-quota-limit-requests", "x-quota-reset-requests"),
            ("Monthly", "x-credit-remaining", "x-credit-limit", "x-credit-reset"),
            ("Monthly", "x-quota-remaining", "x-quota-limit", "x-quota-reset"),
            ("Monthly", "x-remaining-credits", "x-credit-limit-credits", "x-credit-reset"),
        ]
        var seenLabels: Set<String> = []
        for pair in pairs {
            guard let remaining = flat[pair.remainingKey].flatMap(Double.init),
                  let limit = flat[pair.limitKey].flatMap(Double.init),
                  limit > 0
            else { continue }
            // One window per label: the first matching pair wins.
            guard seenLabels.insert(pair.label).inserted else { continue }
            let used = max(0, limit - remaining)
            var resetsAt: Date?
            if let reset = flat[pair.resetKey] {
                if let seconds = Double(reset) {
                    resetsAt = now.addingTimeInterval(max(0, seconds))
                } else if let date = parseDate(reset) {
                    resetsAt = date
                }
            }
            quota.windows.append(Window(
                label: pair.label, used: used, total: limit, resetsAt: resetsAt))
        }
        return quota
    }

    /// Human-readable dump of every header (for the support diagnostic).
    /// Credential-bearing headers are dropped: diagnostics may be shared with
    /// support, and a gateway `Set-Cookie` must never land in a file.
    static func dump(_ headers: [String: String]) -> String {
        headers
            .filter { key, _ in
                let lower = key.lowercased()
                return !lower.contains("cookie")
                    && !lower.contains("authorization")
                    && !lower.contains("token")
                    && !lower.contains("api-key")
                    && !lower.contains("secret")
            }
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
