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

    /// Removes by identifier, which the center does before the call returns, so an erase is done when it returns.
    func cancel(medicationIDs: [UUID]) {
        let center = UNUserNotificationCenter.current()
        let identifiers = medicationIDs.map { MedicationReminderPlan.identifierPrefix + $0.uuidString }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Removes every pending and delivered request under the prefix and waits for it. The center answers on its own
    /// queue, so waiting here never blocks the answer; the wait is bounded.
    func cancelAll() {
        let center = UNUserNotificationCenter.current()
        let prefix = MedicationReminderPlan.identifierPrefix
        let found = IdentifierBox()
        let pending = DispatchSemaphore(value: 0)
        center.getPendingNotificationRequests { requests in
            found.set(pending: requests.map(\.identifier).filter { $0.hasPrefix(prefix) })
            pending.signal()
        }
        let delivered = DispatchSemaphore(value: 0)
        center.getDeliveredNotifications { notifications in
            found.set(delivered: notifications.map(\.request.identifier).filter { $0.hasPrefix(prefix) })
            delivered.signal()
        }
        _ = pending.wait(timeout: .now() + 2)
        _ = delivered.wait(timeout: .now() + 2)
        let (pendingIDs, deliveredIDs) = found.values()
        center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
        center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
    }
}

private final class IdentifierBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []
    private var delivered: [String] = []
    func set(pending ids: [String]) { lock.withLock { pending = ids } }
    func set(delivered ids: [String]) { lock.withLock { delivered = ids } }
    func values() -> ([String], [String]) { lock.withLock { (pending, delivered) } }
}
