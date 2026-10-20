import Foundation
import NutritionUI
import UserNotifications

/// Local notifications for the custom water and supplement reminders. Requests are named
/// "custom-reminder-<id>"; the daily log reminder keeps its own identifier and is never touched here.
extension SystemReminderScheduler: CustomReminderScheduling {
    private static let customPrefix = "custom-reminder-"

    private static func identifier(for id: UUID) -> String { customPrefix + id.uuidString }

    func replaceAll(with reminders: [CustomReminder]) async throws {
        let center = UNUserNotificationCenter.current()
        let wanted = Set(reminders.map { Self.identifier(for: $0.id) })
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(Self.customPrefix) && !wanted.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.kind.notificationTitle
            content.body = reminder.kind.notificationBody
            content.sound = .default
            let components = DateComponents(hour: reminder.time.hour, minute: reminder.time.minute)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let identifier = Self.identifier(for: reminder.id)
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        }
    }

    func cancel(ids: [UUID]) {
        let center = UNUserNotificationCenter.current()
        let identifiers = ids.map { Self.identifier(for: $0) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func pendingCustomCount() async -> Int {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending.filter { $0.identifier.hasPrefix(Self.customPrefix) }.count
    }
}
