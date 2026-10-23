import Foundation
import XCTest
@testable import NutritionUI

/// Today's remaining figure in four cases: under goal, partial under goal, exactly zero, over goal. Synthetic values.
final class CalorieOverGoalTests: XCTestCase {
    private func calories(remaining goal: Decimal, food: Decimal, partial: Bool) -> CalorieRemaining {
        CalorieRemaining.make(goal: goal, food: food, partial: partial, missingCount: partial ? 1 : 0, burned: nil, energyLabel: "Calories")
    }

    func testUnderGoalShowsTheNumber() {
        let figures = NourishTodayHeader.summaryFigures(calories(remaining: 2000, food: 800, partial: false))
        XCTAssertEqual(figures.remaining, "1,200")
    }

    func testPartialUnderGoalSaysUpTo() {
        let figures = NourishTodayHeader.summaryFigures(calories(remaining: 2000, food: 800, partial: true))
        XCTAssertEqual(figures.remaining, "Up to 1,200")
        XCTAssertEqual(NourishTodayHeader.spokenRemaining(1200, partial: true), "up to 1,200 calories remaining")
    }

    func testExactlyZeroIsZeroNotOver() {
        let figures = NourishTodayHeader.summaryFigures(calories(remaining: 2000, food: 2000, partial: false))
        XCTAssertEqual(figures.remaining, "0")
        XCTAssertEqual(NourishTodayHeader.spokenRemaining(0, partial: false), "0 calories remaining")
    }

    func testOverGoalShowsThePositiveCountAndSpeaksOverGoal() {
        let figures = NourishTodayHeader.summaryFigures(calories(remaining: 2000, food: 2120, partial: false))
        XCTAssertEqual(figures.remaining, "120")
        XCTAssertEqual(NourishTodayHeader.spokenRemaining(-120, partial: false), "120 calories over goal")
    }
}
