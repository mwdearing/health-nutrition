import Foundation
import XCTest

@testable import NutritionUI

/// The calorie summary is the only Today block: Food is a dash until something is logged, never 0; Remaining is a
/// dash with a goal but no known food and hidden without a goal; Burned shows only with a Health figure.
final class CalorieSummaryFiguresTests: XCTestCase {
    private func figures(goal: Decimal?, food: Decimal?, burned: Decimal? = nil) -> NourishTodayHeader.SummaryFigures {
        NourishTodayHeader.summaryFigures(CalorieRemaining.make(
            goal: goal, food: food, partial: false, missingCount: 0, burned: burned, energyLabel: "Energy"))
    }

    func testNothingLoggedWithAGoalShowsDashesNotZero() {
        XCTAssertEqual(figures(goal: 2000, food: nil), .init(remaining: "—", caption: "Calories remaining", food: "—", burned: nil))
    }

    func testNothingLoggedWithoutAGoalShowsOnlyFoodAsADash() {
        XCTAssertEqual(figures(goal: nil, food: nil), .init(remaining: nil, caption: "Calories remaining", food: "—", burned: nil))
    }

    func testLoggedFoodWithAGoalShowsRemainingFoodAndBurned() {
        let result = figures(goal: 2000, food: 500, burned: 120)
        // Remaining is goal minus food plus burned (CalorieRemaining.make), so 2000 - 500 + 120.
        XCTAssertEqual(result.remaining, "1,620")
        XCTAssertEqual(result.food, "500")
        XCTAssertEqual(result.burned, "120")
    }

    func testAnExplicitlyLoggedZeroFoodShowsZero() {
        XCTAssertEqual(figures(goal: 2000, food: 0).food, "0")
    }

    func testLoggedFoodWithoutAGoalShowsFoodAndNoRemaining() {
        XCTAssertEqual(figures(goal: nil, food: 500), .init(remaining: nil, caption: "Calories remaining", food: "500", burned: nil))
    }

    func testOverGoalShowsAPositiveFigureUnderCaloriesOverGoal() {
        let result = figures(goal: 2000, food: 2150)
        XCTAssertEqual(result.remaining, "150")
        XCTAssertEqual(result.caption, "Calories over goal")
    }

    func testPartialDayWithSomethingLeftReadsUpTo() {
        let calories = CalorieRemaining.make(
            goal: 2000, food: 500, partial: true, missingCount: 1, burned: nil, energyLabel: "Energy")
        let result = NourishTodayHeader.summaryFigures(calories)
        XCTAssertEqual(result.remaining, "Up to 1,500")
        XCTAssertEqual(result.caption, "Calories remaining")
    }

    func testExactlyZeroIsNotOverGoal() {
        let result = figures(goal: 2000, food: 2000)
        XCTAssertEqual(result.remaining, "0")
        XCTAssertEqual(result.caption, "Calories remaining")
    }
}
