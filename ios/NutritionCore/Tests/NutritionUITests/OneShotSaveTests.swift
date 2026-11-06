import XCTest
@testable import NutritionUI

final class OneShotSaveTests: XCTestCase {
    func testASecondBeginWhileSavingIsRefused() {
        var gate = OneShotSave()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
    }

    func testASuccessfulSaveStaysLocked() {
        var gate = OneShotSave()
        XCTAssertTrue(gate.begin())
        gate.finish(success: true)
        XCTAssertTrue(gate.isLocked)
        XCTAssertFalse(gate.begin())
    }

    func testAFailureUnlocksForARetry() {
        var gate = OneShotSave()
        XCTAssertTrue(gate.begin())
        gate.finish(success: false)
        XCTAssertFalse(gate.isLocked)
        XCTAssertTrue(gate.begin())
    }

    func testAFreshGateForAReopenedSheetAllowsAnotherDose() {
        var first = OneShotSave()
        XCTAssertTrue(first.begin())
        first.finish(success: true)
        var second = OneShotSave()
        XCTAssertTrue(second.begin())
    }
}
