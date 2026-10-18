import Foundation
import XCTest
@testable import NutritionUI

final class CalorieRemainingTests: XCTestCase {
    func testGoalLessFoodWithNoBurned() {
        let value = CalorieRemaining.make(goal: 2000, food: 1500, isPartial: false, burned: nil)
        XCTAssertEqual(value.remaining, 500)
        XCTAssertNil(value.burned)
    }

    func testBurnedAddsWhenCounted() {
        let value = CalorieRemaining.make(goal: 2000, food: 1500, isPartial: false, burned: 240)
        XCTAssertEqual(value.remaining, 740)
        XCTAssertEqual(value.burned, 240)
    }

    func testNoGoalMeansNoRemaining() {
        let value = CalorieRemaining.make(goal: nil, food: 1500, isPartial: false, burned: 240)
        XCTAssertNil(value.remaining)
        XCTAssertEqual(value.food, 1500)
    }

    func testUnknownFoodMeansNoRemaining() {
        let value = CalorieRemaining.make(goal: 2000, food: nil, isPartial: false, burned: 240)
        XCTAssertNil(value.remaining)
    }

    func testPartialFoodIsUsedAndFlagged() {
        let value = CalorieRemaining.make(goal: 2000, food: 1200, isPartial: true, burned: nil)
        XCTAssertEqual(value.remaining, 800)
        XCTAssertTrue(value.isPartial)
    }

    func testSettingOffLeavesBurnedOutOfRemaining() {
        // The setting off is modelled by passing no burned: the stored goal less food, with no Burned shown.
        let value = CalorieRemaining.make(goal: 2000, food: 1500, isPartial: false, burned: nil)
        XCTAssertEqual(value.remaining, 500)
        XCTAssertNil(value.burned)
    }

    func testNoHealthReadingIsGoalLessFood() {
        let value = CalorieRemaining.make(goal: 2100, food: 0, isPartial: false, burned: nil)
        XCTAssertEqual(value.remaining, 2100)
    }
}
