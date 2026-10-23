import Foundation
import XCTest
@testable import NutritionUI

final class NourishGoalPromptTests: XCTestCase {
    private func calories(goal: Decimal?) -> CalorieRemaining {
        CalorieRemaining.make(goal: goal, food: 120, partial: false, missingCount: 0, burned: nil, energyLabel: "Calories")
    }

    func testNoEnergyGoalPublishesTheCalorieGoalPrompt() {
        XCTAssertEqual(NourishTodayHeader.goalPrompt(calories(goal: nil)), "Set a calorie goal to see what's left")
    }

    func testAnEnergyGoalHidesThePrompt() {
        XCTAssertNil(NourishTodayHeader.goalPrompt(calories(goal: 2000)))
    }
}
