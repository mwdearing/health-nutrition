import XCTest
@testable import NutritionUI

/// The selection line tells the person how many days Log will use, and the limit it checks against.
final class LogOnOtherDaysSelectionTests: XCTestCase {
    func testOneDayIsSingular() {
        XCTAssertEqual(LogOnOtherDaysSheet.selectionText(count: 1), "1 day selected, up to 14")
    }

    func testSeveralDaysArePlural() {
        XCTAssertEqual(LogOnOtherDaysSheet.selectionText(count: 3), "3 days selected, up to 14")
    }

    func testOverTheLimitStillShowsTheLimit() {
        XCTAssertEqual(LogOnOtherDaysSheet.selectionText(count: 15), "15 days selected, up to 14")
    }
}
