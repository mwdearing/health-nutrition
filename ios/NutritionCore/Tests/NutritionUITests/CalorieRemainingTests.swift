import Foundation
import XCTest
@testable import NutritionUI

final class CalorieRemainingTests: XCTestCase {
    func testGoalLessFoodWithNoBurned() {
        let value = CalorieRemaining.make(
            goal: 2000, food: 1500, partial: false, missingCount: 0, burned: nil, energyLabel: "Energy")
        XCTAssertEqual(value.remaining, 500)
        XCTAssertNil(value.burned)
    }

    func testBurnedAddsWhenCounted() {
        let value = CalorieRemaining.make(
            goal: 2000, food: 1500, partial: false, missingCount: 0, burned: 240, energyLabel: "Energy")
        XCTAssertEqual(value.remaining, 740)
        XCTAssertEqual(value.burned, 240)
    }

    /// A goal-less day with a Health burned figure and no logged food: Burned shows and Remaining stays hidden.
    func testGoalLessDayWithBurnedAndNoFoodShowsBurnedNotRemaining() {
        let value = CalorieRemaining.make(
            goal: nil, food: 0, partial: false, missingCount: 0, burned: 240, energyLabel: "Energy")
        XCTAssertEqual(value.burned, 240)
        XCTAssertNil(value.remaining)
        XCTAssertFalse(value.showsRemaining)
    }

    func testNoGoalMeansNoRemaining() {
        let value = CalorieRemaining.make(
            goal: nil, food: 1500, partial: false, missingCount: 0, burned: 240, energyLabel: "Energy")
        XCTAssertNil(value.remaining)
        XCTAssertEqual(value.food, 1500)
    }

    func testUnknownFoodMeansNoRemaining() {
        let value = CalorieRemaining.make(
            goal: 2000, food: nil, partial: false, missingCount: 0, burned: 240, energyLabel: "Energy")
        XCTAssertNil(value.remaining)
    }

    func testPartialFoodIsUsedAndFlagged() {
        let value = CalorieRemaining.make(
            goal: 2000, food: 1200, partial: true, missingCount: 1, burned: nil, energyLabel: "Energy")
        XCTAssertEqual(value.remaining, 800)
        XCTAssertTrue(value.isPartial)
    }

    func testSettingOffLeavesBurnedOutOfRemaining() {
        // The setting off is modelled by passing no burned: the stored goal less food, with no Burned shown.
        let value = CalorieRemaining.make(
            goal: 2000, food: 1500, partial: false, missingCount: 0, burned: nil, energyLabel: "Energy")
        XCTAssertEqual(value.remaining, 500)
        XCTAssertNil(value.burned)
    }

    func testNoHealthReadingIsGoalLessFood() {
        let value = CalorieRemaining.make(
            goal: 2100, food: 0, partial: false, missingCount: 0, burned: nil, energyLabel: "Energy")
        XCTAssertEqual(value.remaining, 2100)
    }

    /// The partial note is the shipped wording, one entry or several, with the goal on and with it off, and the
    /// flag and the note come from the same count, so a whole day has neither.
    func testPartialNoteIsTheShippedWordingWithGoalOnAndOff() {
        for goal in [Decimal?(2000), nil] {
            let one = CalorieRemaining.make(
                goal: goal, food: 1500, partial: true, missingCount: 1, burned: nil, energyLabel: "Energy")
            XCTAssertEqual(one.partialNote, "1 entry has no energy value")
            XCTAssertTrue(one.isPartial)

            let two = CalorieRemaining.make(
                goal: goal, food: 1500, partial: true, missingCount: 2, burned: nil, energyLabel: "Energy")
            XCTAssertEqual(two.partialNote, "2 entries have no energy value")
            XCTAssertTrue(two.isPartial)

            let whole = CalorieRemaining.make(
                goal: goal, food: 1500, partial: false, missingCount: 0, burned: nil, energyLabel: "Energy")
            XCTAssertNil(whole.partialNote)
            XCTAssertFalse(whole.isPartial)
        }
    }

    /// A partial line with no missing entry (a below-threshold amount) still shows the rows' fallback note, so a
    /// partial day never lacks one.
    func testBelowThresholdPartialDayKeepsANote() {
        let value = CalorieRemaining.make(
            goal: 2000, food: 1500, partial: true, missingCount: 0, burned: nil, energyLabel: "Energy")
        XCTAssertTrue(value.isPartial)
        XCTAssertEqual(value.partialNote, "Some entries can't be added up for energy")
    }

    /// Below threshold with the goal off: the fallback note still shows, and there is no Remaining to speak.
    func testBelowThresholdPartialDayWithGoalOffKeepsTheNote() {
        let value = CalorieRemaining.make(
            goal: nil, food: 1500, partial: true, missingCount: 0, burned: nil, energyLabel: "Energy")
        XCTAssertTrue(value.isPartial)
        XCTAssertNil(value.remaining)
        XCTAssertEqual(value.partialNote, "Some entries can't be added up for energy")
    }

    /// Remaining is shown only with a goal and a known food total. Counting activity changes Remaining's value,
    /// not whether it is shown, so the flag holds with the active-energy setting on (burned given) and off (nil).
    func testShowsRemainingOnlyWithAGoalAndAKnownFood() {
        XCTAssertTrue(CalorieRemaining.make(
            goal: 2000, food: 500, partial: false, missingCount: 0, burned: nil, energyLabel: "Energy").showsRemaining)
        XCTAssertTrue(CalorieRemaining.make(
            goal: 2000, food: 500, partial: false, missingCount: 0, burned: 120, energyLabel: "Energy").showsRemaining)
        XCTAssertFalse(CalorieRemaining.make(
            goal: nil, food: 500, partial: false, missingCount: 0, burned: nil, energyLabel: "Energy").showsRemaining)
        XCTAssertFalse(CalorieRemaining.make(
            goal: nil, food: 500, partial: false, missingCount: 0, burned: 120, energyLabel: "Energy").showsRemaining)
        XCTAssertFalse(CalorieRemaining.make(
            goal: 2000, food: nil, partial: false, missingCount: 0, burned: nil, energyLabel: "Energy").showsRemaining)
    }
}
