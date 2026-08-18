import Foundation

// MARK: - API response types

/// LongCat (longcat.chat) wraps every response in a Meituan-style envelope:
/// `{"code": 0, "message": "...", "data": { ... } }`. The exact `data` field
/// names are undocumented, so extraction walks the decoded JSON with lenient
/// candidate keys. See `LongCatUsageFetcher` for the pinned field paths.
enum LongCatEnvelope {
    /// Returns the `data` payload when the envelope reports success, else throws.
    static func unwrap(_ object: Any?) throws -> Any {
        guard let dict = object as? [String: Any] else {
            throw UsageError.parseFailed("LongCat response was not a JSON object")
        }
        // Meituan envelopes use code == 0 for success; some surfaces use 200.
        if let code = LongCatJSON.int(dict["code"]), code != 0, code != 200 {
            let message = LongCatJSON.string(dict["message"])
                ?? LongCatJSON.string(dict["msg"]) ?? "code \(code)"
            if code == 401 || code == 403 { throw UsageError.longcatInvalidSession }
            throw UsageError.apiError(statusCode: code, message: message)
        }
        return dict["data"] ?? dict
    }
}

/// Tiny dynamic-JSON helper for lenient extraction by candidate key names.
enum LongCatJSON {
    static func int(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: v
        case let v as Double: Int(v)
        case let v as String: Int(v) ?? Double(v).map(Int.init)
        case let v as NSNumber: v.intValue
        default: nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: v
        case let v as Int: Double(v)
        case let v as String: Double(v)
        case let v as NSNumber: v.doubleValue
        default: nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let v as Bool: return v
        case let v as Int: return v != 0
        case let v as String: return v == "1" || v.lowercased() == "true" || (Bool(v) ?? false)
        case let v as NSNumber: return v.boolValue
        default: return nil
        }
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let v as String: v
        case let v as NSNumber: v.stringValue
        default: nil
        }
    }

    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [[String: Any]]? {
        if let arr = value as? [[String: Any]] { return arr }
        if let arr = value as? [Any] { return arr.compactMap { $0 as? [String: Any] } }
        return nil
    }
}

// MARK: - Provider

/// LongCat (longcat.chat) token-resource-package monitoring.
///
/// LongCat's public API (`api.longcat.chat`) exposes no usage endpoint. The
/// quota lives behind the web console (`longcat.chat`), which authenticates via
/// browser cookies. The console now reads the active token pack from the pay
/// metering service (`POST /api/pay/quota/metering/token-packs/summary`) — the
/// legacy `GET /api/lc-platform/v1/tokenUsage` endpoint returns a "new user"
/// template for every account and must not be used. The provider posts an empty
/// JSON body with a Cookie header imported from the browser or pasted manually.
/// There is no money balance — the ring shows the remaining-token percentage.
final class LongCatProvider: UsageProvider {
    let displayName = "LongCat"

    static let host = "https://longcat.chat"
    static let tokenPackSummaryPath = "/api/pay/quota/metering/token-packs/summary"
    static let userCurrentPath = "/api/v1/user-current"
    static let pendingFuelPath = "/api/lc-platform/v1/pending-fuel-packages"
    static let timeoutSeconds: TimeInterval = 15

    private let settings: AppSettings
    private let transport: any HTTPTransport

    init(settings: AppSettings, transport: any HTTPTransport = defaultHTTPTransport()) {
        self.settings = settings
        self.transport = transport
    }

    /// Credentials are resolved inside `fetch` (settings Keychain / browser /
    /// env). Always report available so the tab can surface the error.
    func isAvailable(environment: [String: String]) -> Bool {
        true
    }

    func fetch(environment: [String: String]) async throws -> ProviderSnapshot {
        let cookieHeader = try await resolveCookieHeader(environment: environment)

        // Account name (optional — the payload also carries a session token
        // and phone number, so its body is never logged).
        var account: String?
        if let data = try await request(Self.userCurrentPath, method: "GET", cookieHeader: cookieHeader, required: false),
           let object = try? LongCatEnvelope.unwrap(LongCatJSON.object(data) ?? data) as? [String: Any]
        {
            account = LongCatJSON.string(object["name"]) ?? LongCatJSON.string(object["nickName"])
        }

        // Token quota: the console's pay metering service. `data.currentLot`
        // holds the active token pack with total/consumed/remaining tokens.
        guard let summaryData = try await request(
            Self.tokenPackSummaryPath,
            method: "POST",
            body: "{}",
            cookieHeader: cookieHeader,
            required: true
        ) else {
            throw UsageError.longcatInvalidSession
        }
        guard let summaryObject = try LongCatEnvelope.unwrap(summaryData) as? [String: Any] else {
            throw UsageError.parseFailed("LongCat token pack summary data was not an object")
        }
        guard let currentLot = LongCatJSON.object(summaryObject["currentLot"]) else {
            throw UsageError.parseFailed("LongCat token pack summary missing currentLot")
        }
        // A valid token pack always has totalToken > 0. The console returns
        // code 0 with an empty currentLot only when the session is invalid, so
        // treat a missing/zero pack as an invalid session and prompt a
        // browser-session re-import.
        let total = LongCatJSON.double(currentLot["totalToken"]) ?? 0
        guard total > 0 else {
            throw UsageError.longcatInvalidSession
        }

        // Fuel packs (optional — best-effort, legacy endpoint still served).
        var fuel: [String: Any]?
        if let data = try await request(Self.pendingFuelPath, method: "GET", cookieHeader: cookieHeader, required: false),
           let object = try? LongCatEnvelope.unwrap(data) as? [String: Any]
        {
            fuel = object
        }

        let expiry = Self.parseDate(currentLot["expireTime"]) ?? Self.summaryNearestFuelExpiry(fuel)
        let summary = Self.makeSummary(
            account: account,
            usage: currentLot,
            fuel: fuel,
            expiry: expiry)
        // The ring reflects remaining-token percentage: 0% used means the
        // package is full, so the remaining percent is the remaining ratio.
        let window = UsageWindow(
            label: "balance",
            usedPercent: max(0, min(100, summary.usedPercent)),
            used: Int(summary.usedToken),
            total: Int(summary.totalToken),
            resetsAt: expiry)
        let plan = PlanSnapshot(
            id: "longcat",
            product: .longcat,
            edition: nil,
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: [window],
            expiryDate: expiry,
            errorMessage: nil,
            deepseek: nil,
            nebula: nil,
            grokPool: nil,
            longcat: summary)
        return ProviderSnapshot(
            providerName: displayName,
            authMethod: "cookie",
            plans: [plan],
            updatedAt: Date(),
            errorMessage: nil)
    }

    // MARK: - Credential resolution

    /// Resolves the Cookie header from (in order): manual setting, cached
    /// browser session, environment variable. Throws if none found.
    private func resolveCookieHeader(environment: [String: String]) async throws -> String {
        let manual = await MainActor.run { settings.longcatCookie }
        if !manual.isEmpty {
            UsageStore.log("LongCat: using manual cookie (length \(manual.count))")
            return manual
        }
        if let cached = LongCatBrowserSession.cachedSession() {
            UsageStore.log("LongCat: using cached browser session from \(cached.sourceLabel) (length \(cached.cookieHeader.count))")
            return cached.cookieHeader
        }
        if let envValue = LongCatCredentialResolver.cookieHeader(environment: environment) {
            UsageStore.log("LongCat: using environment cookie (length \(envValue.count))")
            return envValue
        }
        UsageStore.log("LongCat: no cookie source available")
        throw UsageError.longcatMissingCredentials
    }

    // MARK: - HTTP

    private func request(
        _ path: String,
        method: String,
        body: String? = nil,
        cookieHeader: String,
        required: Bool
    ) async throws -> [String: Any]? {
        guard let url = URL(string: Self.host + path) else {
            throw UsageError.networkError("Invalid LongCat URL: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data((body ?? "{}").utf8)
        }
        request.setValue(Self.host, forHTTPHeaderField: "Origin")
        request.setValue("\(Self.host)/platform/usage", forHTTPHeaderField: "Referer")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403
                || (300..<400).contains(response.statusCode)
            {
                throw UsageError.longcatInvalidSession
            }
            if required {
                throw UsageError.apiError(statusCode: response.statusCode, message: "LongCat \(path)")
            }
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            if required {
                throw UsageError.parseFailed("LongCat \(path) returned non-JSON")
            }
            return nil
        }
        return object
    }

    // MARK: - Summary builder

    static func makeSummary(
        account: String?,
        usage: [String: Any],
        fuel: [String: Any]?,
        expiry: Date? = nil) -> LongCatSummary
    {
        let total = LongCatJSON.double(usage["totalToken"]) ?? 0
        let used = LongCatJSON.double(usage["consumedToken"])
            ?? LongCatJSON.double(usage["usedToken"]) ?? 0
        let available = LongCatJSON.double(usage["remainingToken"])
            ?? LongCatJSON.double(usage["availableToken"]) ?? max(0, total - used)

        var fuelPackTotal: Double?
        var fuelPackRemaining: Double?
        // The token-pack lot carries its own expiry; fuel packages may too.
        var nearestExpiry = expiry ?? parseDate(usage["expireTime"])
        if let fuel {
            let total = LongCatJSON.double(fuel["totalQuota"])
            let packages = LongCatJSON.array(fuel["list"]) ?? []
            var remaining = 0.0
            var sawRemaining = false
            for package in packages {
                if let value = LongCatJSON.double(package["availableToken"]) {
                    remaining += value
                    sawRemaining = true
                }
                if let packageExpiry = parseDate(package["expireTime"]) {
                    if nearestExpiry == nil || packageExpiry < nearestExpiry! {
                        nearestExpiry = packageExpiry
                    }
                }
            }
            if let total, total > 0 {
                fuelPackTotal = total
                fuelPackRemaining = sawRemaining ? remaining : total
            }
        }

        return LongCatSummary(
            totalToken: total,
            usedToken: used,
            availableToken: available,
            fuelPackTotal: fuelPackTotal,
            fuelPackRemaining: fuelPackRemaining,
            nearestFuelExpiry: nearestExpiry,
            accountName: account)
    }

    /// Expiry from fuel-pack packages only (used when the token-pack lot has
    /// no `expireTime`).
    private static func summaryNearestFuelExpiry(_ fuel: [String: Any]?) -> Date? {
        guard let fuel,
              let packages = LongCatJSON.array(fuel["list"])
        else { return nil }
        var nearest: Date?
        for package in packages {
            if let expiry = parseDate(package["expireTime"]) {
                if nearest == nil || expiry < nearest! {
                    nearest = expiry
                }
            }
        }
        return nearest
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let number = LongCatJSON.double(value) {
            let seconds = number > 1_000_000_000_000 ? number / 1000 : number
            if seconds > 1_000_000_000 {
                return Date(timeIntervalSince1970: seconds)
            }
        }
        if let string = LongCatJSON.string(value) {
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: string) {
                return date
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }
}

// MARK: - Credentials

/// Reads a LongCat console Cookie header from the environment. Settings
/// (Keychain) and browser-session values take precedence; these are the
/// fallback.
enum LongCatCredentialResolver {
    static let cookieHeaderKeys = ["LONGCAT_MANUAL_COOKIE", "longcat_manual_cookie"]

    static func cookieHeader(environment: [String: String]) -> String? {
        for key in cookieHeaderKeys {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                continue
            }
            var value = raw
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'"))
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
