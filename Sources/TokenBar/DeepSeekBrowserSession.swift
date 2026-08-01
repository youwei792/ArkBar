import Foundation
import SweetCookieKit

/// Extracts the DeepSeek platform session from Chrome's local storage — the
/// same mechanism CodexBar uses. `platform.deepseek.com` keeps its `userToken`
/// in localStorage (plaintext LevelDB), so this needs no Keychain password and
/// can run silently as part of a routine refresh.
enum DeepSeekBrowserSession {
    struct Session: Sendable, Equatable {
        let token: String
        let sourceLabel: String
    }

    struct TokenInfo: Sendable, Equatable {
        let id: String
        let token: String
        let sourceLabel: String
    }

    private static let origin = "https://platform.deepseek.com"
    private static let sourceLabelKey = "tokenbar.deepseekBrowserSourceLabel"
    private static let validationCache = DeepSeekBrowserValidationCache()

    /// Browser-session label shown in settings ("Google Chrome — 个人资料 1").
    static func cachedSourceLabel() -> String? {
        UserDefaults.standard.string(forKey: sourceLabelKey)
    }

    /// Silently scans Chrome profiles and returns the first session whose token
    /// validates against the usage API. Validation results are cached so routine
    /// refreshes do not rescan LevelDB on every tick.
    static func resolveAutomaticSession(
        transport: any HTTPTransport,
        logger: ((String) -> Void)? = nil) async -> Session?
    {
        let candidates = importTokens(logger: logger)
        guard !candidates.isEmpty else { return nil }
        let valid = await validatedCandidates(candidates, transport: transport, logger: logger)
        guard let winner = valid.first else { return nil }
        let session = Session(token: winner.token, sourceLabel: winner.sourceLabel)
        UserDefaults.standard.set(session.sourceLabel, forKey: sourceLabelKey)
        return session
    }

    /// Read-only variant for tests; skips the source-label persistence.
    static func resolve(candidates: [TokenInfo], transport: any HTTPTransport) async -> Session? {
        let valid = await validatedCandidates(candidates, transport: transport, logger: nil)
        guard let winner = valid.first else { return nil }
        return Session(token: winner.token, sourceLabel: winner.sourceLabel)
    }

    /// Scans every Chrome profile's `Local Storage/leveldb` for the DeepSeek
    /// platform `userToken`. Mirrors CodexBar's BrowserLocalStorageAPI walk.
    static func importTokens(logger: ((String) -> Void)? = nil) -> [TokenInfo] {
        let roots = ChromiumProfileLocator.roots(
            for: [.chrome],
            homeDirectories: BrowserCookieClient.defaultHomeDirectories())
        var results: [TokenInfo] = []
        for root in roots {
            guard let directories = try? FileManager.default.contentsOfDirectory(
                at: root.url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for directory in directories {
                guard !Task.isCancelled,
                      let isDirectory = try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                      isDirectory
                else { continue }
                let name = directory.lastPathComponent
                guard name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-") else { continue }
                let levelDB = directory.appendingPathComponent("Local Storage").appendingPathComponent("leveldb")
                guard FileManager.default.fileExists(atPath: levelDB.path) else { continue }
                let entries = ChromiumLocalStorageReader.readEntries(
                    for: origin,
                    in: levelDB,
                    logger: logger)
                guard let entry = entries.first(where: { $0.key == "userToken" }),
                      let token = extractUserToken(from: entry.value)
                else { continue }
                results.append(TokenInfo(
                    id: "\(root.browser.rawValue):\(name)",
                    token: token,
                    sourceLabel: "\(root.browser.displayName) — \(name)"))
            }
        }
        return results.sorted { $0.sourceLabel.localizedStandardCompare($1.sourceLabel) == .orderedAscending }
    }

    private static func validatedCandidates(
        _ candidates: [TokenInfo],
        transport: any HTTPTransport,
        logger: ((String) -> Void)?) async -> [TokenInfo]
    {
        let now = Date()
        var valid: [TokenInfo] = []
        for candidate in candidates {
            guard !Task.isCancelled else { break }
            let isValid: Bool
            if let cached = await validationCache.lookup(id: candidate.id, token: candidate.token, now: now) {
                isValid = cached
            } else {
                isValid = await isValidToken(candidate.token, transport: transport)
                await validationCache.record(id: candidate.id, token: candidate.token, isValid: isValid, now: now)
                logger?("[deepseek-browser] \(candidate.id) token \(isValid ? "valid" : "invalid")")
            }
            if isValid {
                valid.append(candidate)
            }
        }
        return valid
    }

    /// A usable session answers the usage/amount endpoint with HTTP 200.
    static func isValidToken(_ token: String, transport: any HTTPTransport) async -> Bool {
        let period: (month: Int, year: Int)
        do {
            period = try DeepSeekProvider.currentUsagePeriod()
        } catch {
            return false
        }
        guard var components = URLComponents(
            string: "https://platform.deepseek.com/api/v0/usage/amount")
        else { return false }
        components.queryItems = [
            URLQueryItem(name: "month", value: String(period.month)),
            URLQueryItem(name: "year", value: String(period.year)),
        ]
        guard let url = components.url else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = DeepSeekProvider.timeoutSeconds
        do {
            let response = try await transport.response(for: request)
            return response.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Token extraction (mirrors CodexBar)

    static func extractUserToken(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data)
        {
            return token(fromJSONObject: object)
        }

        let unquoted: String = if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
            (trimmed.hasPrefix("'") && trimmed.hasSuffix("'"))
        {
            String(trimmed.dropFirst().dropLast())
        } else {
            trimmed
        }
        return isPlausibleToken(unquoted) ? unquoted : nil
    }

    private static func token(fromJSONObject value: Any) -> String? {
        if let string = value as? String {
            return isPlausibleToken(string) ? string : nil
        }
        guard let dictionary = value as? [String: Any] else { return nil }
        for key in ["value", "token", "access_token", "accessToken", "userToken"] {
            guard let token = dictionary[key] as? String, isPlausibleToken(token) else { continue }
            return token
        }
        return nil
    }

    private static func isPlausibleToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 20 && !trimmed.contains(where: \.isWhitespace)
    }
}

/// Short-lived in-memory cache of browser-token validation outcomes, so routine
/// refreshes skip the LevelDB scan and network probe for 30 minutes.
actor DeepSeekBrowserValidationCache {
    private struct Entry: Sendable {
        let token: String
        let isValid: Bool
        let checkedAt: Date
    }

    private let validityTTL: TimeInterval
    private var entries: [String: Entry] = [:]

    init(validityTTL: TimeInterval = 30 * 60) {
        self.validityTTL = validityTTL
    }

    func lookup(id: String, token: String, now: Date) -> Bool? {
        guard let entry = entries[id], entry.token == token else { return nil }
        guard now.timeIntervalSince(entry.checkedAt) < validityTTL else { return nil }
        return entry.isValid
    }

    func record(id: String, token: String, isValid: Bool, now: Date) {
        entries[id] = Entry(token: token, isValid: isValid, checkedAt: now)
    }
}
