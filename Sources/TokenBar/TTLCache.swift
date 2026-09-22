import Foundation

/// Thread-safe time-to-live cache. Subscription/order lookups (Ark
/// ListSubscribeTrade, Z.ai subscription/list) move at day granularity, so
/// providers cache the result and skip the extra subprocess/HTTP call until
/// the TTL lapses.
/// `@unchecked Sendable` because the NSLock guards every access.
final class TTLCache<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let ttl: TimeInterval
    private var fetchedAt: Date?
    private var value: Value?

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func validValue(now: Date = Date()) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let value, let fetchedAt,
              now.timeIntervalSince(fetchedAt) < ttl else { return nil }
        return value
    }

    func store(_ value: Value, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
        self.fetchedAt = date
    }
}
