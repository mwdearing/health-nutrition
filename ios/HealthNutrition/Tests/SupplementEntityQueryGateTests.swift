import XCTest

@testable import HealthNutrition

final class SupplementEntityQueryGateTests: XCTestCase {
    func testTheListIsNotReadWhileTheDeviceIsLocked() {
        XCTAssertFalse(SupplementEntityQuery.readsTheList(isUnlocked: false, isBusy: false))
    }

    func testTheListIsNotReadWhileAnEraseOrRestoreRuns() {
        XCTAssertFalse(SupplementEntityQuery.readsTheList(isUnlocked: true, isBusy: true))
    }

    func testTheListIsNotReadWhenLockedAndBusy() {
        XCTAssertFalse(SupplementEntityQuery.readsTheList(isUnlocked: false, isBusy: true))
    }

    func testTheListIsReadWhenUnlockedAndNotBusy() {
        XCTAssertTrue(SupplementEntityQuery.readsTheList(isUnlocked: true, isBusy: false))
    }
}
