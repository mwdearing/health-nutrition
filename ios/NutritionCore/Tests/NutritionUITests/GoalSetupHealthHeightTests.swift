import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Goal setup fills an empty height field from the newest height Apple Health reports (#508). Synthetic heights.
@MainActor
final class GoalSetupHealthHeightTests: XCTestCase {
    private func makeModel(system: UnitSystem = .metric, healthHeight: Decimal?) -> GoalSetupViewModel {
        let goals = GoalsViewModel(
            store: InMemoryGoalStore(goals: []), preferences: InMemoryDisplayPreferences(unitSystem: system))
        goals.latestHeightCentimeters = { healthHeight }
        return GoalSetupViewModel(goals: goals)
    }

    func testAMetricHeightFromHealthFillsTheCentimetersField() {
        let model = makeModel(healthHeight: Decimal(string: "175.4")!)
        XCTAssertEqual(model.heightCentimetersText, "175")
    }

    func testAUSHeightFromHealthFillsFeetAndInches() {
        // 180 cm is 70.87 in, which rounds to 71 in: 5 ft 11 in.
        let model = makeModel(system: .usCustomary, healthHeight: 180)
        XCTAssertEqual(model.heightFeetText, "5")
        XCTAssertEqual(model.heightInchesText, "11")
        XCTAssertEqual(model.heightCentimetersText, "")
    }

    func testWithoutAHealthHeightTheFieldStaysEmpty() {
        let model = makeModel(healthHeight: nil)
        XCTAssertEqual(model.heightCentimetersText, "")
    }

    func testAHeightOutsideTheEstimateRangeIsNotFilledIn() {
        XCTAssertEqual(makeModel(healthHeight: 100).heightCentimetersText, "")
        XCTAssertEqual(makeModel(healthHeight: 240).heightCentimetersText, "")
    }

    func testATypedHeightIsNotReplaced() {
        let model = makeModel(healthHeight: 175)
        model.heightCentimetersText = "168"
        model.fillHeightFromHealth()
        XCTAssertEqual(model.heightCentimetersText, "168")
    }

    func testClearingTheAnswersFillsTheHeightAgain() {
        let model = makeModel(healthHeight: 175)
        model.heightCentimetersText = "168"
        model.clearAnswers()
        XCTAssertEqual(model.heightCentimetersText, "175")
    }
}
