import Foundation
import NutritionUI
import UserNotifications

/// Local notifications for the medication reminders. Requests are named "medication-reminder-<id>" and each fires
/// once, on one calendar day. The text is fixed and names no medication and no dose. The other reminders keep their
/// own identifiers and are never touched here.
extension SystemReminderScheduler: MedicationReminderScheduling {
    func replaceAll(with requests: [MedicationReminderRequest]) async throws {
        let center = UNUserNotificationCenter.current()
        let wanted = Set(requests.map(\.identifier))
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter {
            $0.hasPrefix(MedicationReminderPlan.identifierPrefix) && !wanted.contains($0)
        }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        for request in requests {
            let content = UNMutableNotificationContent()
            content.title = MedicationReminderPlan.notificationTitle
            content.body = MedicationReminderPlan.notificationBody
            content.sound = .default
            let components = DateComponents(
                year: request.day.year, month: request.day.month, day: request.day.day,
                hour: request.time.hour, minute: request.time.minute)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
            try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger))
        }
    }

    func cancelAll() {
        let center = UNUserNotificationCenter.current()
        Task {
            let identifiers = await center.pendingNotificationRequests().map(\.identifier)
                .filter { $0.hasPrefix(MedicationReminderPlan.identifierPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            let delivered = await center.deliveredNotifications().map(\.request.identifier)
                .filter { $0.hasPrefix(MedicationReminderPlan.identifierPrefix) }
            center.removeDeliveredNotifications(withIdentifiers: delivered)
        }
    }
}
