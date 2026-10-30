import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The whole starting set goal setup can offer from the reference table: the same rule as the Goals screen's
/// one-row hint, applied to every vitamin and mineral at once.
@MainActor
final class ReferenceGoalPrefillTests: XCTestCase {
    private let men31 = ReferenceGroup(sex: .male, ageBand: .years31To50)

    /// Without a published group there is nothing to prefill: the table has no row for "no answer".
    func testWithoutAGroupNothingIsPrefilled() {
        XCTAssertEqual(ReferenceGoalPrefill.goals(for: nil, existingGoalKeys: []), [])
    }

    /// Every vitamin and mineral the table covers for the group, except A, D and E, at its RDA or AI and in
    /// the reference's own unit. Fails if a value, a unit or a nutrient differs from the table.
    func testEveryCoveredNutrientIsPrefilledAtItsReference() {
        let goals = ReferenceGoalPrefill.goals(for: men31, existingGoalKeys: [])
        let expected = ReferenceIntakes.intakes(for: men31)
            .filter { !["vitaminA", "vitaminD", "vitaminE"].contains($0.nutrient) }
            .map { NutrientGoal(nutrient: $0.nutrient, target: $0.amount, unit: $0.unit) }
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(goals, expected)
    }

    /// Vitamins A, D and E stay off the prefill, as they stay off the one-row hint: a label may state them
    /// in IU, which a goal in mcg or mg can't be compared with.
    func testVitaminsStatedInIUAreNeverPrefilled() {
        let keys = Set(ReferenceGoalPrefill.goals(for: men31, existingGoalKeys: []).map(\.nutrient))
        XCTAssertTrue(keys.isDisjoint(with: ["vitaminA", "vitaminD", "vitaminE"]))
    }

    /// Chloride and the macronutrients are not in the reference table (their values by age and sex were not
    /// verified), so they are never prefilled.
    func testKeysOutsideTheTableAreNeverPrefilled() {
        let keys = Set(ReferenceGoalPrefill.goals(for: men31, existingGoalKeys: []).map(\.nutrient))
        XCTAssertTrue(keys.isDisjoint(with: ["chloride", "sodium", "protein", "fat", "carbohydrate", "fiber", "water"]))
    }

    /// A nutrient that already has a goal is left out, so a number the person set is never overwritten.
    func testANutrientWithAGoalIsLeftOut() {
        let keys = Set(ReferenceGoalPrefill.goals(for: men31, existingGoalKeys: ["iron", "zinc"]).map(\.nutrient))
        XCTAssertFalse(keys.contains("iron"))
        XCTAssertFalse(keys.contains("zinc"))
        XCTAssertTrue(keys.contains("calcium"))
    }

    /// A goal kept under an alias of the nutrient (a label's `vitamin-c`) is a goal for it too.
    func testAGoalUnderAnAliasCountsAsAGoal() {
        let alias = "vitamin-c"
        XCTAssertEqual(HealthKitWritePlanner.canonicalKey(for: alias), "vitaminC", "the alias this test relies on")
        let keys = Set(ReferenceGoalPrefill.goals(for: men31, existingGoalKeys: [alias]).map(\.nutrient))
        XCTAssertFalse(keys.contains("vitaminC"))
    }

    /// The group's own row is used: pregnancy gets the pregnancy values, not the women's.
    func testThePregnancyGroupGetsThePregnancyValues() throws {
        let pregnancy = try XCTUnwrap(ReferenceGroup(lifeStage: .pregnancy, ageBand: .years19To30))
        let iron = ReferenceGoalPrefill.goals(for: pregnancy, existingGoalKeys: []).first { $0.nutrient == "iron" }
        XCTAssertEqual(iron?.target, ReferenceIntakes.intake(for: "iron", group: pregnancy)?.amount)
        XCTAssertEqual(iron?.target, Decimal(27))
    }
}
