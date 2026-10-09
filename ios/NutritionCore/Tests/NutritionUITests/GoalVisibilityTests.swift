import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders
import XCTest
@testable import NutritionUI

/// A file-scope constant rather than an instance member, because the helpers below default to it.
private let when = Date(timeIntervalSince1970: 1_700_000_000)

private struct OatsFacts: NutrientFactsLookup {
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue {
        .unknown
    }

    func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue {
        snapshot?.value(for: nutrient) ?? .unknown
    }
}

/// Choosing which goals show on Today. The switch hides a bar and nothing else: the goal, its target
/// and the day's totals are unchanged, and the Journal day header follows the same choice.
@MainActor
final class GoalVisibilityTests: XCTestCase {
    private func makeJournalStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func makeGoalStore() throws -> SwiftDataGoalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataGoalStore(url: directory.appendingPathComponent("goals.store"))
    }

    /// A defaults suite of its own, so a test never touches the standard domain.
    private func makeDefaults() -> UserDefaults {
        let name = "goal-visibility-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func logOats(_ store: JournalStore, grams: Decimal) throws {
        let snapshot = ProductDefinition(
            snapshotID: "snapshot-oats", productID: "product-oats", name: "Rolled oats",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["protein": .known(Decimal(13), .g), "fiber": .known(Decimal(10), .g)])
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "oats", name: "Rolled oats", amount: grams, unit: .g)],
            product: snapshot, now: when)
    }

    private func todayBarIDs(_ model: TodayViewModel) -> [String] {
        model.goalBars.map(\.id)
    }

    // MARK: Defaults and the Today card

    func testEveryGoalShowsOnTodayUntilAPersonHidesIt() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try goals.setGoal(NutrientGoal(nutrient: "fiber", target: Decimal(30), unit: .g))
        try logOats(journal, grams: 40)
        let preferences = InMemoryDisplayPreferences()

        let model = TodayViewModel(store: journal, goals: goals, lookup: OatsFacts(), preferences: preferences)
        model.load(now: when)

        XCTAssertEqual(Set(todayBarIDs(model)), ["protein", "fiber"])
        XCTAssertEqual(preferences.hiddenTodayGoals, [])
    }

    func testHidingProteinRemovesItsBarFromTodayAndLeavesTheOthers() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try goals.setGoal(NutrientGoal(nutrient: "fiber", target: Decimal(30), unit: .g))
        try logOats(journal, grams: 40)
        let preferences = InMemoryDisplayPreferences()
        preferences.setGoalShownOnToday("protein", shown: false)

        let model = TodayViewModel(store: journal, goals: goals, lookup: OatsFacts(), preferences: preferences)
        model.load(now: when)

        XCTAssertEqual(todayBarIDs(model), ["fiber"])
        // The goal and its target are untouched, and the day's protein is still totalled.
        XCTAssertEqual(try goals.goals().first { $0.nutrient == "protein" }?.target, Decimal(60))
        XCTAssertEqual(
            model.progress.first { $0.nutrient == "protein" }?.text, "Protein 5.2 g of 60 g")
    }

    func testHidingProteinAlsoRemovesItsBarFromTheJournalDayHeader() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try goals.setGoal(NutrientGoal(nutrient: "fiber", target: Decimal(30), unit: .g))
        try logOats(journal, grams: 40)
        let preferences = InMemoryDisplayPreferences()
        preferences.setGoalShownOnToday("protein", shown: false)

        let model = JournalViewModel(
            store: journal, goals: goals, lookup: OatsFacts(), timeZoneIdentifier: "UTC",
            locale: Locale(identifier: "en_US_POSIX"), preferences: preferences)
        model.load(now: when)

        let headerIDs = try XCTUnwrap(model.sections.first).headerBars.map(\.id)
        XCTAssertEqual(headerIDs, ["fiber"])
    }

    func testShowingProteinAgainRestoresItsBar() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logOats(journal, grams: 40)
        let preferences = InMemoryDisplayPreferences()
        preferences.setGoalShownOnToday("protein", shown: false)
        preferences.setGoalShownOnToday("protein", shown: true)

        let model = TodayViewModel(store: journal, goals: goals, lookup: OatsFacts(), preferences: preferences)
        model.load(now: when)

        XCTAssertEqual(todayBarIDs(model), ["protein"])
        XCTAssertEqual(preferences.hiddenTodayGoals, [])
    }

    func testTheChoiceSurvivesANewViewModelOnTheSamePreferences() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logOats(journal, grams: 40)
        let preferences = InMemoryDisplayPreferences()

        let goalsModel = GoalsViewModel(store: goals, preferences: preferences)
        goalsModel.load()
        XCTAssertTrue(goalsModel.setShowsOnToday(false, for: "protein"))

        let rebuilt = TodayViewModel(store: journal, goals: goals, lookup: OatsFacts(), preferences: preferences)
        rebuilt.load(now: when)
        XCTAssertEqual(todayBarIDs(rebuilt), [])
    }

    func testResettingPreferencesShowsEveryGoalAgain() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logOats(journal, grams: 40)
        let preferences = InMemoryDisplayPreferences()
        preferences.setGoalShownOnToday("protein", shown: false)

        preferences.resetToDefaults()

        XCTAssertEqual(preferences.hiddenTodayGoals, [])
        let model = TodayViewModel(store: journal, goals: goals, lookup: OatsFacts(), preferences: preferences)
        model.load(now: when)
        XCTAssertEqual(todayBarIDs(model), ["protein"])
    }

    // MARK: The Goals screen

    func testAGoalWithoutATargetCannotBeToggled() throws {
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        let preferences = InMemoryDisplayPreferences()
        let model = GoalsViewModel(store: goals, preferences: preferences)
        model.load()

        let fiber = try XCTUnwrap(model.sections.flatMap(\.rows).first { $0.nutrient == "fiber" })
        XCTAssertFalse(fiber.hasTarget)
        XCTAssertFalse(model.setShowsOnToday(false, for: "fiber"))
        XCTAssertEqual(preferences.hiddenTodayGoals, [])
    }

    func testTheGoalsScreenShowsEachTargetedGoalAsShownByDefault() throws {
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        let model = GoalsViewModel(store: goals, preferences: InMemoryDisplayPreferences())
        model.load()

        let protein = try XCTUnwrap(model.sections.flatMap(\.rows).first { $0.nutrient == "protein" })
        XCTAssertTrue(protein.hasTarget)
        XCTAssertTrue(protein.showsOnToday)
    }

    // MARK: Storage

    func testTheStoredTextIsSortedAndReadsBackAsTheSameChoice() throws {
        let defaults = makeDefaults()
        let writer = UserDefaultsDisplayPreferences(defaults: defaults)
        writer.setGoalShownOnToday("protein", shown: false)
        writer.setGoalShownOnToday("fiber", shown: false)

        XCTAssertEqual(defaults.string(forKey: "display.goals.hiddenOnToday"), "fiber,protein")
        let reader = UserDefaultsDisplayPreferences(defaults: defaults)
        XCTAssertEqual(reader.hiddenTodayGoals, ["fiber", "protein"])
    }

    func testAnUnknownKeyInTheStoredTextHasNoEffectOnAnyBar() throws {
        let defaults = makeDefaults()
        defaults.set("not-a-nutrient,protein", forKey: "display.goals.hiddenOnToday")
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try goals.setGoal(NutrientGoal(nutrient: "fiber", target: Decimal(30), unit: .g))
        try logOats(journal, grams: 40)
        let preferences = UserDefaultsDisplayPreferences(defaults: defaults)

        let model = TodayViewModel(store: journal, goals: goals, lookup: OatsFacts(), preferences: preferences)
        model.load(now: when)

        XCTAssertEqual(todayBarIDs(model), ["fiber"])
    }

    func testResetRemovesTheStoredChoiceFromTheDefaultsDomain() throws {
        let defaults = makeDefaults()
        let preferences = UserDefaultsDisplayPreferences(defaults: defaults)
        preferences.setGoalShownOnToday("protein", shown: false)

        preferences.resetToDefaults()

        XCTAssertNil(defaults.string(forKey: "display.goals.hiddenOnToday"))
        XCTAssertEqual(preferences.hiddenTodayGoals, [])
    }
}
