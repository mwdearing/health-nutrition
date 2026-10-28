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

    func testAUSHeightThatRoundsOutsideTheRangeIsNotFilledIn() {
        // 120.5 cm is 47.4 in, which rounds to 47 in, below the 48 in the estimate accepts.
        let low = makeModel(system: .usCustomary, healthHeight: Decimal(string: "120.5")!)
        XCTAssertEqual(low.heightFeetText, "")
        // 229.9 cm is 90.5 in, which rounds to 91 in, above the 90 in the estimate accepts.
        let high = makeModel(system: .usCustomary, healthHeight: Decimal(string: "229.9")!)
        XCTAssertEqual(high.heightFeetText, "")
    }

    func testAHeightReadAfterTheSheetOpenedFillsOnTheBodyStep() {
        var health: Decimal?
        let goals = GoalsViewModel(
            store: InMemoryGoalStore(goals: []), preferences: InMemoryDisplayPreferences(unitSystem: .metric))
        goals.latestHeightCentimeters = { health }
        let model = GoalSetupViewModel(goals: goals)
        XCTAssertEqual(model.heightCentimetersText, "")
        health = 175
        model.aim = .maintain
        model.next()
        model.sex = .male
        model.ageText = "30"
        model.next()
        XCTAssertEqual(model.step, .body)
        XCTAssertEqual(model.heightCentimetersText, "175")
    }

    func testAHeightThePersonClearedIsNotFilledAgainOnTheBodyStep() {
        let model = makeModel(healthHeight: 175)
        XCTAssertEqual(model.heightCentimetersText, "175")
        model.aim = .maintain
        model.next()
        model.sex = .male
        model.ageText = "30"
        model.next()
        model.heightCentimetersText = ""
        model.back()
        model.next()
        XCTAssertEqual(model.step, .body)
        XCTAssertEqual(model.heightCentimetersText, "", "a height the person cleared stays cleared")
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
