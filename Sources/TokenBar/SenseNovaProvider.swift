import Foundation

// MARK: - Provider

/// SenseNova (商汤日日新) Token Plan usage.
///
/// The plan page is `https://www.sensenova.cn/token-plan`, the console is
/// `platform.sensenova.cn/console`, and the model gateway is
/// `token.sensenova.cn/v1`. Quota is NOT reachable with the plan API key: the
/// console's own API (see `probeCandidates`) only accepts the OAuth access
/// token the console SPA keeps for the signed-in user, and that token can only
/// be minted through an interactive Hydra login (`iam.sensecoreapi.cn`, SMS
/// code) — so until that credential path is settled the provider reports the
/// state honestly instead of inventing numbers. The session import is gated on
/// a real sign-in cookie, and every probe response lands in
/// `~/Library/Application Support/TokenBar/sensenova-last-response.txt`.
final class SenseNovaProvider: UsageProvider {
    let displayName = "商汤"

    /// The Token Plan quota lives on the console's own API, discovered from the
    /// console bundle: the dashboard component fetches
    /// `${location.origin}/lite/console/v1/tokenplan/pool-usage` (dual credit
    /// pools) and `…/credit-usage-trend`, through an axios layer that always
    /// sends `Authorization: Bearer <oauth access token>`. The plan API key is
    /// rejected there (`Authentication type 'apikey' is not enabled`) and the
    /// console session cookie alone is not a credential for this API, so the
    /// probes below exist to record what the endpoint says rather than to
    /// guess paths any more.
    private static let probeCandidates: [String] = [
        "https://platform.sensenova.cn/lite/console/v1/tokenplan/pool-usage",
        "https://platform.sensenova.cn/lite/console/v1/tokenplan/credit-usage-trend",
    ]

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private let settings: AppSettings
    private let transport: any HTTPTransport

    init(settings: AppSettings, transport: any HTTPTransport = defaultHTTPTransport()) {
        self.settings = settings
        self.transport = transport
    }

    func isAvailable(environment _: [String: String]) -> Bool { true }

    func fetch(environment: [String: String]) async throws -> ProviderSnapshot {
        // API key first: the token gateway accepts Bearer keys; probe
        // /v1/models and read any quota headers it returns.
        let envKey = environment["SENSENOVA_API_KEY"]
        let apiKey = await MainActor.run {
            Self.trimmed(self.settings.senseNovaAPIKey) ?? Self.trimmed(envKey)
        }
        if let apiKey {
            if let quota = try? await fetchGatewayHeaders(apiKey: apiKey),
               !quota.windows.isEmpty || quota.expiryDate != nil
            {
                return Self.makeSnapshotFromHeaders(quota)
            }
        }
        let manual = await MainActor.run { self.settings.senseNovaManualCookie }
        let session: SenseNovaBrowserSession.Session
        if let manual = Self.trimmed(manual) {
            session = SenseNovaBrowserSession.Session(
                cookieHeader: manual, sourceLabel: L(.manualCookie))
        } else if let cached = SenseNovaBrowserSession.cachedSession() {
            session = cached
        } else {
            throw UsageError.senseNovaMissingCredentials
        }
        // A pasted or imported bag without the Hydra session cookie is not a
        // sign-in; say so instead of spending requests on it.
        guard SenseNovaBrowserSession.hasSignInCookie(session.cookieHeader) else {
            Self.writeDiagnostic(
                "session has no sign-in cookie (names: "
                + SenseNovaBrowserSession.cookieNames(session.cookieHeader) + ")")
            throw UsageError.senseNovaMissingCredentials
        }

        var log: [String] = ["session: \(session.sourceLabel)"]
        var sawAuthRejection = false
        for urlString in Self.probeCandidates {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = 15
            request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("https://platform.sensenova.cn/console", forHTTPHeaderField: "Referer")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

            let response: HTTPResponse
            do {
                response = try await transport.response(for: request)
            } catch {
                log.append("PROBE \(urlString) network-error")
                continue
            }
            let head = String(data: response.data, encoding: .utf8)?.prefix(400)
                .replacingOccurrences(of: "\n", with: " ") ?? ""
            log.append("PROBE \(urlString) http=\(response.statusCode) head=\(head)")

            // A quota payload carries credit/usage/plan keys.
            if response.statusCode == 200,
               let text = String(data: response.data, encoding: .utf8),
               text.contains("credit") || text.contains("quota")
                   || text.contains("usage") || text.contains("pools")
            {
                if let parsed = Self.parseQuota(text) {
                    Self.writeDiagnostic(log.joined(separator: "\n"))
                    return Self.makeSnapshot(from: parsed, authMethod: session.sourceLabel)
                }
            }
            // One rejection must not end the chain: the console answers 401 for
            // every candidate that is not a cookie-authenticated API, and the
            // real cause only shows up in the accumulated responses.
            if response.statusCode == 401 || response.statusCode == 403 {
                sawAuthRejection = true
            }
        }
        Self.writeDiagnostic(log.joined(separator: "\n"))
        if sawAuthRejection {
            throw UsageError.senseNovaInvalidSession
        }
        throw UsageError.senseNovaNotSupported
    }

    // MARK: - API-key gateway probe

    /// Zero-cost probe: `GET /v1/models` on the token gateway with the API
    /// key; every response header is dumped to the diagnostic so the real
    /// quota contract can be confirmed from one response.
    private func fetchGatewayHeaders(apiKey: String) async throws -> GatewayQuotaHeaders.Quota {
        guard let url = URL(string: "https://token.sensenova.cn/v1/models") else {
            throw UsageError.parseFailed("Invalid SenseNova gateway URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.response(for: request)
        var headers: [String: String] = [:]
        if let http = response.response as? HTTPURLResponse {
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key] = value
                }
            }
        }
        Self.writeDiagnostic("gateway http=\(response.statusCode)\n\(GatewayQuotaHeaders.dump(headers))")
        switch response.statusCode {
        case 200:
            return GatewayQuotaHeaders.parse(headers)
        case 401, 403:
            throw UsageError.senseNovaInvalidSession
        default:
            throw UsageError.apiError(
                statusCode: response.statusCode,
                message: "SenseNova gateway: \(String(data: response.data, encoding: .utf8) ?? "")")
        }
    }

    static func makeSnapshotFromHeaders(_ quota: GatewayQuotaHeaders.Quota) -> ProviderSnapshot {
        let windows = quota.windows
            .sorted { $0.label != "5-hour" && $1.label == "5-hour" }
            .map {
                UsageWindow(
                    label: $0.label,
                    usedPercent: $0.usedPercent,
                    used: Int($0.used),
                    total: Int($0.total),
                    resetsAt: $0.resetsAt)
            }
        let plan = PlanSnapshot(
            id: "sensenova-token-plan",
            product: .senseNovaCodingPlan,
            edition: "Token Plan",
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: windows,
            expiryDate: quota.expiryDate,
            errorMessage: nil)
        return ProviderSnapshot(
            providerName: "商汤",
            authMethod: "apikey",
            plans: [plan],
            updatedAt: Date(),
            errorMessage: nil)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Parsing (placeholder until a capture lands)

    struct QuotaSnapshot: Sendable, Equatable {
        var usedPercent: Double?
        var remaining: Double?
        var total: Double?
        var resetsAt: Date?
        var expiryDate: Date?
    }

    /// Tolerant quota extraction across plausible field names. Returns nil
    /// when nothing quota-like is present (a login page or an error body).
    static func parseQuota(_ text: String) -> QuotaSnapshot? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return nil }

        func flatten(_ value: Any, depth: Int = 0) -> [String: Any] {
            var out: [String: Any] = [:]
            guard depth < 4 else { return out }
            if let dict = value as? [String: Any] {
                for (key, item) in dict {
                    out[key] = item
                    out.merge(flatten(item, depth: depth + 1)) { current, _ in current }
                }
            }
            return out
        }

        let flat = flatten(root)
        func number(_ keys: [String]) -> Double? {
            for key in keys {
                switch flat[key] {
                case let number as NSNumber:
                    return number.doubleValue
                case let string as String:
                    if let value = Double(string) { return value }
                default:
                    continue
                }
            }
            return nil
        }
        func date(_ keys: [String]) -> Date? {
            for key in keys {
                guard let string = flat[key] as? String else { continue }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let value = formatter.date(from: string) { return value }
                formatter.formatOptions = [.withInternetDateTime]
                if let value = formatter.date(from: string) { return value }
            }
            return nil
        }

        let used = number(["used", "usedCredit", "usedCredits", "consumed", "usedQuota"])
        let remaining = number(["remaining", "remainingCredit", "remainingCredits", "left", "balance"])
        let total = number(["total", "totalCredit", "totalCredits", "quota", "limit", "capacity"])
        let percent = number(["usedPercent", "percent", "usagePercent", "ratio"])

        var usedPercent = percent
        if usedPercent == nil, let used, let total, total > 0 {
            usedPercent = used / total * 100
        } else if usedPercent == nil, let used, let remaining {
            usedPercent = used / (used + remaining) * 100
        }
        guard usedPercent != nil || remaining != nil || total != nil else { return nil }
        return QuotaSnapshot(
            usedPercent: usedPercent.map { min(100, max(0, $0)) },
            remaining: remaining,
            total: total,
            resetsAt: date(["resetTime", "resetsAt", "resetAt"]),
            expiryDate: date(["expireTime", "expireAt", "expiresAt", "validUntil"]))
    }

    static func makeSnapshot(from quota: QuotaSnapshot, authMethod: String) -> ProviderSnapshot {
        let windows: [UsageWindow] = {
            guard let usedPercent = quota.usedPercent else { return [] }
            return [UsageWindow(
                label: "5-hour",
                usedPercent: usedPercent,
                used: {
                    guard let total = quota.total, let remaining = quota.remaining else { return nil }
                    return Int(max(0, total - remaining))
                }(),
                total: quota.total.map { Int($0) },
                resetsAt: quota.resetsAt)]
        }()
        let plan = PlanSnapshot(
            id: "sensenova-token-plan",
            product: .senseNovaCodingPlan,
            edition: "Token Plan",
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: windows,
            expiryDate: quota.expiryDate,
            errorMessage: nil)
        return ProviderSnapshot(
            providerName: "商汤",
            authMethod: authMethod,
            plans: [plan],
            updatedAt: Date(),
            errorMessage: nil)
    }

    static func writeDiagnostic(_ text: String) {
        guard let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TokenBar", isDirectory: true)
        else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(
            to: dir.appendingPathComponent("sensenova-last-response.txt"),
            atomically: true, encoding: .utf8)
    }
}
