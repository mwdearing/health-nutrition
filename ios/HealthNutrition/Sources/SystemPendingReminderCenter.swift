import Foundation
import NutritionUI
import UserNotifications

/// The system notification center's pending requests, for the erase readback.
struct SystemPendingReminderCenter: PendingReminderCenter {
    func pendingRequestIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
    }
}
