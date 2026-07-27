import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches the authoritative OpenCode Go subscription page. Authentication can
/// come from an automatically imported browser session or a manually supplied
/// Cookie header. Only `auth` cookies are sent, redirects never leave
/// `opencode.ai`, and no local cost estimate is ever presented as plan quota.
final class OpenCodeGoProvider: UsageProvider {
    let displayName = "OpenCode Go"

    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let serverURL = URL(string: "https://opencode.ai/_server")!
    private static let workspacesServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private let settings: AppSettings
    private let redirectGuard: RedirectGuard
    private let session: URLSession

    init(settings: AppSettings) {
        self.settings = settings
        self.redirectGuard = RedirectGuard()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(
            configuration: configuration,
            delegate: redirectGuard,
            delegateQueue: nil)
    }

    func isAvailable(environment _: [String: String]) -> Bool {
        true
    }

    func fetch(environment _: [String: String]) async throws -> ProviderSnapshot {
        let (source, rawCookie, workspaceOverride) = await MainActor.run {
            (
                self.settings.opencodeCookieSource,
                self.settings.opencodeCookie,
                self.settings.opencodeWorkspaceID
            )
        }

        let credential = try Self.resolveCredential(
            source: source,
            rawManualCookie: rawCookie)
        do {
            return try await fetchSnapshot(
                credential: credential,
                workspaceOverride: workspaceOverride)
        } catch UsageError.openCodeCookieInvalid where source == .automatic {
            // A cached browser session may expire independently of ArkBar.
            // Background and ordinary refreshes must never fall through to a
            // browser-cookie import: doing so causes recurring macOS Keychain
            // prompts. Clear the stale cache and wait for the explicit repair
            // action in OpenCode Go settings.
            OpenCodeGoBrowserSession.clearCache()
            throw UsageError.openCodeBrowserSessionMissing(
                L(.errorOpenCodeBrowserAuthorizationRequired))
        }
    }

    private struct Credential: Sendable {
        let cookieHeader: String
        let sourceLabel: String
    }

    private static func resolveCredential(
        source: AppSettings.OpenCodeCookieSource,
        rawManualCookie: String) throws -> Credential
    {
        switch source {
        case .manual:
            guard let header = OpenCodeGoCookieSupport.requestCookieHeader(from: rawManualCookie) else {
                throw UsageError.openCodeCookieMissing
            }
            return Credential(cookieHeader: header, sourceLabel: L(.manualCookie))
        case .automatic:
            guard let session = OpenCodeGoBrowserSession.cachedSession() else {
                throw UsageError.openCodeBrowserSessionMissing(
                    L(.errorOpenCodeBrowserAuthorizationRequired))
            }
            return Credential(cookieHeader: session.cookieHeader, sourceLabel: session.sourceLabel)
        }
    }

    private func fetchSnapshot(
        credential: Credential,
        workspaceOverride: String) async throws -> ProviderSnapshot
    {
        let workspaceID: String
        if let override = Self.normalizeWorkspaceID(workspaceOverride) {
            workspaceID = override
        } else {
            workspaceID = try await resolveWorkspaceID(cookieHeader: credential.cookieHeader)
        }

        let page = try await fetchUsagePage(
            workspaceID: workspaceID,
            cookieHeader: credential.cookieHeader)
        let usage = try Self.decodeUsagePage(page, now: Date())
        return Self.makeProviderSnapshot(usage, authMethod: credential.sourceLabel)
    }

    // MARK: - Request safety

    /// This delegate deliberately rejects a redirect to another host. A session
    /// header is credential material and must never follow an arbitrary redirect.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void)
        {
            guard let source = task.originalRequest?.url,
                  let destination = request.url,
                  source.host?.lowercased() == destination.host?.lowercased(),
                  destination.scheme?.lowercased() == "https"
            else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    private func resolveWorkspaceID(cookieHeader: String) async throws -> String {
        let getText = try await fetchServerText(
            serverID: Self.workspacesServerID,
            args: nil,
            method: "GET",
            referer: Self.baseURL,
            cookieHeader: cookieHeader)
        if Self.looksSignedOut(getText) { throw UsageError.openCodeCookieInvalid }
        if let id = Self.parseWorkspaceIDs(from: getText).first { return id }

        // CodexBar keeps this fallback because the server endpoint has returned
        // different shapes to different deployments over time.
        let postText = try await fetchServerText(
            serverID: Self.workspacesServerID,
            args: "[]",
            method: "POST",
            referer: Self.baseURL,
            cookieHeader: cookieHeader)
        if Self.looksSignedOut(postText) { throw UsageError.openCodeCookieInvalid }
        if let id = Self.parseWorkspaceIDs(from: postText).first { return id }
        throw UsageError.parseFailed("OpenCode Go workspace ID is missing. Set it manually in Settings.")
    }

    private func fetchServerText(
        serverID: String,
        args: String?,
        method: String,
        referer: URL,
        cookieHeader: String) async throws -> String
    {
        var components = URLComponents(url: Self.serverURL, resolvingAgainstBaseURL: false)
        if method == "GET" {
            var items = [URLQueryItem(name: "id", value: serverID)]
            if let args, !args.isEmpty { items.append(URLQueryItem(name: "args", value: args)) }
            components?.queryItems = items
        }
        guard let url = components?.url else {
            throw UsageError.parseFailed("Invalid OpenCode Go server URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(serverID, forHTTPHeaderField: "X-Server-Id")
        request.setValue("server-fn:\(UUID().uuidString)", forHTTPHeaderField: "X-Server-Instance")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        if method != "GET", let args {
            request.httpBody = Data(args.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await responseText(for: request)
    }

    private func fetchUsagePage(workspaceID: String, cookieHeader: String) async throws -> String {
        guard var components = URLComponents(
            string: "https://opencode.ai/workspace/\(workspaceID)/go")
        else {
            throw UsageError.parseFailed("Invalid OpenCode Go workspace URL.")
        }
        components.queryItems = [
            URLQueryItem(name: "arkbar_refresh", value: String(Int(Date().timeIntervalSince1970))),
        ]
        guard let url = components.url else {
            throw UsageError.parseFailed("Invalid OpenCode Go workspace URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let text = try await responseText(for: request)
        if Self.looksSignedOut(text) { throw UsageError.openCodeCookieInvalid }
        return text
    }

    private func responseText(for request: URLRequest) async throws -> String {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UsageError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.networkError("OpenCode Go returned a non-HTTP response.")
        }
        guard http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 401 || http.statusCode == 403 || Self.looksSignedOut(text) {
                throw UsageError.openCodeCookieInvalid
            }
            throw UsageError.apiError(statusCode: http.statusCode, message: Self.serverMessage(from: text) ?? "OpenCode Go")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw UsageError.parseFailed("OpenCode Go response was not UTF-8.")
        }
        return text
    }

    // MARK: - Decoding

    struct ParsedUsage: Sendable, Equatable {
        let rolling: ParsedWindow
        let weekly: ParsedWindow?
        let monthly: ParsedWindow?
        let expiryDate: Date?
        let updatedAt: Date
    }

    struct ParsedWindow: Sendable, Equatable {
        let usedPercent: Double
        let resetsAt: Date?
    }

    static func decodeUsagePage(_ text: String, now: Date) throws -> ParsedUsage {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let parsed = parseJSON(object, now: now, depth: 0, inheritedExpiry: nil)
        {
            return parsed
        }
        if let parsed = parseRegex(text, now: now) { return parsed }
        throw UsageError.parseFailed("OpenCode Go response is missing subscription usage fields.")
    }

    private static func parseJSON(
        _ object: Any,
        now: Date,
        depth: Int,
        inheritedExpiry: Date?) -> ParsedUsage?
    {
        guard depth <= 4 else { return nil }
        if let array = object as? [Any] {
            for value in array {
                if let result = parseJSON(value, now: now, depth: depth + 1, inheritedExpiry: inheritedExpiry) {
                    return result
                }
            }
            return nil
        }
        guard let dictionary = object as? [String: Any] else { return nil }

        let expiry = dateValue(from: value(in: dictionary, keys: renewAtKeys)) ?? inheritedExpiry
        if let usage = dictionary["usage"] as? [String: Any],
           let result = parseJSON(usage, now: now, depth: depth + 1, inheritedExpiry: expiry)
        {
            return result
        }
        let rolling = firstDictionary(in: dictionary, keys: rollingKeys)
        let weekly = firstDictionary(in: dictionary, keys: weeklyKeys)
        let monthly = firstDictionary(in: dictionary, keys: monthlyKeys)
        if let rolling, let parsedRolling = parseWindow(rolling, now: now) {
            return ParsedUsage(
                rolling: parsedRolling,
                weekly: weekly.flatMap { parseWindow($0, now: now) },
                monthly: monthly.flatMap { parseWindow($0, now: now) },
                expiryDate: expiry,
                updatedAt: now)
        }

        // Some server payloads wrap the usage object in data/result/payload;
        // some use opaque keys. Search both without trusting one response shape.
        for key in ["data", "result", "billing", "payload", "subscription"] {
            if let nested = dictionary[key],
               let result = parseJSON(nested, now: now, depth: depth + 1, inheritedExpiry: expiry)
            {
                return result
            }
        }
        for value in dictionary.values {
            if let result = parseJSON(value, now: now, depth: depth + 1, inheritedExpiry: expiry) {
                return result
            }
        }
        return nil
    }

    private static func parseRegex(_ text: String, now: Date) -> ParsedUsage? {
        guard let rollingPercent = extractDouble(
            pattern: #"rolling(?:Usage|_usage|Window|_window)?[^}]{0,1800}?(?:usagePercent|usedPercent|percentUsed|utilization|percent)\s*[\":=]+\s*([0-9]+(?:\.[0-9]+)?)"#,
            text: text)
        else { return nil }
        let rollingReset = extractInt(
            pattern: #"rolling(?:Usage|_usage|Window|_window)?[^}]{0,1800}?(?:resetInSec|resetInSeconds|resetSeconds|reset_at|resetAt)\s*[\":=]+\s*([0-9]+)"#,
            text: text)
        let weeklyPercent = extractDouble(
            pattern: #"weekly(?:Usage|_usage|Window|_window)?[^}]{0,1800}?(?:usagePercent|usedPercent|percentUsed|utilization|percent)\s*[\":=]+\s*([0-9]+(?:\.[0-9]+)?)"#,
            text: text)
        let monthlyPercent = extractDouble(
            pattern: #"monthly(?:Usage|_usage|Window|_window)?[^}]{0,1800}?(?:usagePercent|usedPercent|percentUsed|utilization|percent)\s*[\":=]+\s*([0-9]+(?:\.[0-9]+)?)"#,
            text: text)
        let weeklyReset = extractInt(
            pattern: #"weekly(?:Usage|_usage|Window|_window)?[^}]{0,1800}?(?:resetInSec|resetInSeconds|resetSeconds|reset_at|resetAt)\s*[\":=]+\s*([0-9]+)"#,
            text: text)
        let monthlyReset = extractInt(
            pattern: #"monthly(?:Usage|_usage|Window|_window)?[^}]{0,1800}?(?:resetInSec|resetInSeconds|resetSeconds|reset_at|resetAt)\s*[\":=]+\s*([0-9]+)"#,
            text: text)
        func window(percent: Double, reset: Int?) -> ParsedWindow {
            let used = normalisedPercent(percent, isDirect: true)
            return ParsedWindow(usedPercent: used, resetsAt: reset.map { now.addingTimeInterval(TimeInterval($0)) })
        }
        return ParsedUsage(
            rolling: window(percent: rollingPercent, reset: rollingReset),
            weekly: weeklyPercent.map { window(percent: $0, reset: weeklyReset) },
            monthly: monthlyPercent.map { window(percent: $0, reset: monthlyReset) },
            expiryDate: nil,
            updatedAt: now)
    }

    private static let rollingKeys = ["rollingUsage", "rolling", "rolling_usage", "rollingWindow", "rolling_window"]
    private static let weeklyKeys = ["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow", "weekly_window"]
    private static let monthlyKeys = ["monthlyUsage", "monthly", "monthly_usage", "monthlyWindow", "monthly_window"]
    private static let percentKeys = [
        "usagePercent", "usedPercent", "percentUsed", "percent", "usage_percent",
        "used_percent", "utilization", "utilizationPercent", "utilization_percent", "usage",
    ]
    private static let resetInKeys = [
        "resetInSec", "resetInSeconds", "resetSeconds", "reset_sec", "reset_in_sec",
        "resetsInSec", "resetsInSeconds", "resetIn", "resetSec",
    ]
    private static let resetAtKeys = ["resetAt", "resetsAt", "reset_at", "resets_at", "nextReset", "next_reset"]
    private static let renewAtKeys = ["renewAt", "renew_at"]

    private static func parseWindow(_ dictionary: [String: Any], now: Date) -> ParsedWindow? {
        var directPercent: Double?
        for key in percentKeys {
            if let value = doubleValue(from: dictionary[key]) {
                directPercent = value
                break
            }
        }
        let usedPercent: Double
        if let directPercent {
            usedPercent = normalisedPercent(directPercent, isDirect: true)
        } else {
            let used = ["used", "consumed", "count", "usedTokens"].lazy.compactMap { doubleValue(from: dictionary[$0]) }.first
            let total = ["limit", "total", "quota", "max", "cap", "tokenLimit"].lazy.compactMap { doubleValue(from: dictionary[$0]) }.first
            guard let used, let total, total > 0 else { return nil }
            usedPercent = normalisedPercent(used / total * 100, isDirect: false)
        }
        let resetSeconds = resetInKeys.lazy.compactMap { intValue(from: dictionary[$0]) }.first
        let resetDate = resetAtKeys.lazy.compactMap { dateValue(from: dictionary[$0]) }.first
        return ParsedWindow(
            usedPercent: usedPercent,
            resetsAt: resetDate ?? resetSeconds.map { now.addingTimeInterval(TimeInterval(max(0, $0))) })
    }

    private static func normalisedPercent(_ value: Double, isDirect: Bool) -> Double {
        var result = value
        if isDirect, result >= 0, result <= 1 { result *= 100 }
        return min(100, max(0, result))
    }

    // MARK: - Mapping and parsing helpers

    static func makeProviderSnapshot(
        _ usage: ParsedUsage,
        authMethod: String) -> ProviderSnapshot
    {
        var windows = [
            UsageWindow(label: "Session", usedPercent: usage.rolling.usedPercent, used: nil, total: nil, resetsAt: usage.rolling.resetsAt),
        ]
        if let weekly = usage.weekly {
            windows.append(UsageWindow(label: "Weekly", usedPercent: weekly.usedPercent, used: nil, total: nil, resetsAt: weekly.resetsAt))
        }
        if let monthly = usage.monthly {
            windows.append(UsageWindow(label: "Monthly", usedPercent: monthly.usedPercent, used: nil, total: nil, resetsAt: monthly.resetsAt))
        }
        let plan = PlanSnapshot(
            id: "opencode-go",
            product: .openCodeGo,
            edition: "Go",
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: windows,
            expiryDate: usage.expiryDate,
            errorMessage: nil)
        return ProviderSnapshot(
            providerName: L(.openCodeGo),
            authMethod: authMethod,
            plans: [plan],
            updatedAt: usage.updatedAt,
            errorMessage: nil)
    }

    static func normalizeWorkspaceID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("wrk_"), trimmed.count > 4 { return trimmed }
        if let url = URL(string: trimmed) {
            let parts = url.pathComponents
            if let index = parts.firstIndex(of: "workspace"), parts.count > index + 1 {
                let value = parts[index + 1]
                if value.hasPrefix("wrk_"), value.count > 4 { return value }
            }
        }
        if let range = trimmed.range(of: #"wrk_[A-Za-z0-9]+"#, options: .regularExpression) {
            return String(trimmed[range])
        }
        return nil
    }

    private static func parseWorkspaceIDs(from text: String) -> [String] {
        let direct = regexMatches(pattern: #"id\s*:\s*\"(wrk_[^\"]+)\""#, text: text)
        if !direct.isEmpty { return unique(direct) }
        if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
            var values: [String] = []
            collectWorkspaceIDs(in: object, into: &values)
            if !values.isEmpty { return values }
        }
        return unique(regexMatches(pattern: #"(wrk_[A-Za-z0-9]+)"#, text: text))
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func collectWorkspaceIDs(in value: Any, into results: inout [String]) {
        if let dictionary = value as? [String: Any] {
            for value in dictionary.values { collectWorkspaceIDs(in: value, into: &results) }
        } else if let array = value as? [Any] {
            for value in array { collectWorkspaceIDs(in: value, into: &results) }
        } else if let string = value as? String, string.hasPrefix("wrk_"), !results.contains(string) {
            results.append(string)
        }
    }

    private static func looksSignedOut(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("auth/authorize") ||
            lower.contains("not associated with an account") ||
            lower.contains("actor of type \"public\"") ||
            lower.contains("sign in") ||
            lower.contains("login")
    }

    private static func serverMessage(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in ["message", "error", "detail"] {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func firstDictionary(in dictionary: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = dictionary[key] as? [String: Any] { return value }
        }
        return nil
    }

    private static func value(in dictionary: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dictionary[key] { return value }
        }
        return nil
    }

    private static func doubleValue(from value: Any?) -> Double? {
        let result: Double? = switch value {
        case let number as Double: number
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default: nil
        }
        guard let result, result.isFinite else { return nil }
        return result
    }

    private static func intValue(from value: Any?) -> Int? {
        switch value {
        case let number as Int: number
        case let number as NSNumber: number.intValue
        case let string as String: Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default: nil
        }
    }

    private static func dateValue(from value: Any?) -> Date? {
        guard let value else { return nil }
        if let timestamp = doubleValue(from: value) {
            if timestamp > 1_000_000_000_000 { return Date(timeIntervalSince1970: timestamp / 1000) }
            if timestamp > 1_000_000_000 { return Date(timeIntervalSince1970: timestamp) }
        }
        guard let string = value as? String else { return nil }
        let normal = ISO8601DateFormatter()
        if let date = normal.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }

    private static func extractDouble(pattern: String, text: String) -> Double? {
        guard let match = regexMatches(pattern: pattern, text: text).first else { return nil }
        return Double(match)
    }

    private static func extractInt(pattern: String, text: String) -> Int? {
        extractDouble(pattern: pattern, text: text).map(Int.init)
    }

    private static func regexMatches(pattern: String, text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }
}

/// Normalises a pasted `Cookie:` header and retains only the credentials that
/// OpenCode Go itself needs. Tracking / preference cookies never leave the app.
enum OpenCodeGoCookieSupport {
    private static let allowedNames: Set<String> = ["auth", "__Host-auth"]

    static func requestCookieHeader(from raw: String?) -> String? {
        guard var raw else { return nil }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("cookie:") {
            raw = String(raw.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if raw.count >= 2,
           (raw.hasPrefix("\"") && raw.hasSuffix("\"")) || (raw.hasPrefix("'") && raw.hasSuffix("'"))
        {
            raw = String(raw.dropFirst().dropLast())
        }
        let pairs = raw.split(separator: ";").compactMap { part -> (String, String)? in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equal = trimmed.firstIndex(of: "=") else { return nil }
            let name = trimmed[..<equal].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed[trimmed.index(after: equal)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty, allowedNames.contains(String(name)) else { return nil }
            return (String(name), String(value))
        }
        guard !pairs.isEmpty else { return nil }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }
}
