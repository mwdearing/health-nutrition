import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A goal store that refuses writes for the keys in `refused`, so a test can fail one write of several.
private final class RefusingGoalStore: GoalStore, @unchecked Sendable {
    private let inner: InMemoryGoalStore
    var refused: Set<String> = []
    /// When set, the number of writes still allowed; every write after that is refused.
    var allowedWrites: Int?

    init(goals: [NutrientGoal]) {
        inner = InMemoryGoalStore(goals: goals)
    }

    private struct Refused: Error {}

    func goals() throws -> [NutrientGoal] { try inner.goals() }
    func goal(for nutrient: String) throws -> NutrientGoal? { try inner.goal(for: nutrient) }
    func setGoal(_ goal: NutrientGoal) throws {
        if refused.contains(goal.nutrient) { throw Refused() }
        if let allowed = allowedWrites {
            guard allowed > 0 else { throw Refused() }
            allowedWrites = allowed - 1
        }
        try inner.setGoal(goal)
    }
    /// Keys whose removal is refused.
    var refusedRemovals: Set<String> = []
    func removeGoal(nutrient: String) throws {
        if refusedRemovals.contains(nutrient) { throw Refused() }
        try inner.removeGoal(nutrient: nutrient)
    }
    func close() { inner.close() }
}

private func splitSuite() -> UserDefaults {
    let name = "healthnutrition.tests.macrosplit.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Gram goals set from percentages follow the energy goal while they are still that split's output.
/// Every figure is worked by hand: grams are energy times the share, over 4 kcal per gram for protein
/// and carbohydrate and 9 for fat, rounded plainly to whole grams.
@MainActor
final class MacroSplitFollowTests: XCTestCase {
    private func energyGoal(_ kcal: Decimal) -> NutrientGoal {
        NutrientGoal(nutrient: "energy", target: kcal, unit: .kcal)
    }

    private func grams(_ store: GoalStore) throws -> [Decimal?] {
        try ["protein", "carbohydrate", "fat"].map { try store.goal(for: $0)?.target }
    }

    /// A model with 30/40/30 applied to 2,000 kcal: 600/4 = 150 g, 800/4 = 200 g, 600/9 = 66.7 -> 67 g.
    private func appliedModel(
        _ store: GoalStore, preferences: InMemoryDisplayPreferences = InMemoryDisplayPreferences()
    ) throws -> GoalsViewModel {
        let model = GoalsViewModel(store: store, preferences: preferences)
        model.load()
        XCTAssertNil(model.applyMacroSplit(protein: "30", carbohydrate: "40", fat: "30"))
        XCTAssertEqual(try grams(store), [150, 200, 67])
        return model
    }

    private func commitEnergy(_ model: GoalsViewModel, _ text: String) {
        model.draftText["energy"] = text
        XCTAssertTrue(model.commitTarget(for: "energy"))
    }

    func testApplyingASplitStoresIt() throws {
        let preferences = InMemoryDisplayPreferences()
        let model = try appliedModel(InMemoryGoalStore(goals: [energyGoal(2000)]), preferences: preferences)
        XCTAssertEqual(
            preferences.macroSplit, try MacroSplit(proteinPercent: 30, carbohydratePercent: 40, fatPercent: 30))
        XCTAssertEqual(model.followedMacroSplit, preferences.macroSplit)
    }

    func testChangingTheEnergyGoalMovesTheGramGoals() throws {
        let store = InMemoryGoalStore(goals: [energyGoal(2000)])
        let model = try appliedModel(store)

        // 2,500 kcal: 750/4 = 187.5 -> 188 g, 1000/4 = 250 g, 750/9 = 83.3 -> 83 g.
        commitEnergy(model, "2500")

        XCTAssertEqual(try grams(store), [188, 250, 83])
        XCTAssertEqual(try store.goal(for: "protein")?.unit, .g)
        XCTAssertEqual(model.draftText["protein"], "188")
        XCTAssertEqual(model.draftText["fat"], "83")
        XCTAssertNotNil(model.followedMacroSplit)
        XCTAssertNil(model.errorMessage)
        // And again from there, so following does not stop after one change.
        commitEnergy(model, "2000")
        XCTAssertEqual(try grams(store), [150, 200, 67])
    }

    func testEditingAMacroByHandStopsFollowing() throws {
        let store = InMemoryGoalStore(goals: [energyGoal(2000)])
        let model = try appliedModel(store)
        model.draftText["protein"] = "160"
        XCTAssertTrue(model.commitTarget(for: "protein"))
        XCTAssertNil(model.followedMacroSplit)

        commitEnergy(model, "2500")
        XCTAssertEqual(try grams(store), [160, 200, 67])
    }

    func testLeavingAMacroFieldUnchangedKeepsFollowing() throws {
        let store = InMemoryGoalStore(goals: [energyGoal(2000)])
        let model = try appliedModel(store)
        // Focus leaving the field commits the same 150 g again.
        XCTAssertTrue(model.commitTarget(for: "protein"))
        XCTAssertNotNil(model.followedMacroSplit)
        commitEnergy(model, "2500")
        XCTAssertEqual(try grams(store), [188, 250, 83])
    }

    func testTheSetupEstimateStopsFollowing() throws {
        let store = InMemoryGoalStore(goals: [energyGoal(2000)])
        let model = try appliedModel(store)
        // The setup screen writes its estimate through `setTarget`, like any typed target.
        XCTAssertTrue(model.setTarget("120", for: "protein"))
        XCTAssertNil(model.followedMacroSplit)
    }

    func testRemovingTheEnergyGoalOrClearingAllStopsFollowing() throws {
        let removed = try appliedModel(InMemoryGoalStore(goals: [energyGoal(2000)]))
        removed.draftText["energy"] = ""
        XCTAssertTrue(removed.commitTarget(for: "energy"))
        XCTAssertNil(removed.followedMacroSplit)

        let cleared = try appliedModel(InMemoryGoalStore(goals: [energyGoal(2000)]))
        XCTAssertTrue(cleared.clearAllGoals())
        XCTAssertNil(cleared.followedMacroSplit)
    }

    func testGoalsChangedOutsideTheScreenAreNeverRescaled() throws {
        let store = InMemoryGoalStore(goals: [energyGoal(2000)])
        let model = try appliedModel(store)
        // Written straight to the store, so the split no longer describes the goals.
        try store.setGoal(NutrientGoal(nutrient: "protein", target: 170, unit: .g))

        commitEnergy(model, "2500")

        XCTAssertEqual(try grams(store), [170, 200, 67])
        XCTAssertNil(model.followedMacroSplit)
    }

    func testAnEnergyGoalTooSmallToShareOutLeavesTheGramsAndStopsFollowing() throws {
        let store = InMemoryGoalStore(goals: [energyGoal(2000)])
        let model = try appliedModel(store)
        // 1 kcal: 0.3/4 = 0.075 g of protein rounds to nothing.
        commitEnergy(model, "1")
        XCTAssertEqual(try grams(store), [150, 200, 67])
        XCTAssertNil(model.followedMacroSplit)
    }

    func testARefusedFollowWritePutsTheEarlierGoalsBackAndSaysSo() throws {
        let store = RefusingGoalStore(goals: [energyGoal(2000)])
        let model = try appliedModel(store)
        store.refused = ["fat"]

        commitEnergy(model, "2500")

        XCTAssertEqual(try store.goal(for: "energy"), energyGoal(2500))
        XCTAssertEqual(try grams(store), [150, 200, 67])
        XCTAssertNil(model.followedMacroSplit)
        XCTAssertEqual(model.errorMessage, GoalsViewModel.macroSplitFollowFailedMessage)
    }

    func testARefusedFollowWhoseRollbackAlsoFailsSaysTheGoalsMayBeMixed() throws {
        let store = RefusingGoalStore(goals: [energyGoal(2000)])
        let model = try appliedModel(store)
        // The energy goal and the protein and carbohydrate moves are written; fat and every put-back fail.
        store.allowedWrites = 3

        commitEnergy(model, "2500")

        XCTAssertEqual(try grams(store), [188, 250, 67])
        XCTAssertNil(model.followedMacroSplit)
        XCTAssertEqual(model.errorMessage, GoalsViewModel.macroSplitFollowRestoreFailedMessage)
        // The fields show what is stored, so leaving one cannot write an old value back over a new one.
        XCTAssertEqual(model.draftText["protein"], "188")
        XCTAssertEqual(model.draftText["carbohydrate"], "250")
        XCTAssertEqual(model.draftText["fat"], "67")
    }

    func testTypingTheSplitsGramsBackByHandResumesFollowing() throws {
        let store = InMemoryGoalStore(goals: [energyGoal(2000)])
        let model = try appliedModel(store)
        model.draftText["protein"] = "160"
        XCTAssertTrue(model.commitTarget(for: "protein"))
        XCTAssertNil(model.followedMacroSplit)
        // Following is decided from the goals: back at exactly the split's grams, they follow again.
        model.draftText["protein"] = "150"
        XCTAssertTrue(model.commitTarget(for: "protein"))
        XCTAssertNotNil(model.followedMacroSplit)
        commitEnergy(model, "2500")
        XCTAssertEqual(try grams(store), [188, 250, 83])
    }

    func testAClearAllThatFailsPartwayLeavesNothingToFollow() throws {
        let store = RefusingGoalStore(goals: [energyGoal(2000)])
        let preferences = InMemoryDisplayPreferences()
        let model = try appliedModel(store, preferences: preferences)
        // Goals are removed in key order: carbohydrate goes, then energy is refused.
        store.refusedRemovals = ["energy"]

        XCTAssertFalse(model.clearAllGoals())

        XCTAssertNil(preferences.macroSplit)
        XCTAssertNil(model.followedMacroSplit)
    }

    func testASetupSaveStopsFollowingWhenItsGramsDiffer() throws {
        let store = InMemoryGoalStore(goals: [energyGoal(2000)])
        let model = try appliedModel(store)
        let setup = GoalSetupViewModel(goals: model)
        setup.aim = .maintain
        setup.sex = .male
        setup.ageText = "30"
        setup.heightCentimetersText = "180"
        setup.weightKilogramsText = "80"
        setup.activity = .moderate
        setup.next(); setup.next(); setup.next(); setup.next()

        XCTAssertTrue(setup.save())

        XCTAssertNil(model.followedMacroSplit)
        let saved = try grams(store)
        // A later energy change on the Goals screen leaves the estimate's grams alone.
        commitEnergy(model, "3000")
        XCTAssertEqual(try grams(store), saved)
    }

    func testASetupSaveThatRollsBackKeepsFollowing() throws {
        let store = RefusingGoalStore(goals: [energyGoal(2000)])
        let model = try appliedModel(store)
        let setup = GoalSetupViewModel(goals: model)
        setup.aim = .maintain
        setup.sex = .male
        setup.ageText = "30"
        setup.heightCentimetersText = "180"
        setup.weightKilogramsText = "80"
        setup.activity = .moderate
        setup.next(); setup.next(); setup.next(); setup.next()
        // The estimate's energy and protein are written, then carbohydrate is refused and both are put back.
        store.refused = ["carbohydrate"]

        XCTAssertFalse(setup.save())

        XCTAssertEqual(try store.goal(for: "energy"), energyGoal(2000))
        XCTAssertEqual(try grams(store), [150, 200, 67])
        XCTAssertNotNil(model.followedMacroSplit)
    }

    func testAFailedApplyPutsBackTheSplitFollowedBefore() throws {
        let store = RefusingGoalStore(goals: [energyGoal(2000)])
        let model = try appliedModel(store)
        store.refused = ["fat"]

        XCTAssertNotNil(model.applyMacroSplit(protein: "25", carbohydrate: "45", fat: "30"))

        XCTAssertEqual(try grams(store), [150, 200, 67])
        XCTAssertEqual(
            model.followedMacroSplit, try MacroSplit(proteinPercent: 30, carbohydratePercent: 40, fatPercent: 30))
    }

    func testAnApplyStoppedBeforeWritingKeepsFollowing() throws {
        let store = RefusingGoalStore(goals: [energyGoal(2000)])
        let model = try appliedModel(store)
        // The energy edit the new split would be a share of cannot be saved, so nothing is written.
        model.draftText["energy"] = "2500"
        store.refused = ["energy"]

        XCTAssertNotNil(model.applyMacroSplit(protein: "25", carbohydrate: "45", fat: "30"))

        XCTAssertEqual(try store.goal(for: "energy"), energyGoal(2000))
        XCTAssertEqual(try grams(store), [150, 200, 67])
        XCTAssertEqual(
            model.followedMacroSplit, try MacroSplit(proteinPercent: 30, carbohydratePercent: 40, fatPercent: 30))
    }

    func testAnApplyThatSavedANewEnergyGoalBeforeFailingSaysTheEnergySaved() throws {
        let store = RefusingGoalStore(goals: [energyGoal(2000)])
        let model = try appliedModel(store)
        model.draftText["energy"] = "2500"
        store.refused = ["fat"]

        XCTAssertEqual(
            model.applyMacroSplit(protein: "25", carbohydrate: "45", fat: "30"),
            GoalsViewModel.macroSplitEnergySavedMessage)

        // The energy edit stays saved and the grams are put back, which 30/40/30 of 2,500 kcal no longer
        // describes, so following stops rather than claiming a split the goals do not match.
        XCTAssertEqual(try store.goal(for: "energy"), energyGoal(2500))
        XCTAssertEqual(try grams(store), [150, 200, 67])
        XCTAssertNil(model.followedMacroSplit)
    }

    func testASetupRollbackThatFailsDoesNotClaimTheGoalsFollow() throws {
        let store = RefusingGoalStore(goals: [energyGoal(2000)])
        let model = try appliedModel(store)
        let setup = GoalSetupViewModel(goals: model)
        setup.aim = .maintain
        setup.sex = .male
        setup.ageText = "30"
        setup.heightCentimetersText = "180"
        setup.weightKilogramsText = "80"
        setup.activity = .moderate
        setup.next(); setup.next(); setup.next(); setup.next()
        // The estimate's energy is written, protein is refused, and putting the energy back is refused too.
        store.allowedWrites = 1

        XCTAssertFalse(setup.save())

        // The estimate's energy stayed and the grams did not, so the split does not describe the goals.
        XCTAssertNil(model.followedMacroSplit)
    }

    func testAStoredSplitThatNoLongerDescribesTheGoalsIsNotReported() throws {
        let preferences = InMemoryDisplayPreferences()
        preferences.setMacroSplit(try MacroSplit(proteinPercent: 30, carbohydratePercent: 40, fatPercent: 30))
        let model = GoalsViewModel(store: InMemoryGoalStore(goals: [energyGoal(2000)]), preferences: preferences)
        model.load()
        XCTAssertNil(model.followedMacroSplit)
    }

    func testAFailedApplyStoresNoSplit() {
        let preferences = InMemoryDisplayPreferences()
        let model = GoalsViewModel(
            store: InMemoryGoalStore(goals: [energyGoal(2000)], refusesWrites: true), preferences: preferences)
        model.load()
        XCTAssertNotNil(model.applyMacroSplit(protein: "30", carbohydrate: "40", fat: "30"))
        XCTAssertNil(preferences.macroSplit)
    }

    func testTheSplitIsStoredAsOneKeyReadBackExactlyAndErased() throws {
        let defaults = splitSuite()
        let preferences = UserDefaultsDisplayPreferences(defaults: defaults)
        XCTAssertNil(preferences.macroSplit)
        let split = try MacroSplit(proteinPercent: Decimal(string: "27.5")!, carbohydratePercent: 45, fatPercent: Decimal(string: "27.5")!)
        preferences.setMacroSplit(split)
        XCTAssertEqual(defaults.string(forKey: "display.goals.macroSplit"), "27.5,45,27.5")
        XCTAssertEqual(UserDefaultsDisplayPreferences(defaults: defaults).macroSplit, split)
        preferences.resetToDefaults()
        XCTAssertNil(defaults.object(forKey: "display.goals.macroSplit"))
    }

    func testAStoredValueThatIsNotASplitReadsAsNone() {
        let defaults = splitSuite()
        let preferences = UserDefaultsDisplayPreferences(defaults: defaults)
        for text in ["", "30,40", "30,40,40", "a,b,c", "0,50,50", "30,40,30,0", "30x,40,30", ".5,50,49.5", "30.,40,30", "3 0,40,30"] {
            defaults.set(text, forKey: "display.goals.macroSplit")
            XCTAssertNil(preferences.macroSplit, text)
        }
    }

    func testTheSectionSaysWhetherTheGramsFollow() throws {
        XCTAssertEqual(
            MacroSplitCopy.followText(nil),
            "After you set them, the gram goals follow your energy goal when you change it here, "
                + "until you edit protein, carbohydrate or fat by hand.")
        XCTAssertEqual(
            MacroSplitCopy.followText(try MacroSplit(proteinPercent: 30, carbohydratePercent: 40, fatPercent: 30)),
            "Your gram goals follow your energy goal at protein 30%, carbohydrate 40%, fat 30%. "
                + "Editing one of them by hand stops this.")
    }
}
