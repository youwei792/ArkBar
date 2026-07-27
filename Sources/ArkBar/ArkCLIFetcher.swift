import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider that reads Coding/Agent Plan usage from `arkcli usage plan --format json`.
/// Mirrors CodexBar's DoubaoCLIFetchStrategy / decodeArkcliUsage.
final class ArkCLIProvider: UsageProvider {
    let displayName = "arkcli"
    private let runner: ArkCLIRunner

    init(runner: ArkCLIRunner = .live) {
        self.runner = runner
    }

    func isAvailable(environment: [String: String]) -> Bool {
        // Always available - missing CLI / not-logged-in surface as actionable errors.
        true
    }

    func fetch(environment: [String: String]) async throws -> ProviderSnapshot {
        // The runner blocks on a subprocess; run it off the cooperative thread pool.
        let runner = self.runner
        let stdout: Data = try await Task.detached(priority: .utility) {
            try runner.run(environment)
        }.value
        let snapshot = try Self.decode(stdout: stdout, date: Date())

        // `usage plan` reports quota reset windows, but not the order's actual
        // subscription end date. The profile `expires_at` field is only a local
        // credential/cache lifetime and can be shorter than a multi-month order.
        // Never show an estimated expiry: misleading subscription information is
        // worse than not showing a badge at all.
        return snapshot
    }

    // MARK: - Decoding

    static func decode(stdout: Data, date: Date) throws -> ProviderSnapshot {
        let response: ArkcliUsageResponse
        do {
            response = try JSONDecoder().decode(ArkcliUsageResponse.self, from: stdout)
        } catch {
            throw UsageError.parseFailed(error.localizedDescription)
        }

        let authMethod = response.viewer?.authMethod?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if authMethod?.lowercased() == "none" {
            throw UsageError.arkcliNotAuthenticated
        }

        let supportedProducts: Set<String> = Set([
            PlanSnapshot.Product.codingPlan.rawValue,
            PlanSnapshot.Product.agentPlan.rawValue,
            PlanSnapshot.Product.codingPlanTeam.rawValue,
            PlanSnapshot.Product.agentPlanTeam.rawValue,
        ])
        // A subscribed product with no periods is a soft per-bucket failure; surface it.
        if let incomplete = response.items.first(where: {
            supportedProducts.contains($0.product.lowercased())
                && $0.subscribed != false
                && ($0.periods?.isEmpty != false)
        }) {
            let raw = incomplete.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let msg = raw.isEmpty ? "\(incomplete.product) has no usage periods" : raw
            throw UsageError.noPlanUsage(msg)
        }

        var plans: [PlanSnapshot] = []
        var updatedAt = date
        for item in response.items {
            guard let product = PlanSnapshot.Product(rawValue: item.product.lowercased()) else { continue }
            guard item.subscribed != false else { continue }
            let periods = item.periods ?? []
            if periods.isEmpty { continue }

            if let ts = item.updatedAt, ts > 0 {
                // arkcli has shipped updated_at as both epoch seconds and ms; detect by magnitude.
                let seconds = ts >= 1e11 ? ts / 1000 : ts
                updatedAt = max(updatedAt, Date(timeIntervalSince1970: seconds))
            }

            let windows = periods.map { period -> UsageWindow in
                UsageWindow(
                    label: Self.canonicalLabel(period.label),
                    usedPercent: min(100, max(0, period.percent)),
                    used: period.used,
                    total: period.total,
                    resetsAt: period.resetAt?.date)
            }
            plans.append(PlanSnapshot(
                id: "\(product.rawValue):\(item.seatID ?? "")",
                product: product,
                edition: item.edition,
                tier: item.tier,
                seatID: item.seatID,
                subscribed: true,
                windows: windows.sorted { $0.sortRank < $1.sortRank },
                // A quota reset is not a subscription expiry date. arkcli does
                // not currently return a plan-expiration field here.
                expiryDate: nil,
                errorMessage: nil))
        }

        guard !plans.isEmpty else {
            let itemError = response.items.lazy
                .filter { supportedProducts.contains($0.product.lowercased()) }
                .compactMap(\.error)
                .first { !$0.isEmpty }
            throw UsageError.noPlanUsage(itemError)
        }

        return ProviderSnapshot(
            providerName: "arkcli",
            authMethod: authMethod,
            plans: plans,
            updatedAt: updatedAt,
            errorMessage: nil)
    }

    /// Normalise the many spellings arkcli/backends use ("5h", "5-hour", "session") into a stable display label.
    private static func canonicalLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "session": "Session"
        case "5h", "5-hour", "five_hour": "5-hour"
        case "weekly", "week": "Weekly"
        case "monthly", "month": "Monthly"
        case "daily", "day": "Daily"
        default: raw.capitalized
        }
    }
}

// MARK: - arkcli subprocess runner

struct ArkCLIRunner: Sendable {
    /// Closure that runs `arkcli usage plan --format json` and returns stdout bytes.
    /// Synchronous on purpose: it blocks on the subprocess. Callers offload it to a
    /// background context via `Task.detached` so the main actor isn't blocked.
    var run: @Sendable ([String: String]) throws -> Data

    static let live = ArkCLIRunner { environment in
        // Run arkcli through a shell (NOT a login shell). Two reasons:
        // 1. GUI apps inherit a minimal PATH (/usr/bin:/bin:...) that omits homebrew
        //    where arkcli + node live. We pad PATH ourselves below so a non-login
        //    shell can still resolve them.
        // 2. Ad-hoc-signed .app bundles hit "Permission denied" exec'ing the arkcli
        //    symlink directly; routing through /bin/zsh (system-signed) avoids it.
        //
        // Important: we use -c (not -l -c) because a login shell re-sources profiles
        // that, on this machine, make arkcli misdetect the platform as amd64 and fail
        // to find its arm64 binary. Non-login + padded PATH is the working combo.
        guard let shell = ArkCLIProvider.loginShell(),
              let arkcliPath = ArkCLIProvider.resolveArkcliPath(environment: environment)
        else {
            throw UsageError.arkcliNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -c = run command string. No -l: avoids platform misdetection from profiles.
        // Use the resolved binary rather than relying on PATH again; this makes
        // ARKCLI_PATH work for packaged GUI apps and custom installations.
        process.arguments = ["-c", "\(Self.shellQuote(arkcliPath)) usage plan --format json"]
        // Pad PATH with the common toolchain locations so the non-login shell finds
        // both arkcli and the node interpreter arkcli's shebang needs.
        let extraPATH = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.volta/bin",
        ].joined(separator: ":")
        var env = environment
        let inheritedPATH = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(extraPATH):\(inheritedPATH)"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Read stdout/stderr concurrently on background queues so neither pipe
        // deadlocks while the other fills its kernel buffer. We launch the readers
        // BEFORE waitUntilExit() so they drain continuously as the process writes.
        let stdoutReader = PipeReader(pipe: stdoutPipe, limit: 256 * 1024)
        let stderrReader = PipeReader(pipe: stderrPipe, limit: 64 * 1024)

        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSemaphore.signal() }
        do {
            try process.run()
        } catch {
            throw UsageError.networkError("Failed to launch arkcli: \(error.localizedDescription)")
        }

        // Wait for exit with a 15s cap. DispatchSemaphore.wait(timeout:) is sync and
        // safe to call from this (technically async) closure - it just blocks the thread.
        let timeout: DispatchTime = .now() + 15
        let timedOut = exitSemaphore.wait(timeout: timeout) == .timedOut
        if timedOut, process.isRunning {
            process.terminate()
            exitSemaphore.wait()
            throw UsageError.arkcliTimedOut
        }

        let stdoutData = stdoutReader.finish()
        let stderrData = stderrReader.finish()

        if process.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            let message = Self.compact(stderr)
            if Self.isAuthError(message) {
                throw UsageError.arkcliNotAuthenticated
            }
            throw UsageError.arkcliFailed(
                exitCode: process.terminationStatus,
                message: message.isEmpty ? "unknown error" : message)
        }
        return stdoutData
    }

    private static func isAuthError(_ message: String) -> Bool {
        let n = message.lowercased()
        return [
            "not logged in",
            "not authenticated",
            "authentication required",
            "login required",
            "please login",
            "please log in",
            "volc-sso",
        ].contains { n.contains($0) }
    }

    private static func compact(_ text: String, maxLength: Int = 200) -> String {
        let collapsed = text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= maxLength { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        return "\(collapsed[..<end])..."
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}

extension ArkCLIProvider {
    /// Resolve the arkcli binary: $ARKCLI_PATH, then PATH, then common install locations.
    static func resolveArkcliPath(environment: [String: String]) -> String? {
        if let explicit = environment["ARKCLI_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty, FileManager.default.isExecutableFile(atPath: explicit)
        {
            return explicit
        }
        let pathDirs = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        // PATH contains directories, not executables. Resolve `arkcli` beneath
        // each directory; testing the directory itself can otherwise select an
        // arbitrary executable directory (for example a Flutter SDK bin folder)
        // and fail with zsh exit 126.
        let candidates = pathDirs.map { "\($0)/arkcli" } + [
            "/opt/homebrew/bin/arkcli",
            "/usr/local/bin/arkcli",
            "\(NSHomeDirectory())/.arkcli/bin/arkcli",
            "\(NSHomeDirectory())/.local/bin/arkcli",
            "\(NSHomeDirectory())/.volta/bin/arkcli",
        ]
        return candidates.first {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    /// Pick a login shell. $SHELL first, then fall back to common locations.
    static func loginShell() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["SHELL"],
            "/bin/zsh",
            "/bin/bash",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Drains a Pipe on a background thread so a large stderr can't deadlock stdout
/// (or vice versa). `readDataToEndOfFile()` blocks until the write end closes
/// (i.e. the process exits), so it must run off the calling thread.
/// `finish()` blocks until the reader thread completes.
private final class PipeReader: @unchecked Sendable {
    private let pipe: Pipe
    private let limit: Int
    private let group = DispatchGroup()
    private var collected = Data()
    private let lock = NSLock()

    init(pipe: Pipe, limit: Int) {
        self.pipe = pipe
        self.limit = limit
        self.group.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.readLoop()
        }
    }

    private func readLoop() {
        defer { group.leave() }
        // readDataToEndOfFile blocks until EOF (process exits), so this is safe off-thread.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        if data.count <= limit {
            collected = data
        } else {
            // Truncate to limit so we never hold a runaway output.
            collected = data.prefix(limit)
        }
        lock.unlock()
    }

    /// Blocks until the reader thread finishes, returns whatever it collected.
    func finish() -> Data {
        group.wait()
        lock.lock()
        let data = collected
        lock.unlock()
        return data
    }
}

// MARK: - arkcli JSON schema

private struct ArkcliUsageResponse: Decodable {
    let viewer: ArkcliViewer?
    let items: [ArkcliUsageItem]
}

private struct ArkcliViewer: Decodable {
    let authMethod: String?
    enum CodingKeys: String, CodingKey { case authMethod = "auth_method" }
}

private struct ArkcliUsageItem: Decodable {
    let product: String
    let edition: String?
    let tier: String?
    let seatID: String?
    let subscribed: Bool?
    let periods: [ArkcliPeriod]?
    let updatedAt: TimeInterval?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case product, edition, tier
        case seatID = "seat_id"
        case subscribed, periods
        case updatedAt = "updated_at"
        case error
    }
}

private struct ArkcliPeriod: Decodable {
    let label: String
    let used: Int?
    let total: Int?
    let percent: Double
    let resetAt: ArkcliResetAt?

    enum CodingKeys: String, CodingKey {
        case label, used, total, percent
        case resetAt = "reset_at"
    }
}

private enum ArkcliResetAt: Decodable {
    case string(String)
    case number(TimeInterval)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(TimeInterval.self) {
            self = .number(number)
        } else {
            self = try .string(container.decode(String.self))
        }
    }

    var date: Date? {
        switch self {
        case let .string(value):
            return Self.parseISO8601(value)
        case let .number(value):
            guard value > 0 else { return nil }
            // ms vs seconds detection, same rule as updated_at.
            let seconds = value >= 1e11 ? value / 1000 : value
            return Date(timeIntervalSince1970: seconds)
        }
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }
}
