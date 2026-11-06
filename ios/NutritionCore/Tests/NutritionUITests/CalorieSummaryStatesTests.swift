import Foundation
import XCTest
@testable import NutritionUI

/// The calorie summary in each state the ring draws. Over the goal it says how far over, never a negative
/// remaining figure. A day whose entries have no calories says it cannot total; an empty day says nothing is
/// logged yet, because a fresh morning is not a day that failed to add up.
@MainActor
final class CalorieSummaryStatesTests: XCTestCase {
    private func day(goal: Decimal?, food: Decimal?, burned: Decimal? = nil) -> CalorieRemaining {
        CalorieRemaining.make(
            goal: goal, food: food, partial: false, missingCount: 0, burned: burned, energyLabel: "Energy")
    }

    // Thousands are grouped by the device locale, so the expected figures come from the same formatter.
    private func whole(_ value: Decimal) -> String { BodyActivityViewModel.whole(value) }

    func testOverTheGoalShowsHowFarOverAndNeverANegativeFigure() {
        let calories = day(goal: 2000, food: 2150)
        XCTAssertEqual(NourishTodayHeader.summaryFigures(calories).remaining, whole(150))
        XCTAssertEqual(NourishTodayHeader.remainingCaption(calories), "Calories over goal")
        XCTAssertEqual(
            NourishTodayHeader.spokenSummary(calories, partial: nil, footnote: "of 2,000 Calories goal"),
            "\(whole(150)) calories over goal, Food, \(whole(2150)) calories, of 2,000 Calories goal")
    }

    func testExactlyAtTheGoalIsZeroRemaining() {
        let calories = day(goal: 2000, food: 2000)
        XCTAssertEqual(NourishTodayHeader.summaryFigures(calories).remaining, whole(0))
        XCTAssertEqual(NourishTodayHeader.remainingCaption(calories), "Calories remaining")
        XCTAssertEqual(
            NourishTodayHeader.spokenSummary(calories, partial: nil, footnote: nil),
            "\(whole(0)) calories remaining, Food, \(whole(2000)) calories")
    }

    func testBurnedCaloriesCanBringTheDayBackUnderTheGoal() {
        // Remaining is goal minus food plus burned: 2000 - 2100 + 200.
        let calories = day(goal: 2000, food: 2100, burned: 200)
        XCTAssertEqual(NourishTodayHeader.summaryFigures(calories).remaining, whole(100))
        XCTAssertEqual(NourishTodayHeader.remainingCaption(calories), "Calories remaining")
    }

    func testEntriesWithNoCaloriesSayTheDayCannotTotal() {
        let calories = day(goal: 2000, food: nil)
        XCTAssertEqual(NourishTodayHeader.summaryFigures(calories).remaining, "—")
        XCTAssertEqual(NourishTodayHeader.remainingCaption(calories), "Calories remaining")
        XCTAssertEqual(
            NourishTodayHeader.spokenSummary(calories, partial: nil, footnote: nil, uncountedEntries: 2),
            "Calories can't total yet")
    }

    func testAnEmptyDaySaysNothingIsLoggedNotThatItCannotTotal() {
        let spoken = NourishTodayHeader.spokenSummary(
            day(goal: 2000, food: nil), partial: nil, footnote: nil, uncountedEntries: 0)
        XCTAssertEqual(spoken, "Nothing logged yet")
        XCTAssertFalse(spoken.localizedCaseInsensitiveContains("total"))
    }

    func testAnEmptyDayWithoutAGoalAlsoSaysNothingIsLogged() {
        XCTAssertEqual(
            NourishTodayHeader.spokenSummary(
                day(goal: nil, food: nil), partial: nil, footnote: nil, uncountedEntries: 0),
            "Nothing logged yet")
    }

    func testTheRingStateAgreesWithTheWords() {
        XCTAssertEqual(CalorieRingModel.make(day(goal: 2000, food: 2150)).state, .overGoal)
        XCTAssertEqual(CalorieRingModel.make(day(goal: 2000, food: 2000)).state, .progress)
        XCTAssertEqual(CalorieRingModel.make(day(goal: 2000, food: nil)).state, .cannotTotal)
        XCTAssertEqual(CalorieRingModel.make(day(goal: nil, food: 500)).state, .noGoal)
    }
}
