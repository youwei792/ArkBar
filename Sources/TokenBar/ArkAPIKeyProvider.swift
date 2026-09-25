import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider that reads the `x-ratelimit-*` response headers of the Ark coding
/// gateway with an API key. Mirrors CodexBar's DoubaoAPIFetchStrategy probe branch.
///
/// The zero-cost `GET /models` probe runs first: the gateway attaches the same
/// rate-limit headers to it without billing any chat tokens. Only when that
/// route carries no quota contract does this fall back to a minimal billed
/// chat probe (a single request per refresh, no model fan-out).
///
/// This path only yields a single request-limit window (no weekly/monthly), so it is a
/// last-resort fallback when neither arkcli SSO nor AK/SK are available.
final class ArkAPIKeyProvider: UsageProvider {
    let displayName = "Ark (API Key)"
    private let apiKey: String
    private let transport: HTTPTransport

    init(apiKey: String, transport: HTTPTransport = HTTPClientTransport()) {
        self.apiKey = apiKey
        self.transport = transport
    }

    func isAvailable(environment: [String: String]) -> Bool { true }

    func fetch(environment: [String: String]) async throws -> ProviderSnapshot {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UsageError.missingCredentials }

        // Zero-cost probe first; nil means the route carried no quota headers
        // and the billed chat probe is the only way to read the window.
        if let snapshot = try await probeModels() {
            return snapshot
        }

        // Billed fallback. Different keys may not have access to every model,
        // so the probe models are tried in order.
        let probeModels = [
            environment["ARK_MODEL_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            "doubao-seed-2.0-code",
            "doubao-1.5-pro-32k",
            "doubao-lite-32k",
        ].compactMap { $0 }.filter { !$0.isEmpty }
        var lastError: Error?
        for model in probeModels {
            do {
                return try await self.probe(model: model)
            } catch let error as UsageError {
                if case let .apiError(code, _) = error, code == 404 || code == 403 {
                    lastError = error
                    continue
                }
                throw error
            }
        }
        throw lastError ?? UsageError.apiError(statusCode: 0, message: L(.errorProbeModels))
    }

    /// Zero-cost probe: `GET /models` carries the same gateway rate-limit
    /// headers as a chat call but never bills tokens. Returns nil when the
    /// route is missing, not permitted, or carries no quota headers, so the
    /// caller falls back to the billed chat probe.
    private func probeModels() async throws -> ProviderSnapshot? {
        var request = URLRequest(url: Self.modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 || response.statusCode == 429 else {
            if response.statusCode == 404 || response.statusCode == 403 { return nil }
            throw UsageError.apiError(
                statusCode: response.statusCode,
                message: HTTPErrorSummary.summarize(response.data))
        }
        guard let window = Self.rateLimitWindow(from: response.response.allHeaderFields) else {
            return nil
        }
        return Self.snapshot(window: window)
    }

    private func probe(model: String) async throws -> ProviderSnapshot {
        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response = try await transport.response(for: request)
        // Both 200 (success) and 429 (rate limited) carry rate-limit headers.
        guard response.statusCode == 200 || response.statusCode == 429 else {
            throw UsageError.apiError(
                statusCode: response.statusCode,
                message: HTTPErrorSummary.summarize(response.data))
        }

        // If the key is valid but no limit headers, surface as "active, no window".
        guard let window = Self.rateLimitWindow(from: response.response.allHeaderFields) else {
            return Self.noWindowSnapshot()
        }
        return Self.snapshot(window: window)
    }

    private static let apiURL = URL(string: "https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions")!
    private static let modelsURL = URL(string: "https://ark.cn-beijing.volces.com/api/coding/v3/models")!

    private static func rateLimitWindow(from headers: [AnyHashable: Any]) -> UsageWindow? {
        let limit = intHeader(headers, "x-ratelimit-limit-requests")
        let remaining = intHeader(headers, "x-ratelimit-remaining-requests")
        guard let limit, limit > 0, let remaining else { return nil }
        let resetTime = stringHeader(headers, "x-ratelimit-reset-requests").flatMap(parseResetTime)
        // Some gateways report a remaining value that briefly exceeds the limit
        // while a quota update propagates. Clamp both ends before rendering.
        let safeRemaining = min(limit, max(0, remaining))
        let used = limit - safeRemaining
        let usedPercent = min(100, Double(used) / Double(limit) * 100)
        return UsageWindow(
            label: "Requests",
            usedPercent: usedPercent,
            used: used,
            total: limit,
            resetsAt: resetTime)
    }

    private static func snapshot(window: UsageWindow) -> ProviderSnapshot {
        let plan = PlanSnapshot(
            id: "apikey-probe",
            product: .codingPlan,
            edition: "personal",
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: [window],
            expiryDate: nil,
            errorMessage: nil)
        return ProviderSnapshot(
            providerName: "Ark (API Key)",
            authMethod: "apikey",
            plans: [plan],
            updatedAt: Date(),
            errorMessage: nil)
    }

    private static func noWindowSnapshot() -> ProviderSnapshot {
        ProviderSnapshot(
            providerName: "Ark (API Key)",
            authMethod: "apikey",
            plans: [PlanSnapshot(
                id: "apikey-probe",
                product: .codingPlan,
                edition: "personal",
                tier: nil,
                seatID: nil,
                subscribed: true,
                windows: [],
                expiryDate: nil,
                errorMessage: L(.apiKeyNoHeaders))],
            updatedAt: Date(),
            errorMessage: L(.apiKeyNoWindow))
    }

    private static func stringHeader(_ headers: [AnyHashable: Any], _ name: String) -> String? {
        if let v = headers[name] as? String { return v }
        for (k, v) in headers {
            if let ks = k as? String, ks.caseInsensitiveCompare(name) == .orderedSame, let vs = v as? String {
                return vs
            }
        }
        return nil
    }

    private static func intHeader(_ headers: [AnyHashable: Any], _ name: String) -> Int? {
        if let v = headers[name] as? String, let i = Int(v) { return i }
        if let v = headers[name.lowercased()] as? String, let i = Int(v) { return i }
        for (k, v) in headers {
            if let ks = k as? String, ks.lowercased() == name.lowercased(),
               let vs = v as? String, let i = Int(vs)
            { return i }
        }
        return nil
    }

    private static func parseResetTime(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: trimmed) { return d }
        // Duration like "12h30m" / "1500s"
        var seconds: TimeInterval = 0
        let pattern = /(\d+)([dhms])/
        for match in trimmed.matches(of: pattern) {
            guard let n = Double(match.1) else { continue }
            switch match.2 {
            case "d": seconds += n * 86400
            case "h": seconds += n * 3600
            case "m": seconds += n * 60
            case "s": seconds += n
            default: break
            }
        }
        if seconds > 0 { return Date().addingTimeInterval(seconds) }
        if let secs = TimeInterval(trimmed) { return Date().addingTimeInterval(secs) }
        return nil
    }
}

/// Resolves an Ark API key from environment (same names arkcli/CodexBar accept).
enum ArkAPIKeyResolver {
    static let keys = ["ARK_API_KEY", "VOLCENGINE_API_KEY", "DOUBAO_API_KEY"]

    static func resolve(environment: [String: String]) -> String? {
        for key in keys {
            if let v = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return v
            }
        }
        return nil
    }
}
