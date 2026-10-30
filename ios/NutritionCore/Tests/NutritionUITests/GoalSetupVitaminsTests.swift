import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Goal setup's vitamins and minerals choice: "Use recommended amounts" saves the reference values for the
/// person's age and sex, and "Set my own" offers the same values prefilled to edit.
@MainActor
final class GoalSetupVitaminsTests: XCTestCase {
    private func makeModel(goals: [NutrientGoal] = [], loadRows: Bool = true) -> (GoalSetupViewModel, InMemoryGoalStore) {
        let store = InMemoryGoalStore(goals: goals)
        let goalsModel = GoalsViewModel(store: store, preferences: InMemoryDisplayPreferences(unitSystem: .metric))
        if loadRows { goalsModel.load() }
        return (GoalSetupViewModel(goals: goalsModel), store)
    }

    /// A man of 35, 180 cm and 80 kg, moderately active, aiming to maintain, at the results.
    private func manAtResults(_ model: GoalSetupViewModel, age: String = "35", sex: GoalSex = .male) {
        model.aim = .maintain
        model.sex = sex
        model.ageText = age
        model.heightCentimetersText = "180"
        model.weightKilogramsText = "80"
        model.activity = .moderate
        model.next()
        model.next()
        model.next()
        model.next()
        XCTAssertEqual(model.step, .results)
    }

    private func saved(_ store: InMemoryGoalStore) throws -> [String: NutrientGoal] {
        Dictionary(uniqueKeysWithValues: try store.goals().map { ($0.nutrient, $0) })
    }

    func testTheReferenceGroupComesFromTheAnswers() {
        let (model, _) = makeModel()
        model.sex = .male
        model.ageText = "35"
        XCTAssertEqual(model.referenceGroup, ReferenceGroup(sex: .male, ageBand: .years31To50))
        model.sex = .female
        model.ageText = "18"
        XCTAssertEqual(model.referenceGroup, ReferenceGroup(sex: .female, ageBand: .years14To18))
        model.sex = .unspecified
        XCTAssertNil(model.referenceGroup)
    }

    /// The approved wording: the group in lower case, then the reassurance.
    func testThePrefillNoticeNamesTheGroup() {
        let (model, _) = makeModel()
        model.sex = .male
        model.ageText = "35"
        XCTAssertEqual(model.vitaminPrefillNotice, "Prefilled for men 31 to 50. You can change any of them.")
        model.sex = .unspecified
        XCTAssertNil(model.vitaminPrefillNotice)
        XCTAssertEqual(GoalSetupViewModel.vitaminNoGroupNotice, "Add your age and sex to prefill these.")
        XCTAssertEqual(GoalSetupViewModel.vitaminRecommendedTitle, "Use recommended amounts")
        XCTAssertEqual(GoalSetupViewModel.vitaminOwnTitle, "Set my own")
        XCTAssertEqual(
            GoalSetupViewModel.vitaminSourceNotice,
            "From the Dietary Reference Intakes (NIH). Vitamins A, D and E are yours to set, since labels often list them in IU.")
    }

    /// The request for age and sex shows only when one is missing; "unspecified" is an answer, so it shows nothing.
    func testTheNoGroupNoticeShowsOnlyWhenAnAnswerIsMissing() {
        let (model, _) = makeModel()
        XCTAssertTrue(model.vitaminShowsNoGroupNotice)
        model.sex = .unspecified
        model.ageText = "35"
        XCTAssertFalse(model.vitaminShowsNoGroupNotice)
        XCTAssertNil(model.vitaminPrefillNotice)
        model.sex = .male
        XCTAssertFalse(model.vitaminShowsNoGroupNotice)
        model.ageText = ""
        XCTAssertTrue(model.vitaminShowsNoGroupNotice)
    }

    /// With every covered vitamin and mineral already set there is nothing to prefill, so no notice is given.
    func testNothingToPrefillGivesNoNotice() {
        let men35 = ReferenceGroup(sex: .male, ageBand: .years31To50)
        let all = ReferenceGoalPrefill.goals(for: men35, existingGoalKeys: [])
        let (model, _) = makeModel(goals: all)
        model.sex = .male
        model.ageText = "35"
        XCTAssertEqual(model.vitaminPrefill, [])
        XCTAssertNil(model.vitaminPrefillNotice)
    }

    /// Without a choice, saving writes the big three and nothing for vitamins or minerals.
    func testWithoutAChoiceNoVitaminGoalIsSaved() throws {
        let (model, store) = makeModel()
        manAtResults(model)
        XCTAssertTrue(model.save())
        let goals = try saved(store)
        XCTAssertNil(goals["iron"])
        XCTAssertNotNil(goals["protein"])
    }

    /// "Use recommended amounts" saves each prefilled reference value: iron 8 mg for a man of 35.
    func testRecommendedAmountsAreSaved() throws {
        let (model, store) = makeModel()
        manAtResults(model)
        model.chooseVitamins(.recommended)
        XCTAssertTrue(model.save())
        let goals = try saved(store)
        XCTAssertEqual(goals["iron"]?.target, 8)
        XCTAssertEqual(goals["iron"]?.unit, .mg)
        XCTAssertEqual(goals["calcium"]?.target, 1000)
        XCTAssertNil(goals["vitaminD"], "vitamins A, D and E are left for the person to set")
    }

    /// An 18-year-old gets the 14 to 18 values: women's iron is 15 mg.
    func testAnEighteenYearOldGetsTheTeenValues() throws {
        let (model, store) = makeModel()
        manAtResults(model, age: "18", sex: .female)
        model.chooseVitamins(.recommended)
        XCTAssertTrue(model.save())
        XCTAssertEqual(try saved(store)["iron"]?.target, 15)
    }

    /// A goal already set is never overwritten.
    func testAnExistingGoalIsKept() throws {
        let (model, store) = makeModel(goals: [NutrientGoal(nutrient: "iron", target: 20, unit: .mg)])
        manAtResults(model)
        model.chooseVitamins(.recommended)
        XCTAssertTrue(model.save())
        XCTAssertEqual(try saved(store)["iron"]?.target, 20)
    }

    /// A goal in the store is neither offered nor overwritten even when the Goals screen's rows never loaded.
    func testAStoredGoalIsKeptWhenTheRowsDidNotLoad() throws {
        let (model, store) = makeModel(goals: [NutrientGoal(nutrient: "iron", target: 20, unit: .mg)], loadRows: false)
        manAtResults(model)
        XCTAssertFalse(model.vitaminPrefill.contains { $0.nutrient == "iron" }, "the store check hides it")
        model.chooseVitamins(.recommended)
        XCTAssertTrue(model.save())
        XCTAssertEqual(try saved(store)["iron"]?.target, 20)
        XCTAssertEqual(try saved(store)["calcium"]?.target, 1000)
    }

    /// A goal kept under an alias (`vitamin-c`) counts for the nutrient, with or without the rows loaded.
    func testAGoalUnderAnAliasIsNeitherOfferedNorDuplicated() throws {
        let (model, store) = makeModel(
            goals: [NutrientGoal(nutrient: "vitamin-c", target: 500, unit: .mg)], loadRows: false)
        manAtResults(model)
        XCTAssertFalse(model.vitaminPrefill.contains { $0.nutrient == "vitaminC" })
        model.chooseVitamins(.recommended)
        XCTAssertTrue(model.save())
        XCTAssertNil(try saved(store)["vitaminC"])
        XCTAssertEqual(try saved(store)["vitamin-c"]?.target, 500)
    }

    /// "Set my own" fills the fields with the reference values; an edited one is what is saved, and a
    /// cleared one saves nothing for that nutrient.
    func testOwnValuesArePrefilledAndEditable() throws {
        let (model, store) = makeModel()
        manAtResults(model)
        model.chooseVitamins(.own)
        XCTAssertEqual(model.vitaminDrafts["iron"], "8")
        model.vitaminDrafts["iron"] = "10"
        model.vitaminDrafts["zinc"] = ""
        XCTAssertTrue(model.save())
        let goals = try saved(store)
        XCTAssertEqual(goals["iron"]?.target, 10)
        XCTAssertNil(goals["zinc"])
        XCTAssertEqual(goals["calcium"]?.target, 1000)
    }

    /// A value that is not a number above zero stops the save, and nothing is written.
    func testAnInvalidOwnValueSavesNothing() throws {
        let (model, store) = makeModel()
        manAtResults(model)
        model.chooseVitamins(.own)
        model.vitaminDrafts["iron"] = "0"
        XCTAssertFalse(model.save())
        XCTAssertNotNil(model.fieldErrors["iron"])
        XCTAssertEqual(try store.goals(), [])
    }

    /// Closing the sheet clears the choice and the drafts.
    func testClearingTheAnswersClearsTheChoice() {
        let (model, _) = makeModel()
        manAtResults(model)
        model.chooseVitamins(.own)
        model.clearAnswers()
        XCTAssertNil(model.vitaminChoice)
        XCTAssertEqual(model.vitaminDrafts, [:])
    }
}
