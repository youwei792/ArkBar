import Foundation

// MARK: - Console

/// Bailian console destinations for the Coding Plan product.
enum AliyunConsole {
    /// Console root — the subscription section lists both Token Plan and
    /// Coding Plan, so no product-specific page is assumed.
    static let dashboardURL = URL(
        string: "https://bailian.console.aliyun.com/")!
}

// MARK: - Parsed model

/// One quota window of the Coding Plan. The Pro plan exposes three: a rolling
/// 5-hour window (6,000 requests), a weekly window (45,000, Monday reset) and
/// a monthly window (90,000, reset on the subscription day).
struct AliyunWindowEntry: Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable {
        case fiveHour = "five_hour"
        case weekly
        case monthly

        /// Canonical UsageWindow label so the rings, legend and sortRank line
        /// up with every other provider.
        var windowLabel: String {
            switch self {
            case .fiveHour: "5-hour"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            }
        }
    }

    let kind: Kind
    let usedPercent: Double
    let used: Int?
    let total: Int?
    let resetsAt: Date?
}

/// Parsed Alibaba Cloud plan usage, before mapping to ArkBar models.
struct AliyunUsageSnapshot: Sendable, Equatable {
    let planName: String?
    /// Verified subscription expiry when the source exposes it.
    let expiryDate: Date?
    let windows: [AliyunWindowEntry]
}

/// The Token Plan subscription record. Token Plan's usage API publishes only
/// ratios and reset times, so the plan tier and the subscription end date come
/// from here — the same call the console page makes next to the usage one.
struct AliyunSubscription: Sendable, Equatable {
    let planName: String?
    let expiryDate: Date?
}

/// Which Alibaba Cloud subscription the account holds. Coding Plan meters
/// request counts (5-hour / weekly / monthly); Token Plan meters credit
/// ratios (5-hour / weekly). The two have different console APIs, so the
/// first successful fetch records which one this account uses and later
/// refreshes query only that API.
enum AliyunPlanKind: String, Sendable, CaseIterable {
    case token
    case coding

    /// Try the detected plan first; an undetected account tries Token Plan
    /// (the personal default) before Coding Plan.
    static func order(detected: AliyunPlanKind?) -> [AliyunPlanKind] {
        switch detected {
        case .coding: return [.coding, .token]
        case .token, .none: return [.token, .coding]
        }
    }
}

// MARK: - Provider

/// Alibaba Cloud (阿里云百炼) Coding Plan usage.
///
/// Alibaba publishes no public quota API: usage is only visible on the console
/// Coding Plan page, and the `sk-sp-…` plan key authenticates the model
/// gateway only. The console's own data path is the Model Studio console
/// gateway, which the official `bl` CLI drives with a short-lived access
/// token minted from an Aliyun AK/SK pair (`GenerateCLIAccessToken`,
/// ACS3-HMAC-SHA256 signed). TokenBar follows that exact contract — see
/// `AliyunSigner.swift` and docs/aliyun-handoff.md — so a read-only AK/SK pair
/// is all the configuration this needs.
final class AliyunProvider: UsageProvider {
    let displayName = "阿里云"

    private let settings: AppSettings
    private let transport: HTTPTransport
    private let tokenStore = AliyunConsoleTokenStore()

    init(settings: AppSettings, transport: HTTPTransport = defaultHTTPTransport()) {
        self.settings = settings
        self.transport = transport
    }

    /// Credentials are resolved inside `fetch` (settings/Keychain -> environment).
    func isAvailable(environment: [String: String]) -> Bool { true }

    func fetch(environment: [String: String]) async throws -> ProviderSnapshot {
        let (consoleToken, storedCredentials, storedAPIKey) = await MainActor.run {
            (
                self.settings.aliyunConsoleToken,
                self.settings.storedAliyunCredentials,
                Self.trimmed(self.settings.aliyunAPIKey)
            )
        }
        let credentials = storedCredentials ?? AliyunCredentialResolver.resolve(environment: environment)
        let apiKey = storedAPIKey ?? AliyunAPIKeyResolver.resolve(environment: environment)
        let hasConsoleToken = !consoleToken.isEmpty
        guard hasConsoleToken || credentials != nil || apiKey != nil else {
            throw UsageError.aliyunMissingCredentials
        }

        let (token, source) = try await tokenStore.accessToken(
            consoleToken: consoleToken,
            credentials: credentials,
            apiKey: apiKey,
            transport: transport)
        do {
            return try await fetchUsage(token: token)
        } catch {
            switch source {
            case .apiKey:
                // The plan key is scoped to the model gateway; the console
                // gateway rejects it whatever the exact status or envelope.
                // Remember the rejection and point at the paths that work.
                await tokenStore.markAPIKeyRejected()
                throw UsageError.aliyunInvalidToken
            case .browserLogin:
                // The console-login token cannot be refreshed without the
                // user. Drop it, then fall back to AK/SK when available.
                guard case UsageError.aliyunInvalidToken = error else { throw error }
                await MainActor.run { self.settings.setAliyunConsoleToken(nil) }
                if let credentials {
                    await tokenStore.invalidateMinted()
                    let (fresh, _) = try await tokenStore.accessToken(
                        consoleToken: nil, credentials: credentials, apiKey: nil,
                        transport: transport)
                    return try await fetchUsage(token: fresh)
                }
                throw UsageError.aliyunConsoleLoginExpired
            case .accessKey:
                // The console token is short-lived; mint a fresh one and
                // retry once before surfacing the credential error.
                guard case UsageError.aliyunInvalidToken = error else { throw error }
                await tokenStore.invalidateMinted()
                let (fresh, _) = try await tokenStore.accessToken(
                    consoleToken: nil, credentials: credentials, apiKey: nil,
                    transport: transport)
                return try await fetchUsage(token: fresh)
            }
        }
    }

    /// Queries the account's plan. An account holds either a Token Plan or a
    /// Coding Plan (never both); the detected kind is tried first so a normal
    /// refresh costs exactly one usage read.
    private func fetchUsage(token: String) async throws -> ProviderSnapshot {
        let detected = await MainActor.run { self.settings.aliyunDetectedPlan }
        var absent: [(kind: AliyunPlanKind, raw: Data)] = []
        for kind in AliyunPlanKind.order(detected: detected) {
            switch try await fetchPlan(kind: kind, token: token) {
            case let .plan(snapshot):
                if kind != detected {
                    await MainActor.run { self.settings.aliyunDetectedPlan = kind }
                }
                return snapshot
            case let .absent(raw):
                absent.append((kind, raw))
            }
        }
        Self.writeDiagnostic(Self.noPlanDiagnostic(absent))
        throw UsageError.aliyunNotActivated
    }

    /// Both APIs answered without an error envelope, so record exactly what each
    /// one returned — that is the difference between "this account has no such
    /// plan" and "the payload moved", and it cannot be told apart from the menu.
    private static func noPlanDiagnostic(
        _ absent: [(kind: AliyunPlanKind, raw: Data)]
    ) -> String {
        absent.map {
            "\($0.kind.rawValue) plan: "
                + HTTPErrorSummary.truncate(String(decoding: $0.raw, as: UTF8.self), 1200)
        }
        .joined(separator: "\n")
    }

    /// One plan's usage. `.absent` means the account has no such plan — that is
    /// not an error, the caller tries the other kind.
    private func fetchPlan(kind: AliyunPlanKind, token: String) async throws -> PlanOutcome {
        do {
            switch kind {
            case .token:
                let data = try await AliyunConsoleAPI.fetchTokenPlanUsage(
                    token: token, transport: transport)
                let usage = try Self.parseTokenPlan(data: data)
                guard !usage.windows.isEmpty else { return .absent(raw: data) }
                let subscription = await fetchSubscription(token: token)
                let merged = AliyunUsageSnapshot(
                    planName: subscription.planName ?? usage.planName,
                    expiryDate: subscription.expiryDate ?? usage.expiryDate,
                    windows: usage.windows)
                return .plan(Self.makeSnapshot(
                    from: merged,
                    product: .aliyunTokenPlan,
                    edition: merged.planName.map(Self.editionName)))
            case .coding:
                let data = try await AliyunConsoleAPI.fetchCodingPlanUsage(
                    token: token, transport: transport)
                do {
                    let usage = try Self.parse(data: data)
                    return .plan(Self.makeSnapshot(
                        from: usage,
                        product: .aliyunCodingPlan,
                        edition: usage.planName.map(Self.editionName)))
                } catch UsageError.aliyunNotActivated {
                    // No VALID Coding Plan instance: let the caller try the
                    // Token Plan API.
                    return .absent(raw: data)
                }
            }
        } catch {
            Self.writeDiagnostic(
                "\(kind.rawValue) plan query failed: \(HTTPErrorSummary.truncate(error.localizedDescription))")
            throw error
        }
    }

    private enum PlanOutcome {
        case plan(ProviderSnapshot)
        case absent(raw: Data)
    }

    /// Reads the Token Plan subscription record. Usage already answered the
    /// question the card exists for, so a failure here costs the expiry badge
    /// and the tier name rather than failing the whole refresh.
    private func fetchSubscription(token: String) async -> AliyunSubscription {
        do {
            let data = try await AliyunConsoleAPI.fetchTokenPlanSubscription(
                token: token, transport: transport)
            return try Self.parseTokenPlanSubscription(data: data)
        } catch {
            Self.writeDiagnostic(
                "token plan subscription query failed: "
                    + HTTPErrorSummary.truncate(error.localizedDescription))
            return AliyunSubscription(planName: nil, expiryDate: nil)
        }
    }

    // MARK: - Mapping (static for tests)

    static func makeSnapshot(
        from usage: AliyunUsageSnapshot,
        product: PlanSnapshot.Product,
        edition: String?
    ) -> ProviderSnapshot {
        let windows = usage.windows
            .sorted { $0.kind.windowRank < $1.kind.windowRank }
            .map {
                UsageWindow(
                    label: $0.kind.windowLabel,
                    usedPercent: min(100, max(0, $0.usedPercent)),
                    used: $0.used,
                    total: $0.total,
                    resetsAt: $0.resetsAt)
            }
        let plan = PlanSnapshot(
            id: "aliyun-\(product.rawValue)",
            product: product,
            edition: edition,
            tier: nil,
            seatID: nil,
            subscribed: true,
            windows: windows,
            expiryDate: usage.expiryDate,
            errorMessage: nil)
        return ProviderSnapshot(
            providerName: "阿里云",
            authMethod: "aksk",
            plans: [plan],
            updatedAt: Date(),
            errorMessage: nil)
    }

    /// The console reports a lowercase instance type ("pro"); show it the way
    /// the console page does.
    private static func editionName(_ raw: String) -> String {
        raw.isEmpty ? "Coding Plan" : raw.prefix(1).uppercased() + raw.dropFirst()
    }

    private static func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Decoding (static for tests)

    /// Parses the console gateway response.
    ///
    /// Coding Plan envelope (verified against the official CLI's fixtures):
    /// `data → DataV2 → data → data → codingPlanInstanceInfos[]`, where the
    /// first `status == "VALID"` instance's `codingPlanQuotaInfo` carries
    /// `per5Hour*` / `perWeek*` / `perBillMonth*` triplets of
    /// `UsedQuota` / `TotalQuota` / `QuotaNextRefreshTime` (epoch millis).
    static func parse(data: Data) throws -> AliyunUsageSnapshot {
        let payload = try Self.unwrapEnvelope(data)

        guard let instances = payload["codingPlanInstanceInfos"] as? [[String: Any]],
              let instance = instances.first(where: {
                  ($0["status"] as? String)?.uppercased() == "VALID"
              })
        else {
            // No active subscription: expired, refunded, or not activated.
            throw UsageError.aliyunNotActivated
        }

        let quota = instance["codingPlanQuotaInfo"] as? [String: Any] ?? [:]
        var windows: [AliyunWindowEntry] = []
        for (prefix, kind) in [
            ("per5Hour", AliyunWindowEntry.Kind.fiveHour),
            ("perWeek", AliyunWindowEntry.Kind.weekly),
            ("perBillMonth", AliyunWindowEntry.Kind.monthly),
        ] {
            if let window = Self.window(from: quota, prefix: prefix, kind: kind) {
                windows.append(window)
            }
        }
        guard !windows.isEmpty else {
            throw UsageError.parseFailed("Alibaba Cloud: no quota windows in the Coding Plan instance")
        }

        let instanceType = (instance["instanceType"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expiryDate = ["expiredTime", "expireTime", "endTime", "subscriptionExpireTime"]
            .compactMap { instance[$0] }
            .compactMap { Self.dateValue($0) }
            .first
        return AliyunUsageSnapshot(
            planName: instanceType?.isEmpty == false ? instanceType : nil,
            expiryDate: expiryDate,
            windows: windows)
    }

    /// Parses the Token Plan usage payload: `per5HourPercentage` /
    /// `per1WeekPercentage` / `per1MonthPercentage` are **used** ratios in
    /// [0, 1] (absent means the plan has no such window — an Essential-style
    /// personal plan reports the monthly one only), with epoch-millisecond reset
    /// times. No absolute counts are published, so the rings render as
    /// percent-only windows.
    static func parseTokenPlan(data: Data) throws -> AliyunUsageSnapshot {
        let payload = try Self.unwrapEnvelope(data)

        var windows: [AliyunWindowEntry] = []
        let ratios: [(key: String, resetKey: String, kind: AliyunWindowEntry.Kind)] = [
            ("per5HourPercentage", "per5HourResetTime", .fiveHour),
            ("per1WeekPercentage", "per1WeekResetTime", .weekly),
            ("per1MonthPercentage", "per1MonthResetTime", .monthly),
        ]
        for ratio in ratios {
            guard let value = Self.doubleValue(payload[ratio.key]), value.isFinite else {
                continue
            }
            windows.append(AliyunWindowEntry(
                kind: ratio.kind,
                usedPercent: min(100, max(0, value * 100)),
                used: nil,
                total: nil,
                resetsAt: Self.dateValue(payload[ratio.resetKey])))
        }
        return AliyunUsageSnapshot(planName: nil, expiryDate: nil, windows: windows)
    }

    /// Parses the Token Plan subscription record: `specCode` is the plan tier
    /// (`"essential"`), `endTime` the subscription expiry in epoch
    /// milliseconds. `remainingDays` is deliberately ignored — it is derived
    /// data the app recomputes from the date, and a stale copy of it would
    /// disagree with the countdown.
    static func parseTokenPlanSubscription(data: Data) throws -> AliyunSubscription {
        let payload = try Self.unwrapEnvelope(data)
        let specCode = (payload["specCode"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AliyunSubscription(
            planName: (specCode?.isEmpty == false) ? specCode : nil,
            expiryDate: Self.dateValue(payload["endTime"]))
    }

    /// Walks the console envelope (`data → DataV2 → data → data`, with a
    /// shallower fallback) — the same tolerant unwrap the official CLI does.
    static func unwrapEnvelope(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else {
            throw UsageError.parseFailed("Empty Alibaba Cloud response body")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UsageError.parseFailed("Alibaba Cloud: \(error.localizedDescription)")
        }
        guard var payload = object as? [String: Any] else {
            throw UsageError.parseFailed("Alibaba Cloud: expected a JSON object")
        }
        if let data = payload["data"] as? [String: Any] {
            if let dataV2 = data["DataV2"] as? [String: Any] {
                let inner = dataV2["data"] as? [String: Any]
                payload = (inner?["data"] as? [String: Any]) ?? inner ?? dataV2
            } else {
                payload = data["data"] as? [String: Any] ?? data
            }
        }
        return payload
    }

    /// One `per5Hour` / `perWeek` / `perBillMonth` triplet. A window without a
    /// positive total does not apply to the plan and is omitted, matching the
    /// console's own rendering.
    private static func window(
        from quota: [String: Any], prefix: String, kind: AliyunWindowEntry.Kind
    ) -> AliyunWindowEntry? {
        guard let total = Self.intValue(quota["\(prefix)TotalQuota"]), total > 0 else {
            return nil
        }
        let used = Self.intValue(quota["\(prefix)UsedQuota"]) ?? 0
        let usedPercent = min(100, max(0, Double(used) / Double(total) * 100))
        let resetsAt = Self.dateValue(quota["\(prefix)QuotaNextRefreshTime"])
        return AliyunWindowEntry(
            kind: kind,
            usedPercent: usedPercent,
            used: used,
            total: total,
            resetsAt: resetsAt)
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private static func dateValue(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            let interval = number.doubleValue
            // Heuristic: > 1e12 is milliseconds since 1970.
            return Date(timeIntervalSince1970: interval > 1_000_000_000_000 ? interval / 1000 : interval)
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let interval = Double(trimmed) {
                return Date(timeIntervalSince1970: interval > 1_000_000_000_000 ? interval / 1000 : interval)
            }
            if let date = ISO8601DateFormatter().date(from: trimmed) { return date }
            let fallback = DateFormatter()
            fallback.locale = Locale(identifier: "en_US_POSIX")
            fallback.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return fallback.date(from: trimmed)
        default:
            return nil
        }
    }

    /// Support diagnostic: the request shape and a bounded body summary land in
    /// the app-support directory (never credentials — the token is a header).
    static func writeDiagnostic(_ text: String) {
        guard let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TokenBar", isDirectory: true)
        else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(
            to: dir.appendingPathComponent("aliyun-last-response.txt"),
            atomically: true, encoding: .utf8)
    }
}

private extension AliyunWindowEntry.Kind {
    /// Canonical ordering: 5-hour < weekly < monthly.
    var windowRank: Int {
        switch self {
        case .fiveHour: 0
        case .weekly: 1
        case .monthly: 2
        }
    }
}
