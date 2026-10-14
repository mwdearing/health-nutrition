import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Macro targets set as percentages of the energy goal: they become ordinary gram goals, all three or
/// none, and only when there is an energy goal for them to be shares of.
@MainActor
final class MacroSplitGoalsTests: XCTestCase {
    private func energyGoal(_ kcal: Decimal) -> NutrientGoal {
        NutrientGoal(nutrient: "energy", target: kcal, unit: .kcal)
    }

    private func loadedModel(_ store: GoalStore) -> GoalsViewModel {
        let model = GoalsViewModel(store: store)
        model.load()
        return model
    }

    func testApplyingASplitWritesTheThreeGramGoals() throws {
        let store = InMemoryGoalStore(goals: [energyGoal(2000)])
        let model = loadedModel(store)

        XCTAssertNil(model.applyMacroSplit(protein: "30", carbohydrate: "40", fat: "30"))

        XCTAssertEqual(try store.goal(for: "protein"), NutrientGoal(nutrient: "protein", target: 150, unit: .g))
        XCTAssertEqual(
            try store.goal(for: "carbohydrate"), NutrientGoal(nutrient: "carbohydrate", target: 200, unit: .g))
        XCTAssertEqual(try store.goal(for: "fat"), NutrientGoal(nutrient: "fat", target: 67, unit: .g))
        XCTAssertEqual(try store.goal(for: "energy"), energyGoal(2000))
        XCTAssertEqual(model.rows.first { $0.nutrient == "protein" }?.targetText, "150 g")
        XCTAssertEqual(
            model.currentMacroPercents(), MacroSplit.Grams(protein: 30, carbohydrate: 40, fat: 30))
    }

    func testApplyingASplitReplacesTheInlineDraftsSoAStaleOneIsNotCommittedOverIt() throws {
        let store = InMemoryGoalStore(goals: [
            energyGoal(2000), NutrientGoal(nutrient: "protein", target: 500, unit: .mg),
        ])
        let model = loadedModel(store)
        XCTAssertEqual(model.draftText["protein"], "500")

        XCTAssertNil(model.applyMacroSplit(protein: "30", carbohydrate: "40", fat: "30"))
        XCTAssertEqual(model.draftText["protein"], "150")
        XCTAssertEqual(model.selectedUnits["protein"], .g)

        XCTAssertTrue(model.commitTarget(for: "protein"))
        XCTAssertEqual(try store.goal(for: "protein"), NutrientGoal(nutrient: "protein", target: 150, unit: .g))
    }

    func testAnEnergyEditNotYetSavedIsSavedAndUsedBeforeTheSplit() throws {
        let store = InMemoryGoalStore(goals: [energyGoal(2000)])
        let model = loadedModel(store)
        model.draftText["energy"] = "2500"

        // The preview is worked out from the same 2500 kcal the save then stores.
        XCTAssertEqual(
            model.macroSplitGrams(protein: "30", carbohydrate: "40", fat: "30"),
            .success(MacroSplit.Grams(protein: 188, carbohydrate: 250, fat: 83)))
        XCTAssertNil(model.applyMacroSplit(protein: "30", carbohydrate: "40", fat: "30"))

        // 750 / 4 = 187.5 -> 188, 1000 / 4 = 250, 750 / 9 = 83.33 -> 83
        XCTAssertEqual(try store.goal(for: "energy"), energyGoal(2500))
        XCTAssertEqual(try store.goal(for: "protein"), NutrientGoal(nutrient: "protein", target: 188, unit: .g))
        XCTAssertEqual(
            try store.goal(for: "carbohydrate"), NutrientGoal(nutrient: "carbohydrate", target: 250, unit: .g))
        XCTAssertEqual(try store.goal(for: "fat"), NutrientGoal(nutrient: "fat", target: 83, unit: .g))
    }

    func testAnInvalidEnergyEditStopsTheSplitAndWritesNothing() throws {
        let store = InMemoryGoalStore(goals: [energyGoal(2000)])
        let model = loadedModel(store)
        model.draftText["energy"] = "-1"

        XCTAssertEqual(model.macroSplitUnavailable(), .energyNotValid)
        XCTAssertEqual(
            model.applyMacroSplit(protein: "30", carbohydrate: "40", fat: "30"),
            MacroSplitProblem.energyNotValid.message)
        XCTAssertEqual(try store.goal(for: "energy"), energyGoal(2000))
        XCTAssertNil(try store.goal(for: "protein"))
    }

    func testWithoutAnEnergyGoalNothingIsWritten() throws {
        let store = InMemoryGoalStore()
        let model = loadedModel(store)

        XCTAssertNil(try model.macroSplitEnergyKcal())
        XCTAssertEqual(model.macroSplitUnavailable(), .needsEnergyGoal)
        XCTAssertEqual(
            model.applyMacroSplit(protein: "30", carbohydrate: "40", fat: "30"),
            MacroSplitProblem.needsEnergyGoal.message)
        XCTAssertEqual(try store.goals(), [])
        XCTAssertNil(model.currentMacroPercents())
    }

    func testPercentagesThatDoNotTotalHundredAreRefusedAndNothingChanges() throws {
        let protein = NutrientGoal(nutrient: "protein", target: 90, unit: .g)
        let store = InMemoryGoalStore(goals: [energyGoal(2000), protein])
        let model = loadedModel(store)

        XCTAssertEqual(
            model.applyMacroSplit(protein: "30", carbohydrate: "40", fat: "20"),
            MacroSplitProblem.notHundred(total: 90).message)
        XCTAssertEqual(
            model.macroSplitGrams(protein: "30", carbohydrate: "40", fat: "20"),
            .failure(.notHundred(total: 90)))
        XCTAssertEqual(try store.goal(for: "protein"), protein)
        XCTAssertNil(try store.goal(for: "fat"))
    }

    func testEmptyZeroOrWordedPercentagesAreRefused() {
        let model = loadedModel(InMemoryGoalStore(goals: [energyGoal(2000)]))

        XCTAssertEqual(model.macroSplitGrams(protein: "", carbohydrate: "60", fat: "40"), .failure(.notNumbers))
        XCTAssertEqual(model.macroSplitGrams(protein: "0", carbohydrate: "60", fat: "40"), .failure(.notNumbers))
        XCTAssertEqual(
            model.macroSplitGrams(protein: "thirty", carbohydrate: "40", fat: "30"), .failure(.notNumbers))
    }

    func testTheShareShownBackFollowsGramGoalsEditedByHand() throws {
        let store = InMemoryGoalStore(goals: [
            energyGoal(2000),
            NutrientGoal(nutrient: "protein", target: 100, unit: .g),
            NutrientGoal(nutrient: "carbohydrate", target: 250, unit: .g),
            NutrientGoal(nutrient: "fat", target: 50, unit: .g),
        ])
        let model = loadedModel(store)

        // 400 / 2000 = 20%, 1000 / 2000 = 50%, 450 / 2000 = 22.5% -> 23
        XCTAssertEqual(
            model.currentMacroPercents(), MacroSplit.Grams(protein: 20, carbohydrate: 50, fat: 23))
    }

    func testAnUnreadableStoreIsReportedAsAReadFailureNotAsAMissingEnergyGoal() {
        let model = GoalsViewModel(store: InMemoryGoalStore(goals: [energyGoal(2000)], failNextRead: true))

        XCTAssertThrowsError(try model.macroSplitEnergyKcal()) {
            XCTAssertEqual($0 as? MacroSplitProblem, .readFailed)
        }
        XCTAssertEqual(model.macroSplitUnavailable(), .readFailed)
        XCTAssertEqual(MacroSplitProblem.readFailed.message, GoalsViewModel.readFailedMessage)
        XCTAssertEqual(
            model.applyMacroSplit(protein: "30", carbohydrate: "40", fat: "30"),
            GoalsViewModel.readFailedMessage)
        XCTAssertNil(model.currentMacroPercents())
    }

    func testApplyingASplitClearsAnErrorARowShowedForEarlierText() {
        let model = loadedModel(InMemoryGoalStore(goals: [energyGoal(2000)]))
        model.draftText["fat"] = "-5"
        XCTAssertFalse(model.commitTarget(for: "fat"))
        XCTAssertNotNil(model.rowError["fat"])

        XCTAssertNil(model.applyMacroSplit(protein: "30", carbohydrate: "40", fat: "30"))

        XCTAssertNil(model.rowError["fat"])
        XCTAssertEqual(model.draftText["fat"], "67")
    }

    func testAStoreThatRefusesWritesReportsTheSaveFailure() {
        let model = GoalsViewModel(store: InMemoryGoalStore(goals: [energyGoal(2000)], refusesWrites: true))
        model.load()

        XCTAssertEqual(
            model.applyMacroSplit(protein: "30", carbohydrate: "40", fat: "30"),
            GoalsViewModel.saveFailedMessage)
        XCTAssertEqual(model.draftText["protein"], "")
    }
}
