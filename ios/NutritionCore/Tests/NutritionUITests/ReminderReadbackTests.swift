import XCTest

@testable import NutritionUI

final class ReminderReadbackTests: XCTestCase {
    /// Nothing pending after the erase means nothing is reported as still on the phone.
    func testNothingPendingReportsNothing() async {
        let names = await ReminderReadback.namesStillPending(in: FakePendingCenter([]))
        XCTAssertEqual(names, [])
    }

    /// The daily request left pending is reported as "reminders".
    func testAPendingDailyRequestIsReported() async {
        let names = await ReminderReadback.namesStillPending(in: FakePendingCenter([ReminderIdentifier.daily]))
        XCTAssertEqual(names, ["reminders"])
    }

    /// A custom request left pending is reported as "custom reminders", and other requests are ignored.
    func testAPendingCustomRequestIsReportedAndOthersAreNot() async {
        let names = await ReminderReadback.namesStillPending(
            in: FakePendingCenter(["unrelated-request", "custom-reminder-\(UUID().uuidString)"]))
        XCTAssertEqual(names, ["custom reminders"])
    }
}

private struct FakePendingCenter: PendingReminderCenter {
    let identifiers: [String]
    init(_ identifiers: [String]) { self.identifiers = identifiers }
    func pendingRequestIdentifiers() async -> [String] { identifiers }
}
