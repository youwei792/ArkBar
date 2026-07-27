import Foundation

/// OpenCode Go usage provider.
///
/// Pulls rolling/weekly/monthly usage from `https://opencode.ai/workspace/<id>/go`,
/// authenticated via a browser cookie the user pastes in Settings. The cookie
/// is stored in Keychain (`CookieKeychainStore`), never in UserDefaults.
///
/// Ported from CodexBar's `OpenCodeGoUsageFetcher` + `OpenCodeGoUsageSnapshot`,
/// trimmed to what ArkBar needs: subscription usage only (no Zen balance, no
/// browser auto-import). The JSON deep-search is replaced by a simpler
/// "top-level + one nested layer" walker; the regex fallback (which CodexBar
/// also keeps as the last resort) handles the rest.
final class OpenCodeGoProvider: UsageProvider {
    let displayName = "OpenCode Go"

    private let settings: AppSettings
    private let session: URLSession

    init(settings: AppSettings) {
        self.settings = settings
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    func isAvailable(environment: [String: String]) -> Bool {
        // Read straight from Keychain (thread-safe) rather than the @MainActor
        // AppSettings mirror, so this stays callable from any context.
        CookieKeychainStore.load(provider: "opencode") != nil
    }

    func fetch(environment: [String: String]) async throws -> ProviderSnapshot {
        // AppSettings is @MainActor-isolated; snapshot the values we need up
        // front so the rest of the fetch runs off the main actor.
        let (rawCookie, workspaceOverride) = await MainActor.run {
            (self.settings.opencodeCookie, self.settings.opencodeWorkspaceID)
        }
        guard let cookieHeader = OpenCodeGoCookieSupport.requestCookieHeader(from: rawCookie) else {
            throw UsageError.missingCredentials
        }

        let workspaceID: String
        if let override = OpenCodeGoCookieSupport.normalizeWorkspaceID(workspaceOverride) {
            workspaceID = override
        } else {
            do {
                workspaceID = try await resolveWorkspaceID(cookieHeader: cookieHeader)
            } catch {
                // Cookie invalid -> clear so the user is prompted to re-paste.
                if case UsageError.missingCredentials = error {
                    Self.clearCookieOnAuthFailure()
                }
                throw error
            }
        }

        let pageText: String
        do {
            pageText = try await fetchUsagePage(workspaceID: workspaceID, cookieHeader: cookieHeader)
        } catch let error as UsageError {
            if case UsageError.missingCredentials = error {
                Self.clearCookieOnAuthFailure()
            }
            throw error
        }

        let now = Date()
        guard let snapshot = parseSubscription(text: pageText, now: now) else {
            throw UsageError.parseFailed("Missing usage fields.")
        }

        return Self.makeProviderSnapshot(snapshot: snapshot, now: now)
    }

    // MARK: - HTTP

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let serverURL = URL(string: "https://opencode.ai/_server")!
    private static let workspacesServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"

    private func resolveWorkspaceID(cookieHeader: String) async throws -> String {
        // GET /_server?id=<workspacesServerID> lists the user's workspaces.
        var components = URLComponents(url: Self.serverURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: Self.workspacesServerID)]
        guard let url = components?.url else {
            throw UsageError.parseFailed("Bad workspace server URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.baseURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.networkError("No HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageError.missingCredentials
        }
        guard http.statusCode == 200 else {
            throw UsageError.apiError(statusCode: http.statusCode, message: "workspace list")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw UsageError.parseFailed("Workspace list was not UTF-8.")
        }
        if OpenCodeGoCookieSupport.looksSignedOut(text: text) {
            throw UsageError.missingCredentials
        }
        if let id = OpenCodeGoCookieSupport.parseFirstWorkspaceID(text: text) {
            return id
        }
        throw UsageError.parseFailed("Missing workspace id. Set it manually in Settings.")
    }

    private func fetchUsagePage(workspaceID: String, cookieHeader: String) async throws -> String {
        let url = URL(string: "https://opencode.ai/workspace/\(workspaceID)/go") ?? Self.baseURL
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.networkError("No HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageError.missingCredentials
        }
        guard http.statusCode == 200 else {
            throw UsageError.apiError(statusCode: http.statusCode, message: "usage page")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw UsageError.parseFailed("Usage page was not UTF-8.")
        }
        if OpenCodeGoCookieSupport.looksSignedOut(text: text) {
            throw UsageError.missingCredentials
        }
        return text
    }

    private static func clearCookieOnAuthFailure() {
        CookieKeychainStore.clear(provider: "opencode")
        // Keep AppSettings.opencodeCookie in sync so the UI stops showing
        // "configured". Load happens on the main actor; do it on next tick.
        Task { @MainActor in
            AppSettings.shared.loadOpenCodeCookieFromKeychain()
        }
    }

    // MARK: - Parsing

    private func parseSubscription(text: String, now: Date) -> OpenCodeGoUsageSnapshot? {
        // JSON first (CodexBar does the same), then regex fallback.
        if let snapshot = parseSubscriptionJSON(text: text, now: now) {
            return snapshot
        }
        return parseSubscriptionRegex(text: text, now: now)
    }

    private func parseSubscriptionJSON(text: String, now: Date) -> OpenCodeGoUsageSnapshot? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any]
        else {
            return nil
        }

        // Look at top-level, then one nested layer (data/result/usage/...).
        if let snapshot = Self.buildSnapshot(from: dict, now: now) {
            return snapshot
        }
        for key in ["data", "result", "usage", "billing", "payload"] {
            if let nested = dict[key] as? [String: Any],
               let snapshot = Self.buildSnapshot(from: nested, now: now)
            {
                return snapshot
            }
        }
        return nil
    }

    /// Find rolling/weekly/monthly sub-dictionaries and build a snapshot.
    private static func buildSnapshot(from dict: [String: Any], now: Date) -> OpenCodeGoUsageSnapshot? {
        let rollingKeys = ["rollingUsage", "rolling", "rolling_usage", "rollingWindow", "rolling_window"]
        let weeklyKeys = ["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow", "weekly_window"]
        let monthlyKeys = ["monthlyUsage", "monthly", "monthly_usage", "monthlyWindow", "monthly_window"]

        guard let rolling = firstDict(from: dict, keys: rollingKeys) else { return nil }
        let weekly = firstDict(from: dict, keys: weeklyKeys)
        let monthly = firstDict(from: dict, keys: monthlyKeys)

        let rollingPercent = percentValue(from: rolling)
        let rollingReset = resetSeconds(from: rolling)
        guard let rollingPercent, let rollingReset else { return nil }

        let weeklyPercent = weekly.flatMap { percentValue(from: $0) }
        let weeklyReset = weekly.flatMap { resetSeconds(from: $0) }
        let hasWeekly = weeklyPercent != nil && weeklyReset != nil

        let monthlyPercent = monthly.flatMap { percentValue(from: $0) }
        let monthlyReset = monthly.flatMap { resetSeconds(from: $0) }
        let hasMonthly = monthlyPercent != nil || monthlyReset != nil

        return OpenCodeGoUsageSnapshot(
            hasWeeklyUsage: hasWeekly,
            hasMonthlyUsage: hasMonthly,
            rollingUsagePercent: rollingPercent,
            weeklyUsagePercent: weeklyPercent ?? 0,
            monthlyUsagePercent: monthlyPercent ?? 0,
            rollingResetInSec: rollingReset,
            weeklyResetInSec: weeklyReset ?? 0,
            monthlyResetInSec: monthlyReset ?? 0,
            updatedAt: now)
    }

    private static func firstDict(from dict: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let sub = dict[key] as? [String: Any] { return sub }
        }
        return nil
    }

    private static let percentKeys = [
        "usagePercent", "usedPercent", "percentUsed", "percent",
        "usage_percent", "used_percent", "utilization", "utilizationPercent",
        "utilization_percent", "usage",
    ]
    private static let resetInKeys = [
        "resetInSec", "resetInSeconds", "resetSeconds", "reset_sec",
        "reset_in_sec", "resetsInSec", "resetsInSeconds", "resetIn", "resetSec",
    ]

    private static func percentValue(from dict: [String: Any]) -> Double? {
        for key in percentKeys {
            if let v = dict[key] as? Double { return v }
            if let v = dict[key] as? Int { return Double(v) }
            if let s = dict[key] as? String, let v = Double(s) { return v }
        }
        return nil
    }

    private static func resetSeconds(from dict: [String: Any]) -> Int? {
        for key in resetInKeys {
            if let v = dict[key] as? Int { return v }
            if let v = dict[key] as? Double { return Int(v) }
            if let s = dict[key] as? String, let v = Int(s) { return v }
        }
        return nil
    }

    // MARK: - Regex fallback (CodexBar's last-resort path)

    private func parseSubscriptionRegex(text: String, now: Date) -> OpenCodeGoUsageSnapshot? {
        guard let rollingPercent = OpenCodeGoCookieSupport.extractDouble(
                pattern: #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text),
              let rollingReset = OpenCodeGoCookieSupport.extractInt(
                pattern: #"rollingUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text)
        else { return nil }

        let weeklyPercent = OpenCodeGoCookieSupport.extractDouble(
            pattern: #"weeklyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text)
        let weeklyReset = OpenCodeGoCookieSupport.extractInt(
            pattern: #"weeklyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text)
        let hasWeekly = weeklyPercent != nil && weeklyReset != nil

        let monthlyPercent = OpenCodeGoCookieSupport.extractDouble(
            pattern: #"monthlyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text)
        let monthlyReset = OpenCodeGoCookieSupport.extractInt(
            pattern: #"monthlyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text)

        return OpenCodeGoUsageSnapshot(
            hasWeeklyUsage: hasWeekly,
            hasMonthlyUsage: monthlyPercent != nil || monthlyReset != nil,
            rollingUsagePercent: rollingPercent,
            weeklyUsagePercent: weeklyPercent ?? 0,
            monthlyUsagePercent: monthlyPercent ?? 0,
            rollingResetInSec: rollingReset,
            weeklyResetInSec: weeklyReset ?? 0,
            monthlyResetInSec: monthlyReset ?? 0,
            updatedAt: now)
    }

    // MARK: - Snapshot mapping

    /// Map the OpenCode Go snapshot into ArkBar's `ProviderSnapshot`:
    /// one plan with three windows (Session=rolling/5h, Weekly, Monthly).
    private static func makeProviderSnapshot(snapshot: OpenCodeGoUsageSnapshot, now: Date) -> ProviderSnapshot {
        let rollingReset = now.addingTimeInterval(TimeInterval(snapshot.rollingResetInSec))
        var windows: [UsageWindow] = [
            UsageWindow(label: "Session", usedPercent: snapshot.rollingUsagePercent,
                        used: nil, total: nil, resetsAt: rollingReset),
        ]
        if snapshot.hasWeeklyUsage {
            let weeklyReset = now.addingTimeInterval(TimeInterval(snapshot.weeklyResetInSec))
            windows.append(UsageWindow(label: "Weekly", usedPercent: snapshot.weeklyUsagePercent,
                                       used: nil, total: nil, resetsAt: weeklyReset))
        }
        if snapshot.hasMonthlyUsage {
            let monthlyReset = now.addingTimeInterval(TimeInterval(snapshot.monthlyResetInSec))
            windows.append(UsageWindow(label: "Monthly", usedPercent: snapshot.monthlyUsagePercent,
                                       used: nil, total: nil, resetsAt: monthlyReset))
        }

        let plan = PlanSnapshot(
            id: "opencode-go",
            product: .codingPlan,   // reuse Coding Plan product for display
            edition: "go",
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: windows,
            expiryDate: nil,
            errorMessage: nil)
        return ProviderSnapshot(
            providerName: L(.openCodeGo),
            authMethod: "cookie",
            plans: [plan],
            updatedAt: now,
            errorMessage: nil)
    }
}

// MARK: - Snapshot model

struct OpenCodeGoUsageSnapshot: Sendable {
    let hasWeeklyUsage: Bool
    let hasMonthlyUsage: Bool
    let rollingUsagePercent: Double
    let weeklyUsagePercent: Double
    let monthlyUsagePercent: Double
    let rollingResetInSec: Int
    let weeklyResetInSec: Int
    let monthlyResetInSec: Int
    let updatedAt: Date
}

// MARK: - Cookie / parsing helpers (ported from CodexBar, trimmed)

/// Cookie normalization + workspace parsing helpers.
/// Mirrors CodexBar's `OpenCodeWebCookieSupport` + `CookieHeaderNormalizer`,
/// kept self-contained so ArkBar has no cross-file dependency on CodexBar code.
enum OpenCodeGoCookieSupport {
    /// Only these cookie names are sent to opencode.ai.
    private static let requestCookieNames: Set<String> = ["auth", "__Host-auth"]

    /// Normalize a raw cookie header (possibly `Cookie: a=1; b=2` or curl `-H '...'`)
    /// and keep only the whitelisted names. Returns nil if none survive.
    static func requestCookieHeader(from rawHeader: String?) -> String? {
        guard let rawHeader else { return nil }
        let pairs = parsePairs(rawHeader)
        let filtered = pairs.filter { requestCookieNames.contains($0.name) }
        guard !filtered.isEmpty else { return nil }
        return filtered.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static func parsePairs(_ raw: String) -> [(name: String, value: String)] {
        // Strip a leading "Cookie:" / "cookie:" prefix.
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip wrapping quotes.
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        var results: [(name: String, value: String)] = []
        for part in value.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            let val = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            results.append((name: String(name), value: String(val)))
        }
        return results
    }

    /// Heuristic: does the response body look like a logged-out page?
    static func looksSignedOut(text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("login") ||
            lower.contains("sign in") ||
            lower.contains("auth/authorize") ||
            lower.contains("not associated with an account") ||
            lower.contains("actor of type \"public\"")
    }

    /// Extract the first `wrk_…` workspace id from a server response.
    static func parseFirstWorkspaceID(text: String) -> String? {
        let pattern = #"id\s*:\s*"(wrk_[^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range),
           match.numberOfRanges >= 2,
           let r = Range(match.range(at: 1), in: text)
        {
            return String(text[r])
        }
        // Fallback: bare wrk_ token anywhere in the text.
        if let r = text.range(of: #"wrk_[A-Za-z0-9]+"#, options: .regularExpression) {
            return String(text[r])
        }
        return nil
    }

    /// Normalize a user-supplied workspace id / URL into a bare `wrk_…`, or nil.
    static func normalizeWorkspaceID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("wrk_"), trimmed.count > 4 { return trimmed }
        if let url = URL(string: trimmed) {
            let parts = url.pathComponents
            if let index = parts.firstIndex(of: "workspace"), parts.count > index + 1 {
                let candidate = parts[index + 1]
                if candidate.hasPrefix("wrk_"), candidate.count > 4 { return candidate }
            }
        }
        if let r = trimmed.range(of: #"wrk_[A-Za-z0-9]+"#, options: .regularExpression) {
            return String(trimmed[r])
        }
        return nil
    }

    static func extractDouble(pattern: String, text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text)
        else { return nil }
        return Double(text[r])
    }

    static func extractInt(pattern: String, text: String) -> Int? {
        guard let value = extractDouble(pattern: pattern, text: text) else { return nil }
        return Int(value)
    }
}
