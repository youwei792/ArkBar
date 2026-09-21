import Foundation
import UserNotifications

/// Owns the visible reminder list and the (optional) system notifications.
/// `UsageStore` calls `update` whenever provider snapshots or reminder
/// settings change; the menu reads `items`, and notifications de-duplicate
/// per subscription per calendar day in UserDefaults.
@MainActor
final class ReminderScheduler: ObservableObject {
    @Published private(set) var items: [ExpiryReminderItem] = []

    private let settings: AppSettings
    private var authorizationRequested = false

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    /// Rebuilds the reminder list from provider snapshots + manual entries
    /// and fires notifications for newly urgent items.
    func update(planSources: [PlanReminderSource],
                manual: [ManualSubscription],
                now: Date = Date()) {
        guard settings.expiryReminderEnabled else {
            if !items.isEmpty { items = [] }
            return
        }
        let next = ReminderEngine.makeItems(
            planSources: planSources,
            manual: manual,
            now: now,
            daysThreshold: settings.expiryReminderDays)
        let previous = items
        items = next
        guard settings.expiryReminderNotify else { return }
        // Only touch notifications when an item is new or its countdown moved
        // (e.g. a new day); the per-day stamp inside notifyIfNeeded is the
        // final de-dupe, so unchanged items stay silent.
        for item in next {
            let unchanged = previous.contains {
                $0.id == item.id && $0.daysUntilExpiry == item.daysUntilExpiry
            }
            if !unchanged { notifyIfNeeded(item, now: now) }
        }
    }

    /// Best-effort local notification. Never throws: reminder display must
    /// not break the refresh path.
    private func notifyIfNeeded(_ item: ExpiryReminderItem, now: Date) {
        guard Self.notificationsAvailable else { return }
        let key = Self.notifiedKey(for: item.id)
        let last = UserDefaults.standard.object(forKey: key) as? Date
        guard ReminderEngine.shouldNotify(item, lastNotifiedDate: last, now: now) else { return }

        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = item.name
        let dayText = item.daysUntilExpiry == 0
            ? L(.reminderExpiresToday)
            : String(format: L(.reminderDaysLeft), item.daysUntilExpiry)
        var parts: [String] = []
        if let remaining = item.remainingPercent {
            parts.append(String(format: L(.reminderBodyQuota), Int(remaining.rounded())))
        }
        parts.append(dayText)
        content.body = parts.joined(separator: " · ")
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "tokenbar.reminder.\(item.id)",
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                UsageStore.log("reminder notification failed: \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.set(now, forKey: key)
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        guard Self.notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted {
                UsageStore.log("reminder notification authorization not granted")
            }
        }
    }

    /// `UNUserNotificationCenter` crashes with NSInternalInconsistencyException
    /// in processes without an app bundle (bare `swift run` / `.build/debug`
    /// executions). Only touch it from the packaged `.app`; source runs keep
    /// the in-menu reminder section.
    static let notificationsAvailable: Bool = {
        Bundle.main.bundleURL.pathExtension == "app"
    }()

    private static func notifiedKey(for itemID: String) -> String {
        "tokenbar.reminder.lastNotified.\(itemID)"
    }

    /// Removes the de-dupe stamp when a manual entry is deleted, so a
    /// re-added subscription with the same id can notify again.
    static func clearNotifiedState(forManualID id: String) {
        UserDefaults.standard.removeObject(forKey: notifiedKey(for: "manual:\(id)"))
    }
}
