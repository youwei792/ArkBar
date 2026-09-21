import Foundation

// MARK: - Manual subscriptions

/// A subscription the user tracks manually because TokenBar has no provider
/// for it (annual plans, services outside the integrated set). Non-sensitive,
/// so it lives in UserDefaults.
struct ManualSubscription: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var expiryDate: Date
    var note: String

    init(id: String = UUID().uuidString, name: String, expiryDate: Date, note: String = "") {
        self.id = id
        self.name = name
        self.expiryDate = expiryDate
        self.note = note
    }
}

// MARK: - Reminder items

/// One expiring thing to surface in the menu and (optionally) a notification.
struct ExpiryReminderItem: Sendable, Equatable, Identifiable {
    /// Stable identity for notification de-duplication: "plan:<tab>:<plan id>"
    /// or "manual:<subscription id>".
    let id: String
    /// Display name, e.g. "LongCat" or the manual subscription's name.
    let name: String
    let expiryDate: Date
    /// Whole calendar days until expiry (negative when already expired).
    let daysUntilExpiry: Int
    /// Remaining quota percent when the provider reports it; nil for manual
    /// entries and providers without a quota concept.
    let remainingPercent: Double?
    /// Jump target when the item maps to an integrated provider; nil for
    /// manual entries (they open the reminder settings instead).
    let tab: ProviderTab?

    var isOverdue: Bool { daysUntilExpiry < 0 }
}

/// One plan's contribution to the reminder engine: its expiry date plus the
/// quota that would be lost when it lapses.
struct PlanReminderSource: Sendable, Equatable {
    let tab: ProviderTab
    let planID: String
    let expiryDate: Date
    /// The quota that lapses at expiry: the monthly window when present,
    /// otherwise the tightest window. nil when the plan reports no windows.
    let remainingPercent: Double?
}

// MARK: - Engine

/// Pure decision logic for "this subscription is about to expire with quota
/// left — nag the user to use it up". Kept free of AppKit/UserNotifications
/// so the rules are unit-testable.
enum ReminderEngine {
    /// Remaining-quota floor: below this the plan counts as "basically used
    /// up" and no longer deserves nagging.
    static let lowUsageWatermark = 50.0

    /// Whole calendar days from `now` (start of day) to `expiry` (start of
    /// day). Mirrors `PlanSnapshot.daysUntilExpiry` so menu rows and cards
    /// count days identically.
    static func daysUntilExpiry(_ expiry: Date, now: Date = Date(),
                                calendar: Calendar = .current) -> Int
    {
        let start = calendar.startOfDay(for: now)
        let end = calendar.startOfDay(for: expiry)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    /// Builds the visible reminder list. Integrated plans appear when they
    /// expire within the lead time and still hold at least `lowUsageWatermark`
    /// quota; manual entries appear whenever they expire within the lead time
    /// (overdue ones stay visible in red until the user edits or deletes
    /// them). Sorted by urgency (fewest days first).
    static func makeItems(
        planSources: [PlanReminderSource],
        manual: [ManualSubscription],
        now: Date = Date(),
        daysThreshold: Int,
        lowUsageWatermark: Double = Self.lowUsageWatermark
    ) -> [ExpiryReminderItem] {
        var items: [ExpiryReminderItem] = []

        for source in planSources {
            let days = daysUntilExpiry(source.expiryDate, now: now)
            guard days >= 0, days <= daysThreshold else { continue }
            if let remaining = source.remainingPercent, remaining < lowUsageWatermark { continue }
            items.append(ExpiryReminderItem(
                id: "plan:\(source.tab.rawValue):\(source.planID)",
                name: source.tab.displayName,
                expiryDate: source.expiryDate,
                daysUntilExpiry: days,
                remainingPercent: source.remainingPercent,
                tab: source.tab))
        }

        for subscription in manual {
            // Unnamed drafts (freshly added, never typed into) stay out of the
            // reminder list until they get a name.
            let trimmedName = subscription.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }
            let days = daysUntilExpiry(subscription.expiryDate, now: now)
            guard days <= daysThreshold else { continue }
            items.append(ExpiryReminderItem(
                id: "manual:\(subscription.id)",
                name: trimmedName,
                expiryDate: subscription.expiryDate,
                daysUntilExpiry: days,
                remainingPercent: nil,
                tab: nil))
        }

        return items.sorted {
            if $0.daysUntilExpiry != $1.daysUntilExpiry {
                return $0.daysUntilExpiry < $1.daysUntilExpiry
            }
            return $0.name < $1.name
        }
    }

    /// Whether a system notification may fire for this item right now: inside
    /// the notify window (never for overdue entries), and not already notified
    /// on the same calendar day. The quota/threshold gate has already been
    /// applied when the item was built.
    static func shouldNotify(
        _ item: ExpiryReminderItem,
        lastNotifiedDate: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard !item.isOverdue, item.daysUntilExpiry >= 0 else { return false }
        if let lastNotifiedDate,
           calendar.isDate(lastNotifiedDate, inSameDayAs: now)
        {
            return false
        }
        return true
    }
}
