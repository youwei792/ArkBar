import Foundation

// MARK: - Credentials

/// Reads a Kimi Code API key from the environment. Settings (Keychain) values
/// take precedence; this is the fallback.
enum KimiCredentialResolver {
    static let apiKeyKeys = ["KIMI_CODE_API_KEY"]

    static func apiKey(environment: [String: String]) -> String? {
        value(for: apiKeyKeys, environment: environment)
    }

    private static func value(for keys: [String], environment: [String: String]) -> String? {
        for key in keys {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                continue
            }
            var value = raw
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                (value.hasPrefix("'") && value.hasSuffix("'"))
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

// MARK: - API response types

private struct KimiCodeAPIUsageResponse: Decodable {
    let usage: KimiUsageDetail
    let limits: [KimiRateLimit]?
}

struct KimiUsageDetail: Decodable {
    let limit: String
    let used: String?
    let remaining: String?
    let resetTime: String?

    private enum CodingKeys: String, CodingKey {
        case limit
        case used
        case remaining
        case resetTime
        case resetAt
        case resetTimeSnake = "reset_time"
        case resetAtSnake = "reset_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The API sends limit/used/remaining as strings, but a numeric response
        // must not break decoding.
        guard let limit = Self.stringValue(in: container, forKey: .limit) else {
            throw DecodingError.keyNotFound(
                CodingKeys.limit,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Kimi usage limit is missing"))
        }
        self.limit = limit
        self.used = Self.stringValue(in: container, forKey: .used)
        self.remaining = Self.stringValue(in: container, forKey: .remaining)
        self.resetTime =
            Self.stringValue(in: container, forKey: .resetTime) ??
            Self.stringValue(in: container, forKey: .resetAt) ??
            Self.stringValue(in: container, forKey: .resetTimeSnake) ??
            Self.stringValue(in: container, forKey: .resetAtSnake)
    }

    private static func stringValue(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys) -> String?
    {
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            if value.rounded(.towardZero) == value,
               value >= Double(Int64.min),
               value <= Double(Int64.max)
            {
                return String(Int64(value))
            }
            return String(value)
        }
        return nil
    }
}

private struct KimiRateLimit: Decodable {
    let window: KimiWindow
    let detail: KimiUsageDetail
}

private struct KimiWindow: Decodable {
    let duration: Int
    let timeUnit: String
}

// MARK: - Parsed snapshot

/// Parsed Kimi Code usage, before mapping to ArkBar models. `weekly` is the
/// membership quota (CodexBar's `usage`), `rateLimit` the 5-hour rate-limit
/// window.
struct KimiUsageSnapshot {
    let weekly: KimiUsageDetail
    let rateLimit: KimiUsageDetail?
}

// MARK: - Provider

/// Kimi (Kimi For Coding) membership usage via the Code API `usages` endpoint.
///
/// Mirrors CodexBar's KimiUsageFetcher Code API path (the API-key route): one
/// GET to `https://api.kimi.com/coding/v1/usages` returning the weekly
/// membership quota plus a 5-hour rate-limit window. No browser cookie import,
/// no CLI credential reuse.
final class KimiProvider: UsageProvider {
    let displayName = "Kimi"

    private static let timeoutSeconds: TimeInterval = 15

    private static let baseURL = URL(string: "https://api.kimi.com")!
    private static let usagePath = "coding/v1/usages"

    private let settings: AppSettings
    private let transport: any HTTPTransport

    init(settings: AppSettings, transport: any HTTPTransport = defaultHTTPTransport()) {
        self.settings = settings
        self.transport = transport
    }

    /// Credentials are resolved inside `fetch` (settings/Keychain -> environment).
    func isAvailable(environment: [String: String]) -> Bool { true }

    func fetch(environment: [String: String]) async throws -> ProviderSnapshot {
        let apiKey = await MainActor.run { Self.trimmed(self.settings.kimiAPIKey) }
            ?? KimiCredentialResolver.apiKey(environment: environment)

        guard let apiKey, !apiKey.isEmpty else {
            throw UsageError.kimiMissingCredentials
        }

        let snapshot = try await fetchUsage(apiKey: apiKey)

        // Map Kimi usage into ArkBar's UsageWindow using the canonical labels so
        // the ring tones and legend line up. The weekly membership quota drives
        // the weekly ring; the 5-hour rate limit the session ring. Both use the
        // API's *used* share, which `UsageWindow.remainingPercent` inverts.
        var windows: [UsageWindow] = []
        if let rateLimit = snapshot.rateLimit {
            windows.append(Self.window(from: rateLimit, label: "5-hour", windowMinutes: 300))
        }
        windows.append(Self.window(from: snapshot.weekly, label: "Weekly", windowMinutes: nil))

        let plan = PlanSnapshot(
            id: "kimi-coding-plan",
            product: .codingPlan,
            edition: "Kimi For Coding",
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: windows,
            expiryDate: nil,
            errorMessage: nil)

        return ProviderSnapshot(
            providerName: displayName,
            authMethod: "apikey",
            plans: [plan],
            updatedAt: Date(),
            errorMessage: nil)
    }

    private func fetchUsage(apiKey: String) async throws -> KimiUsageSnapshot {
        let url = Self.baseURL.appendingPathComponent(Self.usagePath)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw UsageError.kimiInvalidToken
            }
            let body = String(data: response.data, encoding: .utf8) ?? ""
            throw UsageError.apiError(statusCode: response.statusCode, message: "Kimi Code API: \(body)")
        }
        guard !response.data.isEmpty else {
            throw UsageError.parseFailed(
                "Empty Kimi response. Check the API key and that the plan is active.")
        }
        return try Self.parse(data: response.data)
    }

    private static func window(from detail: KimiUsageDetail, label: String, windowMinutes: Int?) -> UsageWindow {
        let limit = Int(detail.limit) ?? 0
        let remaining = Int(detail.remaining ?? "")
        let used = Int(detail.used ?? "") ?? {
            guard let remaining else { return 0 }
            return max(0, limit - remaining)
        }()
        let usedPercent = limit > 0 ? Self.clampedPercent(Double(used) / Double(limit) * 100) : 0
        return UsageWindow(
            label: label,
            usedPercent: usedPercent,
            used: used,
            total: limit,
            resetsAt: Self.parseDate(detail.resetTime))
    }

    private static func parseDate(_ dateString: String?) -> Date? {
        guard let dateString else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: dateString)
    }

    private static func clampedPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Decoding (static for tests)

    static func parse(data: Data) throws -> KimiUsageSnapshot {
        guard !data.isEmpty else {
            throw UsageError.parseFailed("Empty Kimi response body")
        }
        let response: KimiCodeAPIUsageResponse
        do {
            response = try JSONDecoder().decode(KimiCodeAPIUsageResponse.self, from: data)
        } catch {
            throw UsageError.parseFailed("Kimi: \(error.localizedDescription)")
        }
        return KimiUsageSnapshot(
            weekly: response.usage,
            rateLimit: response.limits?.first?.detail)
    }
}
