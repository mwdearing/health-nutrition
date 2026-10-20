import XCTest

@testable import NutritionUI

final class ReminderReadbackTests: XCTestCase {
    /// Nothing pending after the erase means nothing is reported as still on the phone.
    func testNothingPendingReportsNothing() async {
        let names = await ReminderReadback.namesStillPending(in: FakePendingCenter([]), pause: {})
        XCTAssertEqual(names, [])
    }

    /// The daily request left pending is reported as "reminders".
    func testAPendingDailyRequestIsReported() async {
        let names = await ReminderReadback.namesStillPending(
            in: FakePendingCenter([ReminderIdentifier.daily]), pause: {})
        XCTAssertEqual(names, ["reminders"])
    }

    /// A custom request left pending is reported as "custom reminders", and other requests are ignored.
    func testAPendingCustomRequestIsReportedAndOthersAreNot() async {
        let names = await ReminderReadback.namesStillPending(
            in: FakePendingCenter(["unrelated-request", "custom-reminder-\(UUID().uuidString)"]), pause: {})
        XCTAssertEqual(names, ["custom reminders"])
    }

    /// A removal the system is still processing clears within the reads: the store is not reported.
    func testARequestThatClearsWithinTheReadsIsNotReported() async {
        let center = ClearingPendingCenter(identifiers: [ReminderIdentifier.daily], clearsAfterReads: 2)
        let names = await ReminderReadback.namesStillPending(in: center, pause: {})
        XCTAssertEqual(names, [])
    }

    /// A request that never clears is still there at the last read, so it is reported.
    func testARequestThatNeverClearsIsReported() async {
        let center = ClearingPendingCenter(identifiers: [ReminderIdentifier.daily], clearsAfterReads: nil)
        let names = await ReminderReadback.namesStillPending(in: center, pause: {})
        XCTAssertEqual(names, ["reminders"])
        XCTAssertEqual(center.reads, ReminderReadback.settleReads)
    }
}

private struct FakePendingCenter: PendingReminderCenter {
    let identifiers: [String]
    init(_ identifiers: [String]) { self.identifiers = identifiers }
    func pendingRequestIdentifiers() async -> [String] { identifiers }
}

/// A center whose requests stay pending for `clearsAfterReads` reads, then clear; `nil` means they never clear.
private final class ClearingPendingCenter: PendingReminderCenter, @unchecked Sendable {
    private let lock = NSLock()
    private let identifiers: [String]
    private let clearsAfterReads: Int?
    private var readCount = 0

    var reads: Int { lock.withLock { readCount } }

    init(identifiers: [String], clearsAfterReads: Int?) {
        self.identifiers = identifiers
        self.clearsAfterReads = clearsAfterReads
    }

    func pendingRequestIdentifiers() async -> [String] {
        lock.withLock {
            readCount += 1
            if let clearsAfterReads, readCount > clearsAfterReads { return [] }
            return identifiers
        }
    }
}
