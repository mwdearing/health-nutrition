import XCTest
@testable import NutritionUI

/// Wording the owner approved (#593, #992), pinned as literals so a later edit cannot change it unnoticed.
@MainActor
final class ApprovedCopyTests: XCTestCase {
    func testTheAddScanTilesSayScanBarcodeAndScanLabel() {
        XCTAssertEqual(AddQuickActionTitle.barcode, "Scan barcode")
        XCTAssertEqual(AddQuickActionTitle.label, "Scan label")
    }

    func testTheNotificationsOffMessageNamesTheSettingsAppOnAnyDevice() {
        let approved = "Notifications are turned off for this app. You can allow them in the Settings app."
        XCTAssertEqual(ReminderController.withdrawnMessage, approved)
        XCTAssertEqual(CustomReminderController.withdrawnMessage, approved)
    }
}
