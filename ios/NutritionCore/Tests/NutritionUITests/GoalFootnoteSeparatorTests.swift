import Foundation
import XCTest

@testable import NutritionUI

/// The calorie goal footnote groups its thousands the way the remaining figure does: "of 2,357 Calories goal".
final class GoalFootnoteSeparatorTests: XCTestCase {
    func testAFourDigitCalorieGoalIsGrouped() {
        XCTAssertEqual(
            NourishTodayHeader.ringFootnote(for: NutrientGoal(nutrient: "energy", target: 2357, unit: .kcal)),
            "of 2,357 Calories goal")
    }

    func testTheFootnoteAgreesWithTheRemainingFigureGrouping() {
        XCTAssertEqual(BodyActivityViewModel.whole(2357), "2,357")
        XCTAssertEqual(
            NourishTodayHeader.ringFootnote(for: NutrientGoal(nutrient: "energy", target: 2357, unit: .kcal)),
            "of \(BodyActivityViewModel.whole(2357)) Calories goal")
    }
}
