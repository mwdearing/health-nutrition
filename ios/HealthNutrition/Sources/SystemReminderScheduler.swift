import Foundation
import NutritionUI
import UserNotifications

/// The system's local notifications behind the reminder seam. This is the only file in the app that
/// imports the notifications framework. It stores nothing: each call asks the notification center for
/// what it needs at that moment.
final class SystemReminderScheduler: ReminderScheduling {
    func permission() async -> ReminderPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .allowed
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// The text names no health data: the reminder asks the person to open the app.
    func scheduleDaily(at time: ReminderTime) async {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Log your meals"
        content.body = "Open Health Nutrition to add what you have eaten today."
        content.sound = .default
        // Hour and minute only, with no date or time zone, so the reminder follows the local clock.
        let components = DateComponents(hour: time.hour, minute: time.minute)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: ReminderIdentifier.daily, content: content, trigger: trigger)
        center.removePendingNotificationRequests(withIdentifiers: [ReminderIdentifier.daily])
        try? await center.add(request)
    }

    func cancelDaily() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [ReminderIdentifier.daily])
        center.removeDeliveredNotifications(withIdentifiers: [ReminderIdentifier.daily])
    }

    func pendingDailyCount() async -> Int {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending.filter { $0.identifier == ReminderIdentifier.daily }.count
    }
}
