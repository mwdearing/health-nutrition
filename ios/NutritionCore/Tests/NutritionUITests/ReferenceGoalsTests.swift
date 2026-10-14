import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Reference values offered as goals on the Goals screen: only with a group chosen, only on a vitamin or
/// mineral row with no goal, and written as an ordinary goal in the reference's own amount and unit.
@MainActor
final class ReferenceGoalsTests: XCTestCase {
    private let men31 = ReferenceGroup(sex: .male, ageBand: .years31To50)

    private func makeModel(
        goals: [NutrientGoal] = [], group: ReferenceGroup? = nil
    ) -> (GoalsViewModel, InMemoryGoalStore) {
        let store = InMemoryGoalStore(goals: goals)
        let preferences = InMemoryDisplayPreferences()
        preferences.setReferenceGroup(group)
        let model = GoalsViewModel(store: store, preferences: preferences)
        model.load()
        return (model, store)
    }

    func testWithoutAGroupNoRowIsOfferedAReference() {
        let (model, _) = makeModel()
        XCTAssertNil(model.referenceGoalHint(for: "iron"))
        XCTAssertFalse(model.useReferenceGoal(for: "iron"))
    }

    func testARowWithNoGoalIsOfferedItsGroupsReference() {
        let (model, _) = makeModel(group: men31)
        XCTAssertEqual(
            model.referenceGoalHint(for: "iron"),
            ReferenceGoalHint(nutrient: "iron", amount: 8, unit: .mg, text: "RDA 8 mg for Men 31 to 50"))
        XCTAssertEqual(model.referenceGoalHint(for: "magnesium")?.text, "RDA 420 mg for Men 31 to 50")
        XCTAssertEqual(model.referenceGoalHint(for: "vitaminK")?.text, "AI 120 mcg for Men 31 to 50")
        XCTAssertEqual(model.referenceGoalHint(for: "copper")?.text, "RDA 0.9 mg for Men 31 to 50")

        let (women, _) = self.makeModel(group: ReferenceGroup(sex: .female, ageBand: .years19To30))
        XCTAssertEqual(women.referenceGoalHint(for: "iron")?.text, "RDA 18 mg for Women 19 to 30")
    }

    func testUsingTheReferenceWritesItAsAnOrdinaryGoalThatSurvivesLeavingTheField() throws {
        let (model, store) = makeModel(group: men31)

        XCTAssertTrue(model.useReferenceGoal(for: "iron"))

        XCTAssertEqual(try store.goal(for: "iron"), NutrientGoal(nutrient: "iron", target: 8, unit: .mg))
        XCTAssertEqual(model.draftText["iron"], "8")
        XCTAssertEqual(model.selectedUnits["iron"], .mg)
        XCTAssertNil(model.referenceGoalHint(for: "iron"))
        // Focus leaving the field commits the draft, which must be the new goal and not the old empty text.
        XCTAssertTrue(model.commitTarget(for: "iron"))
        XCTAssertEqual(try store.goal(for: "iron"), NutrientGoal(nutrient: "iron", target: 8, unit: .mg))
    }

    func testAFractionalReferenceIsWrittenExactly() throws {
        let (model, store) = makeModel(group: men31)
        XCTAssertTrue(model.useReferenceGoal(for: "copper"))
        XCTAssertEqual(
            try store.goal(for: "copper"), NutrientGoal(nutrient: "copper", target: Decimal(string: "0.9")!, unit: .mg))
    }

    func testAGoalAlreadySetIsNeverOfferedOrOverwritten() throws {
        let zinc = NutrientGoal(nutrient: "zinc", target: 15, unit: .mg)
        let (model, store) = makeModel(goals: [zinc], group: men31)
        XCTAssertNil(model.referenceGoalHint(for: "zinc"))
        XCTAssertFalse(model.useReferenceGoal(for: "zinc"))
        XCTAssertEqual(try store.goal(for: "zinc"), zinc)
    }

    func testRowsTheTableDoesNotCoverGetNoHint() {
        let (model, _) = makeModel(group: men31)
        for key in ["chloride", "protein", "energy", "water", "sodium", "vitaminD"] {
            XCTAssertNil(model.referenceGoalHint(for: key), key)
        }
    }

    func testChangingTheGroupNeverRewritesAGoalAlreadyCopied() throws {
        let store = InMemoryGoalStore()
        let preferences = InMemoryDisplayPreferences()
        preferences.setReferenceGroup(ReferenceGroup(sex: .female, ageBand: .years19To30))
        let model = GoalsViewModel(store: store, preferences: preferences)
        model.load()
        XCTAssertTrue(model.useReferenceGoal(for: "iron"))

        preferences.setReferenceGroup(men31)
        model.load()

        XCTAssertEqual(try store.goal(for: "iron"), NutrientGoal(nutrient: "iron", target: 18, unit: .mg))
        XCTAssertNil(model.referenceGoalHint(for: "iron"))
    }
}
