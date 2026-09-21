import Foundation

// MARK: - Parsed model

/// StepFun Step Plan usage, before mapping to ArkBar models. The console's
/// dashboard renders fiveHour / weekly windows plus a monthly credit meter,
/// an expire time, and optional topup packs; the parser accepts any subset.
struct StepFunUsageSnapshot: Sendable, Equatable {
    struct Meter: Sendable, Equatable {
        let used: Double
        let total: Double
        let resetsAt: Date?
        var usedPercent: Double {
            total > 0 ? min(100, max(0, used / total * 100)) : 0
        }
    }

    var session: Meter?
    var weekly: Meter?
    /// Monthly plan credit bucket.
    var credit: Meter?
    /// Topup-pack remaining share (0–1), when present.
    var topupLeftRate: Double?
    /// Subscription expiry / next billing date.
    var expiryDate: Date?
    var planName: String?
}

// MARK: - Provider

/// StepFun (阶跃星辰) Step Plan usage via the console's Connect-RPC API.
///
/// The platform gateway (`api.stepfun.com`) only exposes model calls; the
/// Step Plan credit/usage numbers live behind the console SPA at
/// `platform.stepfun.com`, which authenticates with a browser session cookie
/// and exposes a Connect-RPC service `step.openapi.devcenter.Dashboard`
/// (`GetStepPlanStatus`, `QueryStepPlanUsages`). Cookies are imported once via
/// the explicit settings action (Full Disk Access is required to read the
/// browser store on current macOS) and cached in Keychain.
final class StepFunProvider: UsageProvider {
    let displayName = "阶跃"

    private static let statusURL = URL(
        string: "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/GetStepPlanStatus")!
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private let settings: AppSettings
    private let transport: any HTTPTransport

    init(settings: AppSettings, transport: any HTTPTransport = defaultHTTPTransport()) {
        self.settings = settings
        self.transport = transport
    }

    /// Credentials are resolved inside `fetch` (settings/Keychain -> browser cache).
    func isAvailable(environment _: [String: String]) -> Bool { true }

    func fetch(environment: [String: String]) async throws -> ProviderSnapshot {
        // Manual Cookie (pasted once from devtools) beats the browser import:
        // it needs no Full Disk Access or Keychain approvals.
        let manual = await MainActor.run { self.settings.stepFunManualCookie }
        let session: StepFunBrowserSession.Session
        if let manual = Self.trimmed(manual) {
            session = StepFunBrowserSession.Session(
                cookieHeader: manual, sourceLabel: L(.manualCookie))
        } else if let cached = StepFunBrowserSession.cachedSession() {
            session = cached
        } else {
            throw UsageError.stepFunMissingCredentials
        }

        // The console session token lives in the Oasis-Token cookie and
        // expires in ~30 minutes; RefreshToken rotates it (and issues a new
        // Oasis-Webid) on every call, so refresh first, then query.
        let refreshed = try await refreshSession(cookieHeader: session.cookieHeader)
        var usage = try await fetchRateLimit(cookieHeader: refreshed)
        if let status = try? await fetchPlanStatus(cookieHeader: refreshed) {
            usage.expiryDate = status.expiryDate
            usage.planName = status.planName ?? usage.planName
        }
        return Self.makeSnapshot(from: usage, authMethod: session.sourceLabel)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Console RPC

    /// Last HTTPURLResponse seen by `rpc`, so Set-Cookie rotation headers can
    /// be read. The provider is used from a single serialized refresh path.
    private nonisolated(unsafe) static var lastResponse: HTTPURLResponse?

    private static let apiBase = "https://platform.stepfun.com"
    private static let refreshPath =
        "/passport/proto.api.passport.v1.PassportService/RefreshToken"
    private static let rateLimitPath =
        "/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit"
    private static let statusPath =
        "/api/step.openapi.devcenter.Dashboard/GetStepPlanStatus"

    /// POSTs a Connect-RPC call with the console's Oasis-* headers. Returns
    /// the raw body; non-2xx maps to session/api errors.
    private func rpc(_ path: String, cookieHeader: String) async throws -> Data {
        guard let url = URL(string: Self.apiBase + path) else {
            throw UsageError.parseFailed("Invalid StepFun console URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(Self.webID(from: cookieHeader), forHTTPHeaderField: "Oasis-Webid")
        request.setValue("web", forHTTPHeaderField: "Oasis-Platform")
        request.setValue("10300", forHTTPHeaderField: "Oasis-appID")
        request.setValue("\(Self.apiBase)/account-overview", forHTTPHeaderField: "Referer")
        request.httpBody = Data("{}".utf8)

        let response = try await transport.response(for: request)
        Self.lastResponse = response.response
        switch response.statusCode {
        case 200:
            return response.data
        case 401, 403:
            Self.writeDiagnostic("rpc \(path) http=\(response.statusCode)")
            throw UsageError.stepFunInvalidSession
        default:
            let body = String(data: response.data, encoding: .utf8) ?? ""
            throw UsageError.apiError(
                statusCode: response.statusCode, message: "StepFun console: \(body)")
        }
    }

    /// Rotates the session and returns the NEW cookie header (the response's
    /// Set-Cookie carries a fresh Oasis-Token JWT plus a new Oasis-Webid).
    private func refreshSession(cookieHeader: String) async throws -> String {
        let data = try await rpc(Self.refreshPath, cookieHeader: cookieHeader)
        // Set-Cookie values live on the HTTPURLResponse.
        var refreshed: [String: String] = [:]
        if let http = Self.lastResponse {
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String,
                   key.lowercased() == "set-cookie"
                {
                    // A Set-Cookie header can carry several pairs; take the
                    // first name=value of each.
                    for part in value.split(separator: ",") {
                        let pair = part.split(separator: ";")[0]
                        if let eq = pair.firstIndex(of: "=") {
                            let name = pair[..<eq].trimmingCharacters(in: .whitespaces)
                            let val = pair[pair.index(after: eq)...]
                                .split(separator: ";", maxSplits: 1)[0]
                                .trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty {
                                refreshed[String(name)] = String(val)
                            }
                        }
                    }
                }
            }
        }
        if refreshed["Oasis-Token"] == nil {
            // Fall back to the JWT in the body (accessToken.raw).
            if let object = try? JSONSerialization.jsonObject(with: data),
               let root = object as? [String: Any],
               let access = root["accessToken"] as? [String: Any],
               let raw = access["raw"] as? String
            {
                refreshed["Oasis-Token"] = raw
            }
        }
        guard refreshed["Oasis-Token"] != nil else {
            throw UsageError.stepFunInvalidSession
        }
        // Rebuild: keep unrelated cookies, replace the rotated pair.
        var pairs: [String] = []
        for pair in cookieHeader.split(separator: "; ") {
            let name = String(pair.split(separator: "=", maxSplits: 1)[0])
            if name == "Oasis-Token" || name == "Oasis-Webid" { continue }
            pairs.append(String(pair))
        }
        for (name, value) in refreshed where name == "Oasis-Token" || name == "Oasis-Webid" {
            pairs.append("\(name)=\(value)")
        }
        return pairs.joined(separator: "; ")
    }

    private func fetchRateLimit(cookieHeader: String) async throws -> StepFunUsageSnapshot {
        let data = try await rpc(Self.rateLimitPath, cookieHeader: cookieHeader)
        return try Self.parseRateLimit(data)
    }

    private func fetchPlanStatus(cookieHeader: String) async throws -> PlanStatus? {
        let data = try await rpc(Self.statusPath, cookieHeader: cookieHeader)
        return try Self.parsePlanStatus(data)
    }

    private static func webID(from cookieHeader: String) -> String {
        for pair in cookieHeader.split(separator: "; ") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == "Oasis-Webid" {
                return String(parts[1])
            }
        }
        return ""
    }

    // MARK: - Mapping

    static func makeSnapshot(
        from usage: StepFunUsageSnapshot,
        authMethod: String) -> ProviderSnapshot
    {
        var windows: [UsageWindow] = []
        if let session = usage.session {
            windows.append(UsageWindow(
                label: "5-hour", usedPercent: session.usedPercent,
                used: Int(session.used), total: Int(session.total),
                resetsAt: session.resetsAt))
        }
        if let weekly = usage.weekly {
            windows.append(UsageWindow(
                label: "Weekly", usedPercent: weekly.usedPercent,
                used: Int(weekly.used), total: Int(weekly.total),
                resetsAt: weekly.resetsAt))
        }
        if let credit = usage.credit {
            windows.append(UsageWindow(
                label: "Monthly", usedPercent: credit.usedPercent,
                used: Int(credit.used), total: Int(credit.total),
                resetsAt: credit.resetsAt))
        }

        let plan = PlanSnapshot(
            id: "stepfun-step-plan",
            product: .stepfunCodingPlan,
            edition: usage.planName ?? "Step Plan",
            tier: nil,
            seatID: nil,
            subscribed: !windows.isEmpty,
            windows: windows,
            expiryDate: usage.expiryDate,
            errorMessage: nil)
        return ProviderSnapshot(
            providerName: "阶跃",
            authMethod: authMethod,
            plans: [plan],
            updatedAt: Date(),
            errorMessage: nil)
    }

    // MARK: - Decoding (static for tests)

    /// Subscription identity from `GetStepPlanStatus`.
    struct PlanStatus: Sendable, Equatable {
        let planName: String?
        let expiryDate: Date?
    }

    /// Parses `QueryStepPlanRateLimit`: the three rolling windows are
    /// `*_usage_left_rate` (0–1 remaining shares) and the monthly credit
    /// bucket carries absolute totals plus its own expiry.
    static func parseRateLimit(_ data: Data) throws -> StepFunUsageSnapshot {
        guard !data.isEmpty else {
            throw UsageError.parseFailed("Empty StepFun rate-limit body")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UsageError.parseFailed("StepFun: \(error.localizedDescription)")
        }
        guard let root = object as? [String: Any] else {
            throw UsageError.parseFailed("StepFun: expected a JSON object")
        }
        func leftRate(_ key: String) -> Double? {
            Self.number(root[key])
        }
        func resetDate(_ key: String) -> Date? {
            guard let raw = Self.number(root[key]), raw > 0 else { return nil }
            return Date(timeIntervalSince1970: raw)
        }
        var snapshot = StepFunUsageSnapshot()
        // The 5-hour/weekly windows only exist on plan families that carry
        // them: a window that does not apply reports rate 0 AND reset time 0.
        // Treating a 0 rate as "used up" would fake an exhausted ring, so a
        // window is only surfaced when it has a reset time.
        if let rate = leftRate("five_hour_usage_left_rate"),
           resetDate("five_hour_usage_reset_time") != nil
        {
            snapshot.session = StepFunUsageSnapshot.Meter(
                used: (1 - rate) * 100, total: 100,
                resetsAt: resetDate("five_hour_usage_reset_time"))
        }
        if let rate = leftRate("weekly_usage_left_rate"),
           resetDate("weekly_usage_reset_time") != nil
        {
            snapshot.weekly = StepFunUsageSnapshot.Meter(
                used: (1 - rate) * 100, total: 100,
                resetsAt: resetDate("weekly_usage_reset_time"))
        }
        if let plan = root["plan_credit_rate_limit"] as? [String: Any] {
            if let rate = Self.number(plan["subscription_credit_left_rate"]) {
                var used = (1 - rate) * 100
                var total = 100.0
                var resetsAt: Date?
                if let buckets = plan["credit_buckets"] as? [[String: Any]],
                   let bucket = buckets.first
                {
                    let creditTotal = Self.number(bucket["credit_total"])
                    let residual = Self.number(bucket["credit_residual"])
                    if let creditTotal, let residual, creditTotal > 0 {
                        // used/total are absolute Credit units here; the ring
                        // percent comes from their ratio.
                        used = creditTotal - residual
                        total = creditTotal
                        if let expire = Self.number(bucket["expire_at"]), expire > 0 {
                            resetsAt = Date(timeIntervalSince1970: expire)
                        }
                    }
                }
                snapshot.credit = StepFunUsageSnapshot.Meter(used: used, total: total, resetsAt: resetsAt)
            }
            if let topup = Self.number(plan["topup_credit_left_rate"]) {
                snapshot.topupLeftRate = topup
            }
        }
        return snapshot
    }

    static func parsePlanStatus(_ data: Data) throws -> PlanStatus {
        guard !data.isEmpty else {
            throw UsageError.parseFailed("Empty StepFun plan-status body")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UsageError.parseFailed("StepFun: \(error.localizedDescription)")
        }
        guard let root = object as? [String: Any],
              let subscription = root["subscription"] as? [String: Any]
        else {
            throw UsageError.parseFailed("StepFun: missing subscription")
        }
        var expiry: Date?
        if let raw = Self.number(subscription["expired_at"]), raw > 0 {
            expiry = Date(timeIntervalSince1970: raw)
        }
        return PlanStatus(
            planName: subscription["name"] as? String,
            expiryDate: expiry)
    }

    // MARK: - Helpers

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private static func number(_ key: String, in dict: [String: Any]) -> Double? {
        switch dict[key] {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private static func dateValue(_ value: Any) -> Date? {
        switch value {
        case let number as NSNumber:
            let interval = number.doubleValue
            return Date(timeIntervalSince1970: interval > 1_000_000_000_000 ? interval / 1000 : interval)
        case let string as String:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        default:
            return nil
        }
    }

    /// Import-path diagnostic in its own file: the timer refresh overwrites
    /// writeDiagnostic's file within seconds, hiding import failures.
    static func writeImportDiagnostic(_ text: String) {
        guard let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TokenBar", isDirectory: true)
        else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(
            to: dir.appendingPathComponent("stepfun-import.txt"),
            atomically: true, encoding: .utf8)
    }

    /// Support diagnostic: response heads land in the app-support directory
    /// (never cookie values) so a captured payload can be reconciled without
    /// stderr access.
    static func writeDiagnostic(_ text: String) {
        guard let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TokenBar", isDirectory: true)
        else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(
            to: dir.appendingPathComponent("stepfun-last-response.txt"),
            atomically: true, encoding: .utf8)
    }
}
