import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

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

    func testJustTrackWithNoTargetsSaysTheDayShowsTotals() {
        let (model, store, _) = makeModel()
        model.aim = .justTrack
        model.next()
        XCTAssertEqual(model.justTrackMessage, "Nothing was saved. Your day will show totals without targets.")
        XCTAssertFalse(model.save())
        XCTAssertEqual(try store.goals(), [])
    }
}
