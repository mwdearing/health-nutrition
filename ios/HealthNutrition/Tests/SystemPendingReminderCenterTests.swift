import UserNotifications
import XCTest

@testable import HealthNutrition
@testable import NutritionUI

/// The system readback, checked against the simulator's own notification center rather than a fake. Skips when the
/// runner has not granted notification permission, since the system will not keep a request it refuses.
final class SystemPendingReminderCenterTests: XCTestCase {
    func testAScheduledCustomRequestIsReadBackThroughTheSystemCenter() async throws {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
        try XCTSkipUnless(granted, "notifications are not authorized on this runner")

        let identifier = ReminderReadback.customPrefix + UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = "test"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        addTeardownBlock { center.removePendingNotificationRequests(withIdentifiers: [identifier]) }

        let identifiers = await SystemPendingReminderCenter().pendingRequestIdentifiers()
        XCTAssertTrue(identifiers.contains(identifier))
        let names = await ReminderReadback.namesStillPending(in: SystemPendingReminderCenter())
        XCTAssertTrue(names.contains("custom reminders"))
    }
}
