import Foundation
import XCTest
@testable import NutritionUI

final class CalorieRemainingTests: XCTestCase {
    func testGoalLessFoodWithNoBurned() {
        let value = CalorieRemaining.make(goal: 2000, food: 1500, missingCount: 0, burned: nil, energyLabel: "Energy")
        XCTAssertEqual(value.remaining, 500)
        XCTAssertNil(value.burned)
    }

    func testBurnedAddsWhenCounted() {
        let value = CalorieRemaining.make(goal: 2000, food: 1500, missingCount: 0, burned: 240, energyLabel: "Energy")
        XCTAssertEqual(value.remaining, 740)
        XCTAssertEqual(value.burned, 240)
    }

    func testNoGoalMeansNoRemaining() {
        let value = CalorieRemaining.make(goal: nil, food: 1500, missingCount: 0, burned: 240, energyLabel: "Energy")
        XCTAssertNil(value.remaining)
        XCTAssertEqual(value.food, 1500)
    }

    func testUnknownFoodMeansNoRemaining() {
        let value = CalorieRemaining.make(goal: 2000, food: nil, missingCount: 0, burned: 240, energyLabel: "Energy")
        XCTAssertNil(value.remaining)
    }

    func testPartialFoodIsUsedAndFlagged() {
        let value = CalorieRemaining.make(goal: 2000, food: 1200, missingCount: 1, burned: nil, energyLabel: "Energy")
        XCTAssertEqual(value.remaining, 800)
        XCTAssertTrue(value.isPartial)
    }

    func testSettingOffLeavesBurnedOutOfRemaining() {
        // The setting off is modelled by passing no burned: the stored goal less food, with no Burned shown.
        let value = CalorieRemaining.make(goal: 2000, food: 1500, missingCount: 0, burned: nil, energyLabel: "Energy")
        XCTAssertEqual(value.remaining, 500)
        XCTAssertNil(value.burned)
    }

    func testNoHealthReadingIsGoalLessFood() {
        let value = CalorieRemaining.make(goal: 2100, food: 0, missingCount: 0, burned: nil, energyLabel: "Energy")
        XCTAssertEqual(value.remaining, 2100)
    }

    /// The partial note is the shipped wording, one entry or several, with the goal on and with it off, and the
    /// flag and the note come from the same count, so a whole day has neither.
    func testPartialNoteIsTheShippedWordingWithGoalOnAndOff() {
        for goal: Decimal? in [2000, nil] {
            let one = CalorieRemaining.make(goal: goal, food: 1500, missingCount: 1, burned: nil, energyLabel: "Energy")
            XCTAssertEqual(one.partialNote, "1 entry has no energy value")
            XCTAssertTrue(one.isPartial)

            let two = CalorieRemaining.make(goal: goal, food: 1500, missingCount: 2, burned: nil, energyLabel: "Energy")
            XCTAssertEqual(two.partialNote, "2 entries have no energy value")
            XCTAssertTrue(two.isPartial)

            let whole = CalorieRemaining.make(goal: goal, food: 1500, missingCount: 0, burned: nil, energyLabel: "Energy")
            XCTAssertNil(whole.partialNote)
            XCTAssertFalse(whole.isPartial)
        }
    }
}
