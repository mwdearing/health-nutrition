import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A goal store that fails exactly one mutation, the third, and keeps working around it.
final class ThirdWriteFailingGoalStore: GoalStore, @unchecked Sendable {
    private struct WriteFailed: Error {}

    private let lock = NSLock()
    private var stored: [String: NutrientGoal] = [:]
    private var mutations = 0

    init(goals: [NutrientGoal]) {
        for goal in goals { stored[goal.nutrient] = goal }
    }

    func goals() throws -> [NutrientGoal] {
        lock.withLock { stored.values.sorted { $0.nutrient < $1.nutrient } }
    }

    func goal(for nutrient: String) throws -> NutrientGoal? {
        lock.withLock { stored[nutrient] }
    }

    func setGoal(_ goal: NutrientGoal) throws {
        try goal.validate()
        try mutate { stored[goal.nutrient] = goal }
    }

    func removeGoal(nutrient: String) throws {
        try mutate { _ = stored.removeValue(forKey: nutrient) }
    }

    func close() {}

    private func mutate(_ change: () -> Void) throws {
        try lock.withLock {
            mutations += 1
            if mutations == 3 { throw WriteFailed() }
            change()
        }
    }
}

/// A goal store that lets the first mutation through and refuses every later one, so a restore fails too.
final class FailsAfterFirstWriteGoalStore: GoalStore, @unchecked Sendable {
    private struct WriteFailed: Error {}

    private let lock = NSLock()
    private var stored: [String: NutrientGoal] = [:]
    private var mutations = 0

    init(goals: [NutrientGoal]) {
        for goal in goals { stored[goal.nutrient] = goal }
    }

    func goals() throws -> [NutrientGoal] {
        lock.withLock { stored.values.sorted { $0.nutrient < $1.nutrient } }
    }

    func goal(for nutrient: String) throws -> NutrientGoal? {
        lock.withLock { stored[nutrient] }
    }

    func setGoal(_ goal: NutrientGoal) throws {
        try goal.validate()
        try mutate { stored[goal.nutrient] = goal }
    }

    func removeGoal(nutrient: String) throws {
        try mutate { _ = stored.removeValue(forKey: nutrient) }
    }

    func close() {}

    private func mutate(_ change: () -> Void) throws {
        try lock.withLock {
            mutations += 1
            if mutations > 1 { throw WriteFailed() }
            change()
        }
    }
}

/// A goal store whose goals cannot be read.
final class UnreadableGoalStore: GoalStore, @unchecked Sendable {
    private struct ReadFailed: Error {}

    func goals() throws -> [NutrientGoal] { throw ReadFailed() }
    func goal(for nutrient: String) throws -> NutrientGoal? { throw ReadFailed() }
    func setGoal(_ goal: NutrientGoal) throws {}
    func removeGoal(nutrient: String) throws {}
    func close() {}
}

/// The guided goal setup: its steps, its unit conversions, what it saves and what it forgets.
@MainActor
final class GoalSetupViewModelTests: XCTestCase {
    private func makeModel(
        system: UnitSystem = .metric, goals: [NutrientGoal] = []
    ) -> (GoalSetupViewModel, InMemoryGoalStore, GoalsViewModel) {
        let store = InMemoryGoalStore(goals: goals)
        let goalsModel = GoalsViewModel(
            store: store, preferences: InMemoryDisplayPreferences(unitSystem: system))
        goalsModel.load()
        return (GoalSetupViewModel(goals: goalsModel), store, goalsModel)
    }

    /// Answers the questions for a man of 30, 180 cm and 80 kg, moderately active, aiming to maintain.
    private func answerForAMaintainingMan(_ model: GoalSetupViewModel) {
        model.aim = .maintain
        model.sex = .male
        model.ageText = "30"
        model.heightCentimetersText = "180"
        model.weightKilogramsText = "80"
        model.activity = .moderate
    }

    func testMaintainSkipsThePaceStep() {
        let (model, _, _) = makeModel()
        model.aim = .maintain
        XCTAssertEqual(model.steps, [.aim, .about, .body, .activity, .results])
        model.next()
        XCTAssertEqual(model.step, .about)
        XCTAssertEqual(model.stepLabel, "Step 2 of 5")
    }

    func testLosingAndGainingAskForAPace() {
        let (model, _, _) = makeModel()
        model.aim = .lose
        XCTAssertEqual(model.steps, [.aim, .about, .body, .activity, .pace, .results])
        model.aim = .gain
        XCTAssertEqual(model.steps, [.aim, .about, .body, .activity, .pace, .results])
        XCTAssertEqual(model.stepLabel, "Step 1 of 6")
    }

    func testJustTrackEndsWithAMessageAndSavesNothing() {
        let (model, store, _) = makeModel()
        model.aim = .justTrack
        XCTAssertEqual(model.steps, [.aim, .results])
        model.next()
        XCTAssertEqual(model.step, .results)
        XCTAssertTrue(model.draftTargets.isEmpty)
        XCTAssertFalse(model.save())
        XCTAssertEqual(try store.goals(), [])
    }

    func testBackKeepsTheAnswersAlreadyGiven() {
        let (model, _, _) = makeModel()
        model.aim = .maintain
        model.next()
        model.ageText = "30"
        model.sex = .female
        model.next()
        model.back()
        XCTAssertEqual(model.step, .about)
        XCTAssertEqual(model.ageText, "30")
    }

    func testFiveFeetTenInchesIsExactlyCentimeters() {
        let (model, _, _) = makeModel(system: .usCustomary)
        answerForAMaintainingMan(model)
        model.heightCentimetersText = ""
        model.heightFeetText = "5"
        model.heightInchesText = "10"
        model.weightKilogramsText = ""
        model.weightPoundsText = "176"
        // 70 in * 2.54 cm = 177.8 cm exactly.
        XCTAssertEqual(model.makeProfile()?.heightCentimeters, Decimal(string: "177.8"))
        // 176 lb * 0.45359237 kg = 79.83225712 kg exactly.
        XCTAssertEqual(model.makeProfile()?.weightKilograms, Decimal(string: "79.83225712"))
    }

    func testBlankOrZeroInchesCountAsNoInches() {
        let (model, _, _) = makeModel(system: .usCustomary)
        answerForAMaintainingMan(model)
        model.next()
        model.next()
        model.heightCentimetersText = ""
        model.weightKilogramsText = ""
        model.heightFeetText = "5"
        model.weightPoundsText = "176"
        model.heightInchesText = ""
        // 5 ft with no inches: 60 in * 2.54 cm = 152.4 cm, and the step can move on.
        XCTAssertEqual(model.makeProfile()?.heightCentimeters, Decimal(string: "152.4"))
        XCTAssertTrue(model.canGoNext)
        model.heightInchesText = "0"
        XCTAssertEqual(model.makeProfile()?.heightCentimeters, Decimal(string: "152.4"))
        XCTAssertTrue(model.canGoNext)
    }

    func testMetricAnswersAreUsedAsTyped() {
        let (model, _, _) = makeModel(system: .metric)
        answerForAMaintainingMan(model)
        XCTAssertEqual(model.makeProfile()?.heightCentimeters, 180)
        XCTAssertEqual(model.makeProfile()?.weightKilograms, 80)
        XCTAssertEqual(model.makeProfile()?.ageYears, 30)
    }

    func testPaceOptionsAreKilogramsOrConvertedPounds() {
        let (metric, _, _) = makeModel(system: .metric)
        XCTAssertEqual(metric.paceOptions.map(\.kilogramsPerWeek), [
            Decimal(string: "0.25")!, Decimal(string: "0.5")!, Decimal(string: "0.75")!, 1,
        ])
        let (us, _, _) = makeModel(system: .usCustomary)
        XCTAssertEqual(us.paceOptions.map(\.label), ["0.5 lb per week", "1 lb per week", "1.5 lb per week", "2 lb per week"])
        // 2 lb * 0.45359237 kg = 0.90718474 kg a week.
        XCTAssertEqual(us.paceOptions.last?.kilogramsPerWeek, Decimal(string: "0.90718474"))
    }

    func testResultsAreTheEstimateAndSavingWritesThemToTheGoalStore() throws {
        let (model, store, _) = makeModel()
        answerForAMaintainingMan(model)
        model.next()
        model.next()
        model.next()
        model.next()
        XCTAssertEqual(model.step, .results)
        // The moderate maintenance target from the estimator: 2760 kcal, 345 g carbohydrate,
        // 140 g protein, 90 g fat and 39 g fiber.
        XCTAssertEqual(model.draftTargets["energy"], "2760")
        XCTAssertEqual(model.draftTargets["carbohydrate"], "345")
        XCTAssertEqual(model.draftTargets["protein"], "140")
        XCTAssertEqual(model.draftTargets["fat"], "90")
        XCTAssertEqual(model.draftTargets["fiber"], "39")
        XCTAssertTrue(model.save())
        let saved = Dictionary(uniqueKeysWithValues: try store.goals().map { ($0.nutrient, $0) })
        XCTAssertEqual(saved["energy"]?.target, 2760)
        XCTAssertEqual(saved["energy"]?.unit, .kcal)
        XCTAssertEqual(saved["protein"]?.target, 140)
        XCTAssertEqual(saved["protein"]?.unit, .g)
    }

    func testSavingAlsoUpdatesTheDraftsTheGoalsScreenShows() {
        let (model, _, goalsModel) = makeModel()
        answerForAMaintainingMan(model)
        model.next(); model.next(); model.next(); model.next()
        XCTAssertTrue(model.save())
        // The Goals screen keeps its own text for each field. Without this, a field that was empty
        // before the save would still read as empty, and leaving it would remove the new goal.
        XCTAssertEqual(goalsModel.draftText["energy"], "2760")
        XCTAssertEqual(goalsModel.draftText["protein"], "140")
    }

    func testAnEditedResultIsWhatIsSaved() throws {
        let (model, store, _) = makeModel()
        answerForAMaintainingMan(model)
        model.next(); model.next(); model.next(); model.next()
        model.draftTargets["energy"] = "2000"
        XCTAssertTrue(model.save())
        let saved = Dictionary(uniqueKeysWithValues: try store.goals().map { ($0.nutrient, $0) })
        XCTAssertEqual(saved["energy"]?.target, 2000)
        XCTAssertEqual(saved["protein"]?.target, 140)
    }

    func testAgeUnderEighteenShowsThePlainSentenceAndNoResults() {
        let (model, store, _) = makeModel()
        answerForAMaintainingMan(model)
        model.ageText = "17"
        model.next(); model.next(); model.next(); model.next()
        XCTAssertEqual(model.resultError, "Goal estimates here are for adults. Ask a doctor or dietitian for advice on a target.")
        XCTAssertTrue(model.draftTargets.isEmpty)
        XCTAssertFalse(model.save())
        XCTAssertEqual(try store.goals(), [])
    }

    func testAFailedSaveRestoresEveryGoalItChanged() throws {
        // Energy was stored and protein was not, so the rollback sets one goal back and removes the other.
        // Writes run energy, protein, carbohydrate, fat, fiber; the third (carbohydrate) fails.
        let energy = NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)
        let carbohydrate = NutrientGoal(nutrient: "carbohydrate", target: 250, unit: .g)
        let store = ThirdWriteFailingGoalStore(goals: [energy, carbohydrate])
        let goalsModel = GoalsViewModel(
            store: store, preferences: InMemoryDisplayPreferences(unitSystem: .metric))
        goalsModel.load()
        let model = GoalSetupViewModel(goals: goalsModel)
        answerForAMaintainingMan(model)
        model.next(); model.next(); model.next(); model.next()
        XCTAssertFalse(model.save())
        XCTAssertEqual(try store.goals(), [carbohydrate, energy])
        // The Goals screen still shows the goal it had, not the estimate that failed to save.
        XCTAssertEqual(goalsModel.draftText["energy"], "2000")
    }

    func testAGoalASaveRemovedAndPutBackKeepsItsFieldText() throws {
        // Setup blanks protein, which had a goal, so its removal is the second write; the third
        // (carbohydrate) fails and protein is put back. Its field must show the goal again, or leaving
        // it would remove the goal that was just restored.
        let energy = NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)
        let protein = NutrientGoal(nutrient: "protein", target: 60, unit: .g)
        let store = ThirdWriteFailingGoalStore(goals: [energy, protein])
        let goalsModel = GoalsViewModel(
            store: store, preferences: InMemoryDisplayPreferences(unitSystem: .metric))
        goalsModel.load()
        let model = GoalSetupViewModel(goals: goalsModel)
        answerForAMaintainingMan(model)
        model.next(); model.next(); model.next(); model.next()
        model.draftTargets["protein"] = ""

        XCTAssertFalse(model.save())

        XCTAssertEqual(try store.goals(), [energy, protein])
        XCTAssertEqual(goalsModel.draftText["protein"], "60")
        XCTAssertTrue(goalsModel.commitTarget(for: "protein"))
        XCTAssertEqual(try store.goal(for: "protein"), protein)
    }

    func testASaveSetsTheFieldsUnitSoLeavingItKeepsTheSavedGoal() throws {
        // The protein picker was on mg; setup saves in grams, so the field must say grams too.
        let (model, store, goalsModel) = makeModel(goals: [NutrientGoal(nutrient: "protein", target: 60, unit: .mg)])
        XCTAssertEqual(goalsModel.selectedUnits["protein"], .mg)
        answerForAMaintainingMan(model)
        model.next(); model.next(); model.next(); model.next()
        let saved = try XCTUnwrap(model.draftTargets["protein"])

        XCTAssertTrue(model.save())

        XCTAssertEqual(goalsModel.selectedUnits["protein"], .g)
        let stored = try XCTUnwrap(try store.goal(for: "protein"))
        XCTAssertEqual(stored.unit, .g)
        XCTAssertEqual(stored.target, AmountParser.parseTyped(saved))
        XCTAssertTrue(goalsModel.commitTarget(for: "protein"))
        XCTAssertEqual(try store.goal(for: "protein"), stored)
    }

    func testASaveClearsAnErrorTheRowShowedForEarlierText() {
        let (model, _, goalsModel) = makeModel()
        goalsModel.draftText["protein"] = "0"
        XCTAssertFalse(goalsModel.commitTarget(for: "protein"))
        XCTAssertNotNil(goalsModel.rowError["protein"])
        answerForAMaintainingMan(model)
        model.next(); model.next(); model.next(); model.next()

        XCTAssertTrue(model.save())

        XCTAssertNil(goalsModel.rowError["protein"])
    }

    func testAFailedSaveShowsTheSentenceAndKeepsTheResults() {
        let goalsModel = GoalsViewModel(
            store: InMemoryGoalStore(refusesWrites: true),
            preferences: InMemoryDisplayPreferences(unitSystem: .metric))
        goalsModel.load()
        let model = GoalSetupViewModel(goals: goalsModel)
        answerForAMaintainingMan(model)
        model.next(); model.next(); model.next(); model.next()
        XCTAssertFalse(model.save())
        XCTAssertEqual(model.resultError, "Could not save your goals. Try again.")
        XCTAssertEqual(model.step, .results)
        XCTAssertEqual(model.draftTargets["energy"], "2760")
    }

    func testAnInvalidResultIsNamedFieldByFieldAndTheDraftsStayAsTyped() throws {
        let (model, store, _) = makeModel()
        answerForAMaintainingMan(model)
        model.next(); model.next(); model.next(); model.next()
        model.draftTargets["energy"] = "0"
        model.draftTargets["protein"] = "-5"
        let typed = model.draftTargets
        XCTAssertFalse(model.save())
        XCTAssertEqual(model.draftTargets, typed)
        XCTAssertEqual(model.fieldErrors, [
            "energy": "Enter a number greater than zero.",
            "protein": "Enter a number greater than zero.",
        ])
        XCTAssertEqual(model.resultError, "Enter a number above zero.")
        XCTAssertEqual(try store.goals(), [])
        // Fixing the fields and saving again clears the errors and saves.
        model.draftTargets["energy"] = "2000"
        model.draftTargets["protein"] = "140"
        XCTAssertTrue(model.save())
        XCTAssertTrue(model.fieldErrors.isEmpty)
        XCTAssertNil(model.resultError)
    }

    func testBackClearsTheFieldErrorsAsItDoesTheSummary() {
        let (model, _, _) = makeModel()
        answerForAMaintainingMan(model)
        model.next(); model.next(); model.next(); model.next()
        model.draftTargets["fiber"] = "abc"
        XCTAssertFalse(model.save())
        XCTAssertEqual(model.fieldErrors["fiber"], "Enter a number greater than zero.")
        model.back()
        XCTAssertTrue(model.fieldErrors.isEmpty)
        XCTAssertNil(model.resultError)
    }

    /// Answers for a losing person, so the pace step is part of the path to the results.
    private func answerForALosingMan(_ model: GoalSetupViewModel) {
        model.aim = .lose
        model.sex = .male
        model.ageText = "30"
        model.heightCentimetersText = "180"
        model.weightKilogramsText = "80"
        model.activity = .moderate
    }

    func testAHeightOutOfRangeIsWordedInCentimetersForMetric() {
        let (model, _, _) = makeModel(system: .metric)
        answerForAMaintainingMan(model)
        model.heightCentimetersText = "110"
        model.next(); model.next(); model.next(); model.next()
        XCTAssertEqual(model.resultError, "Check your height. It must be between 120 and 230 cm.")
    }

    func testAHeightOutOfRangeIsWordedInFeetAndInchesForUSCustomary() {
        let (model, _, _) = makeModel(system: .usCustomary)
        answerForAMaintainingMan(model)
        model.heightCentimetersText = ""
        model.heightFeetText = "3"
        model.heightInchesText = ""
        model.weightKilogramsText = ""
        model.weightPoundsText = "176"
        model.next(); model.next(); model.next(); model.next()
        // 120 cm is 47.2 in, so the least height the estimate accepts is 4 ft 0 in; 230 cm is 90.5 in.
        XCTAssertEqual(model.resultError, "Check your height. It must be between 4 ft 0 in and 7 ft 6 in.")
    }

    func testAWeightOutOfRangeIsWordedInKilogramsForMetric() {
        let (model, _, _) = makeModel(system: .metric)
        answerForAMaintainingMan(model)
        model.weightKilogramsText = "400"
        model.next(); model.next(); model.next(); model.next()
        XCTAssertEqual(model.resultError, "Check your weight. It must be between 30 and 300 kg.")
    }

    func testAWeightOutOfRangeIsWordedInPoundsForUSCustomary() {
        let (model, _, _) = makeModel(system: .usCustomary)
        answerForAMaintainingMan(model)
        model.heightCentimetersText = ""
        model.heightFeetText = "5"
        model.heightInchesText = "10"
        model.weightKilogramsText = ""
        model.weightPoundsText = "900"
        model.next(); model.next(); model.next(); model.next()
        // 30 kg is 66.1 lb, so the least weight accepted is 67 lb; 300 kg is 661.4 lb.
        XCTAssertEqual(model.resultError, "Check your weight. It must be between 67 and 661 lb.")
    }

    func testAPaceOutOfRangeIsWordedInKilogramsForMetric() {
        let (model, _, _) = makeModel(system: .metric)
        answerForALosingMan(model)
        model.selectedPaceKilograms = 2
        model.goalWeightKilogramsText = "75"
        model.next(); model.next(); model.next(); model.next(); model.next()
        XCTAssertEqual(model.resultError, "Check your pace. It must be between 0.1 and 1 kg a week.")
    }

    func testAPaceOutOfRangeIsWordedInPoundsForUSCustomary() {
        let (model, _, _) = makeModel(system: .usCustomary)
        answerForALosingMan(model)
        model.heightCentimetersText = ""
        model.heightFeetText = "5"
        model.heightInchesText = "11"
        model.weightKilogramsText = ""
        model.weightPoundsText = "176"
        model.selectedPaceKilograms = 2
        model.goalWeightPoundsText = "165"
        model.next(); model.next(); model.next(); model.next(); model.next()
        // 0.1 kg is 0.22 lb, so the least pace accepted is 0.3 lb a week; 1 kg is 2.2 lb.
        XCTAssertEqual(model.resultError, "Check your pace. It must be between 0.3 and 2.2 lb a week.")
    }

    func testClosingTheSheetClearsEveryAnswer() {
        let (model, _, _) = makeModel()
        answerForAMaintainingMan(model)
        model.next(); model.next(); model.next(); model.next()
        model.clearAnswers()
        XCTAssertNil(model.aim)
        XCTAssertNil(model.sex)
        XCTAssertEqual(model.ageText, "")
        XCTAssertEqual(model.heightCentimetersText, "")
        XCTAssertEqual(model.weightKilogramsText, "")
        XCTAssertNil(model.activity)
        XCTAssertTrue(model.draftTargets.isEmpty)
        XCTAssertEqual(model.step, .aim)
    }

    func testTheReplaceSentenceAppearsOnlyWhenTargetsExist() {
        let (model, _, goalsModel) = makeModel()
        XCTAssertFalse(model.hasExistingTargets)
        goalsModel.setTarget("50", for: "protein")
        XCTAssertTrue(model.hasExistingTargets)
        XCTAssertEqual(
            GoalSetupViewModel.replaceNotice,
            "This replaces your current targets for these nutrients.")
    }

    func testJustTrackSaysTheCurrentTargetsStayWhenAnyGoalIsStored() {
        // A water-only goal is still a target, so the day must not promise to show none.
        let water = NutrientGoal(nutrient: "water", target: 2000, unit: .mL)
        let (model, store, _) = makeModel(goals: [water])
        model.aim = .justTrack
        model.next()
        XCTAssertEqual(
            model.justTrackMessage,
            "Your current targets are unchanged. You can change or remove them on the Goals screen.")
        XCTAssertFalse(model.save())
        XCTAssertEqual(try store.goals(), [water])
    }

    /// When the targets cannot be read, the result must not claim there are none.
    func testJustTrackDoesNotClaimNoTargetsWhenTheStoreCannotBeRead() {
        let goalsModel = GoalsViewModel(
            store: UnreadableGoalStore(), preferences: InMemoryDisplayPreferences(unitSystem: .metric))
        goalsModel.load()
        let model = GoalSetupViewModel(goals: goalsModel)
        model.aim = .justTrack
        model.next()
        XCTAssertEqual(
            model.justTrackMessage,
            "We could not read your current targets, so they are unchanged. Check them on the Goals screen.")
    }

    /// A restore that also fails must be reported as such, not as an ordinary failed save.
    func testAFailedRestoreIsReportedAsPossiblyPartial() {
        let energy = NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)
        let store = FailsAfterFirstWriteGoalStore(goals: [energy])
        let goalsModel = GoalsViewModel(
            store: store, preferences: InMemoryDisplayPreferences(unitSystem: .metric))
        goalsModel.load()
        let model = GoalSetupViewModel(goals: goalsModel)
        answerForAMaintainingMan(model)
        model.next(); model.next(); model.next(); model.next()
        XCTAssertFalse(model.save())
        XCTAssertEqual(
            model.resultError,
            "Some goals may not have been put back. Check your targets on the Goals screen.")
    }

    /// The heading follows the same rule as the message: an unreadable store is unknown, not empty.
    func testJustTrackHeadingDoesNotClaimNoTargetsWhenTheStoreCannotBeRead() {
        let goalsModel = GoalsViewModel(
            store: UnreadableGoalStore(), preferences: InMemoryDisplayPreferences(unitSystem: .metric))
        goalsModel.load()
        let model = GoalSetupViewModel(goals: goalsModel)
        XCTAssertEqual(model.justTrackHeading, "Your day")
        let (empty, _, _) = makeModel()
        XCTAssertEqual(empty.justTrackHeading, "Your day, without targets")
    }

    func testJustTrackWithNoTargetsSaysTheDayShowsTotals() {
        let (model, store, _) = makeModel()
        model.aim = .justTrack
        model.next()
        XCTAssertEqual(model.justTrackMessage, "Nothing was saved. Your day will show totals without targets.")
        XCTAssertFalse(model.save())
        XCTAssertEqual(try store.goals(), [])
    }

    /// The About step names exactly what is missing, and nothing once both fields are set.
    func testAboutNamesWhatIsMissing() {
        let model = GoalSetupViewModel(goals: GoalsViewModel(store: InMemoryGoalStore(goals: [])))
        XCTAssertEqual(model.aboutMissingNotice, "Choose your sex and enter your age to continue.")
        model.sex = .female
        XCTAssertEqual(model.aboutMissingNotice, "Enter your age to continue.")
        model.sex = nil
        model.ageText = "34"
        XCTAssertEqual(model.aboutMissingNotice, "Choose your sex to continue.")
        model.sex = .male
        XCTAssertNil(model.aboutMissingNotice)
    }
}
