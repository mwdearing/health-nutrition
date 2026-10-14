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

    func testUseWritesTheReferencesOwnUnitWhateverThePickerHeld() throws {
        let (model, store) = makeModel(group: men31)
        model.selectedUnits["iron"] = .g
        XCTAssertTrue(model.useReferenceGoal(for: "iron"))
        XCTAssertEqual(try store.goal(for: "iron"), NutrientGoal(nutrient: "iron", target: 8, unit: .mg))
        XCTAssertEqual(model.selectedUnits["iron"], .mg)
    }

    func testAGoalKeptUnderAnAliasIsAGoalForTheNutrient() throws {
        // A label's `vitamin-c` goal is a goal for vitamin C, so the canonical row is not offered a second.
        let (model, store) = makeModel(
            goals: [NutrientGoal(nutrient: "vitamin-c", target: 500, unit: .mg)], group: men31)
        XCTAssertNil(model.referenceGoalHint(for: "vitaminC"))
        XCTAssertFalse(model.useReferenceGoal(for: "vitaminC"))
        XCTAssertNil(try store.goal(for: "vitaminC"))
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
        for key in ["chloride", "protein", "energy", "water", "sodium", "vitamin-d"] {
            XCTAssertNil(model.referenceGoalHint(for: key), key)
        }
    }

    func testVitaminsStatedInIUAreNeverOfferedAReference() {
        // The table covers them, but a goal in mcg or mg could not be compared with an IU label.
        XCTAssertEqual(GoalsViewModel.referenceGoalExcludedKeys, ["vitaminA", "vitaminD", "vitaminE"])
        XCTAssertNotNil(ReferenceIntakes.intake(for: "vitaminD", group: men31))
        let (model, _) = makeModel(group: men31)
        for key in ["vitaminA", "vitaminD", "vitaminE"] {
            XCTAssertNil(model.referenceGoalHint(for: key), key)
        }
    }

    func testEachConditionOfTheRuleStopsTheHintOnItsOwn() {
        func hint(
            _ nutrient: String = "iron", group: ReferenceGroup? = ReferenceGroup(sex: .male, ageBand: .years31To50),
            offered: Bool = true, draft: String? = "", unit: MeasureUnit = .mg
        ) -> ReferenceGoalHint? {
            GoalsViewModel.referenceGoalHint(
                nutrient: nutrient, group: group, isOfferedWithoutGoal: offered, draft: draft, goalUnit: unit)
        }
        XCTAssertEqual(hint()?.text, "RDA 8 mg for Men 31 to 50")
        XCTAssertNil(hint(group: nil))
        XCTAssertNil(hint(offered: false))
        XCTAssertNil(hint(draft: "12"))
        // A row counted in IU is never offered a mass reference.
        XCTAssertNil(hint(unit: .iu))
        // Even offered as a mass row, the IU-stated vitamins are excluded by name.
        XCTAssertNil(hint("vitaminD", unit: .mcg))
        XCTAssertNil(hint("vitaminE", unit: .mg))
        XCTAssertNil(hint("vitaminA", unit: .mcg))
        // Captured aliases are not table keys.
        XCTAssertNil(hint("vitamin-a", unit: .iu))
        XCTAssertNil(hint("vitamin-e", unit: .mg))
    }

    func testAFailedUseLeavesTheRowAsItWas() {
        let store = InMemoryGoalStore(refusesWrites: true)
        let preferences = InMemoryDisplayPreferences()
        preferences.setReferenceGroup(men31)
        let model = GoalsViewModel(store: store, preferences: preferences)
        model.load()
        model.selectedUnits["iron"] = .g

        XCTAssertFalse(model.useReferenceGoal(for: "iron"))

        XCTAssertEqual(model.draftText["iron"], "")
        XCTAssertEqual(model.selectedUnits["iron"], .g)
    }

    func testANumberBeingTypedIsNotReplacedByTheReference() throws {
        let (model, store) = makeModel(group: men31)
        model.draftText["iron"] = "12"
        XCTAssertNil(model.referenceGoalHint(for: "iron"))
        XCTAssertFalse(model.useReferenceGoal(for: "iron"))
        XCTAssertEqual(model.draftText["iron"], "12")
        XCTAssertNil(try store.goal(for: "iron"))
    }

    func testUsingTheReferenceClearsAnErrorTheRowShowed() throws {
        let (model, _) = makeModel(group: men31)
        model.draftText["iron"] = "0"
        XCTAssertFalse(model.commitTarget(for: "iron"))
        XCTAssertNotNil(model.rowError["iron"])
        model.draftText["iron"] = ""
        XCTAssertTrue(model.useReferenceGoal(for: "iron"))
        XCTAssertNil(model.rowError["iron"])
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
