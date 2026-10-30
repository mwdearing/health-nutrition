import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A goal store that also keeps the weight plan, and can refuse the plan write while goal writes go through.
final class GoalSetupPlanStore: GoalStore, WeightPlanStore, @unchecked Sendable {
    private struct Refused: Error {}

    private let lock = NSLock()
    private var stored: [String: NutrientGoal] = [:]
    private var plan: WeightPlan?
    private let refusesPlanWrites: Bool
    private(set) var planWrites = 0

    init(goals: [NutrientGoal] = [], plan: WeightPlan? = nil, refusesPlanWrites: Bool = false) {
        for goal in goals { stored[goal.nutrient] = goal }
        self.plan = plan
        self.refusesPlanWrites = refusesPlanWrites
    }

    func goals() throws -> [NutrientGoal] {
        lock.withLock { stored.values.sorted { $0.nutrient < $1.nutrient } }
    }

    func goal(for nutrient: String) throws -> NutrientGoal? {
        lock.withLock { stored[nutrient] }
    }

    func setGoal(_ goal: NutrientGoal) throws {
        try goal.validate()
        lock.withLock { stored[goal.nutrient] = goal }
    }

    func removeGoal(nutrient: String) throws {
        lock.withLock { _ = stored.removeValue(forKey: nutrient) }
    }

    func close() {}

    func weightPlan() throws -> WeightPlan? {
        lock.withLock { plan }
    }

    func setWeightPlan(_ plan: WeightPlan) throws {
        try lock.withLock {
            planWrites += 1
            if refusesPlanWrites { throw Refused() }
            try plan.validate()
            self.plan = plan
        }
    }

    func removeWeightPlan() throws {
        try lock.withLock {
            planWrites += 1
            if refusesPlanWrites { throw Refused() }
            plan = nil
        }
    }
}

/// Goal setup asks for a goal weight when losing or gaining, and saves the weight plan after the targets.
@MainActor
final class GoalSetupWeightPlanTests: XCTestCase {
    private func makeModel(
        system: UnitSystem = .metric, store: GoalStore
    ) -> GoalSetupViewModel {
        let goals = GoalsViewModel(store: store, preferences: InMemoryDisplayPreferences(unitSystem: system))
        goals.load()
        return GoalSetupViewModel(goals: goals)
    }

    private func kg(_ text: String) -> Decimal { Decimal(string: text)! }

    /// A man of 30, 180 cm and 80 kg (5 ft 11 in and 176 lb), moderately active.
    private func answer(_ model: GoalSetupViewModel, aim: GoalAim, system: UnitSystem = .metric) {
        model.aim = aim
        model.sex = .male
        model.ageText = "30"
        if system == .usCustomary {
            model.heightFeetText = "5"
            model.heightInchesText = "11"
            model.weightPoundsText = "176"
        } else {
            model.heightCentimetersText = "180"
            model.weightKilogramsText = "80"
        }
        model.activity = .moderate
    }

    private func walk(_ model: GoalSetupViewModel, to target: GoalSetupStep) {
        var moves = 0
        while model.step != target, model.canGoNext, moves < 10 {
            model.next()
            moves += 1
        }
    }

    func testLosingSavesTheTargetsAndThenThePlan() throws {
        let store = GoalSetupPlanStore()
        let model = makeModel(store: store)
        answer(model, aim: .lose)
        walk(model, to: .pace)
        XCTAssertEqual(model.step, .pace)
        model.selectedPaceKilograms = model.paceOptions[1].kilogramsPerWeek
        model.goalWeightKilogramsText = "75"
        walk(model, to: .results)
        XCTAssertEqual(model.step, .results)

        XCTAssertTrue(model.save())

        XCTAssertEqual(try store.weightPlan(), WeightPlan(aim: .lose, goalKilograms: 75, weeklyPaceKilograms: kg("0.5")))
        XCTAssertEqual(try store.goals().count, GoalSetupViewModel.targetKeys.count)
        XCTAssertEqual(store.planWrites, 1)
    }

    func testGainingInPoundsStoresExactKilograms() throws {
        let store = GoalSetupPlanStore()
        let model = makeModel(system: .usCustomary, store: store)
        answer(model, aim: .gain, system: .usCustomary)
        walk(model, to: .pace)
        model.selectedPaceKilograms = model.paceOptions[1].kilogramsPerWeek
        model.goalWeightPoundsText = "185"
        walk(model, to: .results)

        XCTAssertTrue(model.save())

        // 185 lb * 0.45359237 = 83.91458845 kg; 1 lb a week = 0.45359237 kg.
        XCTAssertEqual(
            try store.weightPlan(),
            WeightPlan(aim: .gain, goalKilograms: kg("83.91458845"), weeklyPaceKilograms: kg("0.45359237")))
    }

    func testThePaceStepNeedsAGoalWeightInRangeAndInTheAimsDirection() {
        let model = makeModel(store: GoalSetupPlanStore())
        answer(model, aim: .lose)
        walk(model, to: .pace)
        model.selectedPaceKilograms = model.paceOptions[1].kilogramsPerWeek

        XCTAssertFalse(model.canGoNext)
        XCTAssertNil(model.goalWeightNotice)

        model.goalWeightKilogramsText = "29"
        XCTAssertFalse(model.canGoNext)
        XCTAssertEqual(model.goalWeightNotice, "Check your goal weight. It must be between 30 and 300 kg.")

        model.goalWeightKilogramsText = "80"
        XCTAssertFalse(model.canGoNext)
        XCTAssertEqual(model.goalWeightNotice, GoalSetupViewModel.goalWeightBelowNotice)

        model.goalWeightKilogramsText = "75"
        XCTAssertTrue(model.canGoNext)
        XCTAssertNil(model.goalWeightNotice)

        model.selectedPaceKilograms = nil
        XCTAssertFalse(model.canGoNext)

        model.selectedPaceKilograms = model.paceOptions[1].kilogramsPerWeek
        model.aim = .gain
        XCTAssertFalse(model.canGoNext)
        XCTAssertEqual(model.goalWeightNotice, GoalSetupViewModel.goalWeightAboveNotice)
    }

    func testTheRangeNoticeUsesPounds() {
        let model = makeModel(system: .usCustomary, store: GoalSetupPlanStore())
        answer(model, aim: .lose, system: .usCustomary)
        walk(model, to: .pace)
        model.goalWeightPoundsText = "700"
        XCTAssertEqual(model.goalWeightNotice, "Check your goal weight. It must be between 67 and 661 lb.")
    }

    func testDirectionNoticesAreFixedSentences() {
        XCTAssertEqual(GoalSetupViewModel.goalWeightBelowNotice, "To lose weight, your goal weight must be below your current weight.")
        XCTAssertEqual(GoalSetupViewModel.goalWeightAboveNotice, "To gain weight, your goal weight must be above your current weight.")
    }

    func testMaintainingSavesAnAimOnlyPlanAndIgnoresATypedGoal() throws {
        let store = GoalSetupPlanStore()
        let model = makeModel(store: store)
        answer(model, aim: .lose)
        model.goalWeightKilogramsText = "75"
        model.aim = .maintain
        walk(model, to: .results)
        XCTAssertEqual(model.step, .results)

        XCTAssertTrue(model.save())

        XCTAssertEqual(try store.weightPlan(), WeightPlan(aim: .maintain, goalKilograms: nil, weeklyPaceKilograms: nil))
    }

    func testJustTrackingLeavesAStoredPlanUntouched() throws {
        let stored = WeightPlan(aim: .lose, goalKilograms: 75, weeklyPaceKilograms: kg("0.5"))
        let store = GoalSetupPlanStore(plan: stored)
        let model = makeModel(store: store)
        model.aim = .justTrack
        model.next()

        XCTAssertFalse(model.save())

        XCTAssertEqual(try store.weightPlan(), stored)
        XCTAssertEqual(store.planWrites, 0)
    }

    func testAFailedPlanWritePutsTheTargetsBack() throws {
        let store = GoalSetupPlanStore(
            goals: [
                NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal),
                NutrientGoal(nutrient: "protein", target: 100, unit: .g),
            ],
            refusesPlanWrites: true)
        let model = makeModel(store: store)
        answer(model, aim: .lose)
        walk(model, to: .pace)
        model.selectedPaceKilograms = model.paceOptions[1].kilogramsPerWeek
        model.goalWeightKilogramsText = "75"
        walk(model, to: .results)

        XCTAssertFalse(model.save())

        XCTAssertEqual(model.resultError, GoalSetupViewModel.saveFailedNotice)
        XCTAssertEqual(try store.goal(for: "energy"), NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal))
        XCTAssertEqual(try store.goal(for: "protein"), NutrientGoal(nutrient: "protein", target: 100, unit: .g))
        XCTAssertNil(try store.goal(for: "carbohydrate"))
        XCTAssertNil(try store.weightPlan())
    }

    func testAFailedPlanWriteRestoresATargetThatAnEmptyDraftRemoved() throws {
        let store = GoalSetupPlanStore(
            goals: [
                NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal),
                NutrientGoal(nutrient: "protein", target: 100, unit: .g),
            ],
            refusesPlanWrites: true)
        let model = makeModel(store: store)
        answer(model, aim: .lose)
        walk(model, to: .pace)
        model.selectedPaceKilograms = model.paceOptions[1].kilogramsPerWeek
        model.goalWeightKilogramsText = "75"
        walk(model, to: .results)
        model.draftTargets["energy"] = ""

        XCTAssertFalse(model.save())

        XCTAssertEqual(model.resultError, GoalSetupViewModel.saveFailedNotice)
        XCTAssertEqual(try store.goal(for: "energy"), NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal))
        XCTAssertEqual(try store.goal(for: "protein"), NutrientGoal(nutrient: "protein", target: 100, unit: .g))
        XCTAssertNil(try store.weightPlan())
    }

    func testSaveChecksTheGoalAgainstTheWeightAsItNowReads() throws {
        let store = GoalSetupPlanStore()
        let model = makeModel(store: store)
        answer(model, aim: .lose)
        walk(model, to: .pace)
        model.selectedPaceKilograms = model.paceOptions[1].kilogramsPerWeek
        model.goalWeightKilogramsText = "75"
        walk(model, to: .results)
        model.weightKilogramsText = "70"

        XCTAssertFalse(model.save())

        XCTAssertEqual(model.resultError, GoalSetupViewModel.goalWeightBelowNotice)
        XCTAssertEqual(try store.goals(), [])
        XCTAssertEqual(store.planWrites, 0)
    }

    func testWithoutAPlanStoreTheTargetsStillSave() throws {
        let store = InMemoryGoalStore(goals: [])
        let model = makeModel(store: store)
        answer(model, aim: .lose)
        walk(model, to: .pace)
        model.selectedPaceKilograms = model.paceOptions[1].kilogramsPerWeek
        model.goalWeightKilogramsText = "75"
        walk(model, to: .results)

        XCTAssertTrue(model.save())

        XCTAssertEqual(try store.goals().count, GoalSetupViewModel.targetKeys.count)
    }

    func testClosingTheSheetClearsTheGoalWeight() {
        let model = makeModel(store: GoalSetupPlanStore())
        model.goalWeightKilogramsText = "75"
        model.goalWeightPoundsText = "165"

        model.clearAnswers()

        XCTAssertEqual(model.goalWeightKilogramsText, "")
        XCTAssertEqual(model.goalWeightPoundsText, "")
    }

    func testSwitchingToPoundsConvertsTheTypedGoalWeightAndSaveKeepsTheGoal() throws {
        let prefs = InMemoryDisplayPreferences(unitSystem: .metric)
        let store = GoalSetupPlanStore()
        let goals = GoalsViewModel(store: store, preferences: prefs)
        goals.load()
        let model = GoalSetupViewModel(goals: goals)
        answer(model, aim: .lose)
        walk(model, to: .pace)
        model.goalWeightKilogramsText = "75"

        prefs.setUnitSystem(.usCustomary)
        model.unitSystemDidChange()

        XCTAssertEqual(model.goalWeightPoundsText, BodyActivityViewModel.oneDecimal(kg("75") / kg("0.45359237")))
        XCTAssertEqual(model.weightPoundsText, BodyActivityViewModel.oneDecimal(kg("80") / kg("0.45359237")))
        let pace = model.paceOptions[1].kilogramsPerWeek
        model.selectedPaceKilograms = pace
        walk(model, to: .results)
        XCTAssertEqual(model.step, .results)

        XCTAssertTrue(model.save())

        XCTAssertEqual(
            try store.weightPlan(),
            WeightPlan(aim: .lose, goalKilograms: 75, weeklyPaceKilograms: pace))
    }

    func testSwitchingToKilogramsConvertsTheTypedGoalWeightAndSaveKeepsTheGoal() throws {
        let prefs = InMemoryDisplayPreferences(unitSystem: .usCustomary)
        let store = GoalSetupPlanStore()
        let goals = GoalsViewModel(store: store, preferences: prefs)
        goals.load()
        let model = GoalSetupViewModel(goals: goals)
        answer(model, aim: .lose, system: .usCustomary)
        walk(model, to: .pace)
        model.goalWeightPoundsText = "165"

        prefs.setUnitSystem(.metric)
        model.unitSystemDidChange()

        XCTAssertEqual(model.goalWeightKilogramsText, BodyActivityViewModel.oneDecimal(kg("165") * kg("0.45359237")))
        model.selectedPaceKilograms = model.paceOptions[1].kilogramsPerWeek
        walk(model, to: .results)
        XCTAssertEqual(model.step, .results)

        XCTAssertTrue(model.save())

        XCTAssertEqual(
            try store.weightPlan(),
            WeightPlan(aim: .lose, goalKilograms: kg("74.84274105"), weeklyPaceKilograms: kg("0.5")))
    }

    func testSwitchingToImperialConvertsTheHeightKeepsThePaceAndSaves() throws {
        let prefs = InMemoryDisplayPreferences(unitSystem: .metric)
        let store = GoalSetupPlanStore()
        let goals = GoalsViewModel(store: store, preferences: prefs)
        goals.load()
        let model = GoalSetupViewModel(goals: goals)
        answer(model, aim: .lose)
        walk(model, to: .pace)
        model.selectedPaceKilograms = model.paceOptions[1].kilogramsPerWeek
        model.goalWeightKilogramsText = "75"

        prefs.setUnitSystem(.usCustomary)
        model.unitSystemDidChange()

        // 180 cm is 70.87 in, shown as 71 in: 5 ft 11 in.
        XCTAssertEqual(model.heightFeetText, DecimalFormatting.text(Decimal(5)))
        XCTAssertEqual(model.heightInchesText, DecimalFormatting.text(Decimal(11)))
        // The pace is the same option in pounds: 1 lb a week is the second option.
        XCTAssertEqual(model.selectedPaceKilograms, model.paceOptions[1].kilogramsPerWeek)
        // The exact 180 cm is kept behind the converted text, so the profile is not the rounded inches.
        XCTAssertEqual(model.makeProfile()?.heightCentimeters, kg("180"))
        walk(model, to: .results)
        XCTAssertEqual(model.step, .results)

        XCTAssertTrue(model.save())

        XCTAssertEqual(
            try store.weightPlan(),
            WeightPlan(aim: .lose, goalKilograms: 75, weeklyPaceKilograms: model.paceOptions[1].kilogramsPerWeek))
    }

    func testSwitchingToMetricConvertsTheHeightKeepsThePaceAndSaves() throws {
        let prefs = InMemoryDisplayPreferences(unitSystem: .usCustomary)
        let store = GoalSetupPlanStore()
        let goals = GoalsViewModel(store: store, preferences: prefs)
        goals.load()
        let model = GoalSetupViewModel(goals: goals)
        answer(model, aim: .lose, system: .usCustomary)
        walk(model, to: .pace)
        model.selectedPaceKilograms = model.paceOptions[1].kilogramsPerWeek
        model.goalWeightPoundsText = "165"

        prefs.setUnitSystem(.metric)
        model.unitSystemDidChange()

        // 5 ft 11 in is 180.34 cm, shown as 180 cm.
        XCTAssertEqual(model.heightCentimetersText, DecimalFormatting.text(Decimal(180)))
        // The pace is the same option in kilograms: 0.5 kg a week is the second option.
        XCTAssertEqual(model.selectedPaceKilograms, model.paceOptions[1].kilogramsPerWeek)
        // The exact 180.34 cm is kept behind the converted text.
        XCTAssertEqual(model.makeProfile()?.heightCentimeters, kg("180.34"))
        walk(model, to: .results)
        XCTAssertEqual(model.step, .results)

        XCTAssertTrue(model.save())

        XCTAssertEqual(
            try store.weightPlan(),
            WeightPlan(aim: .lose, goalKilograms: kg("74.84274105"), weeklyPaceKilograms: model.paceOptions[1].kilogramsPerWeek))
    }

    func testAUnitSwitchAtResultsRefreshesTheTargetsForTheNewPace() throws {
        let prefs = InMemoryDisplayPreferences(unitSystem: .metric)
        let store = GoalSetupPlanStore()
        let goals = GoalsViewModel(store: store, preferences: prefs)
        goals.load()
        let model = GoalSetupViewModel(goals: goals)
        answer(model, aim: .lose)
        walk(model, to: .pace)
        model.selectedPaceKilograms = model.paceOptions[1].kilogramsPerWeek
        model.goalWeightKilogramsText = "75"
        walk(model, to: .results)
        let before = model.draftTargets

        prefs.setUnitSystem(.usCustomary)
        model.unitSystemDidChange()

        // 0.5 kg a week becomes the nearest pound option, 1 lb a week, 0.45359237 kg.
        let pace = kg("0.45359237")
        XCTAssertEqual(model.selectedPaceKilograms, pace)
        // A second model walked to the results with the same answers and the same pace.
        let fresh = makeModel(store: GoalSetupPlanStore())
        answer(fresh, aim: .lose)
        walk(fresh, to: .pace)
        fresh.selectedPaceKilograms = pace
        fresh.goalWeightKilogramsText = "75"
        walk(fresh, to: .results)

        XCTAssertNotEqual(before, fresh.draftTargets)
        XCTAssertEqual(model.draftTargets, fresh.draftTargets)
        XCTAssertEqual(model.adjustmentNote, fresh.adjustmentNote)

        XCTAssertTrue(model.save())

        XCTAssertEqual(try store.weightPlan(), WeightPlan(aim: .lose, goalKilograms: 75, weeklyPaceKilograms: pace))
        XCTAssertEqual(try store.goal(for: "energy")?.target, kg(fresh.draftTargets["energy"]!))
        XCTAssertEqual(try store.goal(for: "protein")?.target, kg(fresh.draftTargets["protein"]!))
    }

    func testAUnitSwitchAtResultsKeepsATargetThePersonEdited() {
        let prefs = InMemoryDisplayPreferences(unitSystem: .metric)
        let goals = GoalsViewModel(store: GoalSetupPlanStore(), preferences: prefs)
        goals.load()
        let model = GoalSetupViewModel(goals: goals)
        answer(model, aim: .lose)
        walk(model, to: .pace)
        model.selectedPaceKilograms = model.paceOptions[1].kilogramsPerWeek
        model.goalWeightKilogramsText = "75"
        walk(model, to: .results)
        let before = model.draftTargets
        model.draftTargets["energy"] = "2100"

        prefs.setUnitSystem(.usCustomary)
        model.unitSystemDidChange()

        XCTAssertEqual(model.draftTargets["energy"], "2100")
        // The targets the person did not edit are estimated again for the new pace.
        let refreshed = model.draftTargets.filter { $0.key != "energy" }
        XCTAssertNotEqual(refreshed, before.filter { $0.key != "energy" })
    }

    func testAUnitSwitchKeepsWeightAndHeightTextThatIsNotANumber() {
        let prefs = InMemoryDisplayPreferences(unitSystem: .metric)
        let goals = GoalsViewModel(store: GoalSetupPlanStore(), preferences: prefs)
        goals.load()
        let model = GoalSetupViewModel(goals: goals)
        model.weightKilogramsText = "7o"
        model.goalWeightKilogramsText = "6o"
        model.heightCentimetersText = "18o"

        prefs.setUnitSystem(.usCustomary)
        model.unitSystemDidChange()

        XCTAssertEqual(model.weightPoundsText, "7o")
        XCTAssertEqual(model.goalWeightPoundsText, "6o")
        XCTAssertEqual(model.heightFeetText, "18o")
        XCTAssertEqual(model.heightInchesText, "")

        model.heightFeetText = "5"
        model.heightInchesText = "1x"
        prefs.setUnitSystem(.metric)
        model.unitSystemDidChange()

        XCTAssertEqual(model.weightKilogramsText, "7o")
        XCTAssertEqual(model.goalWeightKilogramsText, "6o")
        XCTAssertEqual(model.heightCentimetersText, "5 1x")
    }

    func testAUnitSwitchAtResultsKeepsTheNoticeOnAnEditedTarget() {
        let prefs = InMemoryDisplayPreferences(unitSystem: .metric)
        let goals = GoalsViewModel(store: GoalSetupPlanStore(), preferences: prefs)
        goals.load()
        let model = GoalSetupViewModel(goals: goals)
        answer(model, aim: .lose)
        walk(model, to: .pace)
        model.selectedPaceKilograms = model.paceOptions[1].kilogramsPerWeek
        model.goalWeightKilogramsText = "75"
        walk(model, to: .results)
        model.draftTargets["energy"] = "-5"
        XCTAssertFalse(model.save())
        let fieldNotice = model.fieldErrors["energy"]
        XCTAssertNotNil(fieldNotice)
        XCTAssertEqual(model.resultError, "Enter a number above zero.")

        prefs.setUnitSystem(.usCustomary)
        model.unitSystemDidChange()

        XCTAssertEqual(model.draftTargets["energy"], "-5")
        XCTAssertEqual(model.fieldErrors["energy"], fieldNotice)
        XCTAssertEqual(model.resultError, "Enter a number above zero.")
    }

    func testThePrivacyNoticeSaysWhatIsSaved() {
        XCTAssertEqual(
            GoalSetupViewModel.privacyNotice,
            "Your age, sex, height and current weight stay on this device and are not saved. Your aim, pace and goal weight are saved on this device with the targets you choose.")
    }
}
