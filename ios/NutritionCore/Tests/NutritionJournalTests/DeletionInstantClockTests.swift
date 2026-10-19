import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// The tombstone instant of a delete comes from the store's clock, not the caller's `now` (#521 item 4).
final class DeletionInstantClockTests: XCTestCase {
    func testADeleteStampsItsTombstoneFromTheStoreClock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try SwiftDataJournalStore(
            url: directory.appendingPathComponent("clock.store"), clock: { fixed })
        let id = "00000000-0000-4000-8000-0000000000d1"
        let callerNow = Date(timeIntervalSince1970: 1_700_000_000)
        try store.create(
            Intake(id: id, category: "food", occurredAt: callerNow, timeZoneIdentifier: "UTC", meal: "breakfast"),
            components: [IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g)],
            product: nil, now: callerNow)
        try store.delete(intakeID: id, now: callerNow)
        let deleteOp = try XCTUnwrap(try store.pendingOutbox().first { $0.kind == .delete })
        XCTAssertEqual(try store.deletionInstant(operationID: deleteOp.operationID), fixed)
    }
}
