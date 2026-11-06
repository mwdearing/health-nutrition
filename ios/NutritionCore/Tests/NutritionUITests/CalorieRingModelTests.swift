import XCTest
@testable import NutritionUI

/// What the calorie ring draws for each kind of day, and how far it may grow with the text size.
final class CalorieRingModelTests: XCTestCase {
    private func calories(goal: Decimal?, food: Decimal?, burned: Decimal? = nil, partial: Bool = false) -> CalorieRemaining {
        CalorieRemaining.make(
            goal: goal, food: food, partial: partial, missingCount: partial ? 1 : 0, burned: burned,
            energyLabel: "Calories")
    }

    func testProgressUsesFoodOverGoalPlusBurned() {
        let model = CalorieRingModel.make(calories(goal: 2100, food: 1060, burned: 200))
        XCTAssertEqual(model.state, .progress)
        XCTAssertEqual(model.fraction, Decimal(1060) / Decimal(2300))
        XCTAssertFalse(model.isPartial)
    }

    func testOverGoalFillsTheRing() {
        let model = CalorieRingModel.make(calories(goal: 2000, food: 2150))
        XCTAssertEqual(model.state, .overGoal)
        XCTAssertEqual(model.fraction, 1)
    }

    func testExactlyAtGoalIsFullProgressNotOver() {
        let model = CalorieRingModel.make(calories(goal: 2000, food: 2000))
        XCTAssertEqual(model.state, .progress)
        XCTAssertEqual(model.fraction, 1)
    }

    func testBurnedCaloriesKeepADayUnderGoal() {
        let model = CalorieRingModel.make(calories(goal: 2000, food: 2150, burned: 300))
        XCTAssertEqual(model.state, .progress)
        XCTAssertEqual(model.fraction, Decimal(2150) / Decimal(2300))
    }

    func testNoGoalDrawsNoProgress() {
        let model = CalorieRingModel.make(calories(goal: nil, food: 900))
        XCTAssertEqual(model.state, .noGoal)
        XCTAssertNil(model.fraction)
    }

    func testUnknownFoodCannotTotal() {
        let model = CalorieRingModel.make(calories(goal: 2000, food: nil))
        XCTAssertEqual(model.state, .cannotTotal)
        XCTAssertNil(model.fraction)
    }

    func testPartialDayKeepsItsFlag() {
        let model = CalorieRingModel.make(calories(goal: 2000, food: 800, partial: true))
        XCTAssertEqual(model.state, .progress)
        XCTAssertEqual(model.fraction, Decimal(800) / Decimal(2000))
        XCTAssertTrue(model.isPartial)
    }

    func testZeroGoalWithNoFoodDrawsNothing() {
        let model = CalorieRingModel.make(calories(goal: 0, food: 0))
        XCTAssertEqual(model.state, .progress)
        XCTAssertEqual(model.fraction, 0)
    }

    func testRingDiameterScalesWithTextSizeAndStopsAtOnePointSix() {
        XCTAssertEqual(CalorieRingMetrics.diameter(base: 200, scale: 1), 200)
        XCTAssertEqual(CalorieRingMetrics.diameter(base: 200, scale: 1.3), 260, accuracy: 0.001)
        XCTAssertEqual(CalorieRingMetrics.diameter(base: 200, scale: 3), 320, accuracy: 0.001)
        XCTAssertEqual(CalorieRingMetrics.diameter(base: 116, scale: 0.8), 92.8, accuracy: 0.001)
    }
}
