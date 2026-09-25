import Foundation

// MARK: - Provider

/// SenseNova (商汤日日新) Token Plan usage.
///
/// The plan page is `https://www.sensenova.cn/token-plan`, the console is
/// `platform.sensenova.cn/console`, and the model gateway is
/// `token.sensenova.cn/v1`. Quota comes from the console's own credit-pool
/// meter, which accepts only the OAuth bearer token the console SPA uses — the
/// plan API key is rejected there (`Authentication type 'apikey' is not
/// enabled`), so `SenseNovaConsoleAuth` mints a token from the imported
/// sign-in session and keeps it alive on its refresh token. The gateway probe
/// below stays as the no-sign-in fallback only, since the gateway publishes no
/// quota headers today.
final class SenseNovaProvider: UsageProvider {
    let displayName = "商汤"

    /// The console dashboard's credit-pool endpoint: one entry per pool
    /// (general + model-dedicated), each with a rolling 5-hour and 7-day
    /// window. Discovered from the console bundle, then confirmed against a
    /// live account.
    static let poolUsageURL = "https://platform.sensenova.cn/lite/console/v1/tokenplan/pool-usage"

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
        // The console sign-in is the only source that actually carries Token
        // Plan quota, so it is tried first; the API-key gateway probe (which
        // publishes no quota today) only runs when no sign-in is available, so
        // a working setup spends exactly one request per refresh.
        let session: SenseNovaBrowserSession.Session?
        var sessionError = UsageError.senseNovaMissingCredentials
        do {
            session = try await resolvedSession()
        } catch let error as UsageError {
            session = nil
            sessionError = error
        }

        if let session {
            return try await fetchConsoleQuota(session: session)
        }

        let envKey = environment["SENSENOVA_API_KEY"]
        let apiKey = await MainActor.run {
            Self.trimmed(self.settings.senseNovaAPIKey) ?? Self.trimmed(envKey)
        }
        if let apiKey,
           let quota = try? await fetchGatewayHeaders(apiKey: apiKey),
           !quota.windows.isEmpty || quota.expiryDate != nil
        {
            return Self.makeSnapshotFromHeaders(quota)
        }
        throw sessionError
    }

    /// The pasted or imported console sign-in, when it really is one.
    private func resolvedSession() async throws -> SenseNovaBrowserSession.Session {
        let manual = await MainActor.run { self.settings.senseNovaManualCookie }
        let session: SenseNovaBrowserSession.Session
        if let header = CookieHeaderNormalizer.normalize(manual) {
            session = SenseNovaBrowserSession.Session(
                cookieHeader: header, sourceLabel: L(.manualCookie))
        } else if let cached = SenseNovaBrowserSession.cachedSession() {
            session = cached
        } else {
            throw UsageError.senseNovaMissingCredentials
        }
        // A bag without the Hydra session cookie is not a sign-in; say so
        // instead of spending requests on it.
        guard SenseNovaBrowserSession.hasSignInCookie(session.cookieHeader) else {
            Self.writeDiagnostic(
                "session has no sign-in cookie (names: "
                + SenseNovaBrowserSession.cookieNames(session.cookieHeader) + ")")
            throw UsageError.senseNovaMissingCredentials
        }
        return session
    }

    /// Console quota for a signed-in session, re-minting the bearer token once
    /// if Hydra revoked it ahead of its stated expiry.
    private func fetchConsoleQuota(session: SenseNovaBrowserSession.Session) async throws -> ProviderSnapshot {
        let tokens = try await SenseNovaConsoleAuth.accessToken(sessionCookie: session.cookieHeader)
        do {
            return try await fetchPoolUsage(tokens: tokens, authMethod: session.sourceLabel)
        } catch let error as UsageError {
            guard case let .apiError(status, _) = error, status == 401 || status == 403 else {
                throw error
            }
            UsageStore.log("SenseNova console rejected the token; re-minting")
            SenseNovaConsoleAuth.invalidateCachedToken()
            let refreshed = try await SenseNovaConsoleAuth.accessToken(sessionCookie: session.cookieHeader)
            return try await fetchPoolUsage(tokens: refreshed, authMethod: session.sourceLabel)
        }
    }

    /// One call per refresh: the console's dual credit-pool meter.
    private func fetchPoolUsage(tokens: SenseNovaConsoleAuth.Tokens, authMethod: String) async throws -> ProviderSnapshot {
        guard let url = URL(string: Self.poolUsageURL) else {
            throw UsageError.parseFailed("Invalid SenseNova console URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://platform.sensenova.cn/console", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                // Surfaced as apiError so the caller can tell a rejected token
                // apart from a transport failure and retry once.
                throw UsageError.apiError(statusCode: response.statusCode, message: "SenseNova console")
            }
            let body = String(data: response.data, encoding: .utf8) ?? ""
            Self.writeDiagnostic("pool-usage http=\(response.statusCode) head=\(body.prefix(400))")
            throw UsageError.apiError(
                statusCode: response.statusCode,
                message: "SenseNova pool-usage: \(body.prefix(200))")
        }
        let usage: PoolUsageResponse
        do {
            usage = try JSONDecoder().decode(PoolUsageResponse.self, from: response.data)
        } catch {
            Self.writeDiagnostic(
                "pool-usage unparseable: \(error.localizedDescription) head=\(String(data: response.data, encoding: .utf8)?.prefix(400) ?? "")")
            throw UsageError.parseFailed("SenseNova pool-usage: \(error.localizedDescription)")
        }
        return Self.makeSnapshot(from: usage, authMethod: authMethod)
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

    // MARK: - Credit-pool decoding

    /// Wire numbers arrive as decimal strings; accept either spelling so a
    /// provider-side format change cannot blank the rings.
    struct QuotaNumber: Decodable, Sendable {
        let value: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                value = Double(text)
            } else {
                value = try? container.decode(Double.self)
            }
        }
    }

    struct PoolUsageResponse: Decodable, Sendable {
        struct Plan: Decodable, Sendable {
            let id: String?
            let name: String?
        }

        struct Window: Decodable, Sendable {
            let limit: QuotaNumber?
            let used: QuotaNumber?
            let remaining: QuotaNumber?
            let resetAt: QuotaNumber?

            enum CodingKeys: String, CodingKey {
                case limit, used, remaining
                case resetAt = "reset_at"
            }
        }

        struct Pool: Decodable, Sendable {
            let id: String?
            let name: String?
            let poolType: String?
            let window5h: Window?
            let window7d: Window?

            enum CodingKeys: String, CodingKey {
                case id, name
                case poolType = "pool_type"
                case window5h = "window_5h"
                case window7d = "window_7d"
            }
        }

        let plan: Plan?
        let pools: [Pool]?
    }

    static func parsePoolUsage(_ data: Data) throws -> PoolUsageResponse {
        try JSONDecoder().decode(PoolUsageResponse.self, from: data)
    }

    /// One plan per credit pool, so the general pool and a model-dedicated pool
    /// keep their own meters instead of being averaged into one misleading ring.
    static func makeSnapshot(from usage: PoolUsageResponse, authMethod: String) -> ProviderSnapshot {
        let plans: [PlanSnapshot] = (usage.pools ?? []).compactMap { pool in
            var windows: [UsageWindow] = []
            if let window = pool.window5h {
                windows.append(Self.window(from: window, label: "5-hour"))
            }
            if let window = pool.window7d {
                windows.append(Self.window(from: window, label: "Weekly"))
            }
            windows = windows.filter { ($0.total ?? 0) > 0 }
            guard !windows.isEmpty else { return nil }
            return PlanSnapshot(
                id: "sensenova-\(pool.poolType ?? pool.id ?? "pool")",
                product: .senseNovaCodingPlan,
                edition: pool.name,
                tier: nil,
                seatID: nil,
                subscribed: true,
                windows: windows.sorted { $0.sortRank < $1.sortRank },
                // `nearest_grant_expiry` is a top-up grant's expiry, not the
                // subscription's, so it must not drive the plan badge.
                expiryDate: nil,
                errorMessage: nil)
        }
        return ProviderSnapshot(
            providerName: "商汤",
            authMethod: authMethod,
            plans: plans,
            updatedAt: Date(),
            errorMessage: nil)
    }

    private static func window(
        from source: PoolUsageResponse.Window,
        label: String) -> UsageWindow
    {
        let limit = source.limit?.value
        let used = source.used?.value
        let remaining = source.remaining?.value
        let usedPercent: Double
        if let limit, limit > 0, let used {
            usedPercent = min(100, max(0, used / limit * 100))
        } else if let limit, limit > 0, let remaining {
            usedPercent = min(100, max(0, (limit - remaining) / limit * 100))
        } else {
            usedPercent = 0
        }
        return UsageWindow(
            label: label,
            usedPercent: usedPercent,
            used: used.map { Int($0.rounded()) },
            total: limit.map { Int($0.rounded()) },
            resetsAt: source.resetAt?.value.flatMap {
                $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
            })
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
