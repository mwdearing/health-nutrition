import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders
import XCTest
@testable import NutritionUI

/// A file-scope constant rather than an instance member, because a default argument cannot read an
/// instance member and the helpers below default to this instant.
private let when = Date(timeIntervalSince1970: 1_700_000_000)

private struct SnapshotOnlyFacts: NutrientFactsLookup {
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue {
        .unknown
    }

    func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue {
        snapshot?.value(for: nutrient) ?? .unknown
    }
}

/// The daily goals as Today shows them: what the day has reached against a target, or as a plain
/// total where no target is set.
@MainActor
final class DailyGoalsTests: XCTestCase {
    private func makeJournalStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func makeGoalStore() throws -> SwiftDataGoalStore {
        try makeGoalStoreWithURL().0
    }

    /// The store and the file it is on, so a test can close it and open the same file again, which
    /// is what a fresh launch does.
    private func makeGoalStoreWithURL() throws -> (SwiftDataGoalStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("goals.store")
        return (try SwiftDataGoalStore(url: url), url)
    }

    /// A product whose stated protein is per 100 g, so 100 g logged carries exactly 13 g.
    private func oatsSnapshot() -> ProductDefinition {
        ProductDefinition(
            snapshotID: "snapshot-oats", productID: "product-oats", name: "Rolled oats",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["protein": .known(Decimal(13), .g)])
    }

    /// A product stored the way a barcode lookup stores one: its energy under `energyKcal`, not under
    /// the canonical key the goals ask for.
    private func barSnapshot() -> ProductDefinition {
        ProductDefinition(
            snapshotID: "snapshot-bar", productID: "product-bar", name: "Breakfast bar",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["energyKcal": .known(Decimal(400), .kcal)])
    }

    @discardableResult
    private func logBar(
        _ store: JournalStore, grams: Decimal, at date: Date = when
    ) throws -> String {
        let intakeID = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: intakeID, category: "food", occurredAt: date, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "bar", name: "Breakfast bar", amount: grams, unit: .g)],
            product: barSnapshot(), now: date)
        return intakeID
    }

    @discardableResult
    private func logOats(
        _ store: JournalStore, grams: Decimal, at date: Date = when
    ) throws -> String {
        let intakeID = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: intakeID, category: "food", occurredAt: date, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "oats", name: "Rolled oats", amount: grams, unit: .g)],
            product: oatsSnapshot(), now: date)
        return intakeID
    }

    @discardableResult
    private func logWater(_ store: JournalStore, milliliters: Decimal, at date: Date = when) throws -> String {
        let intakeID = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: intakeID, category: "water", occurredAt: date, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(
                componentID: "water", name: "Water", amount: milliliters, unit: .mL)],
            product: nil, now: date)
        return intakeID
    }

    private func line(_ model: TodayViewModel, _ nutrient: String) -> String? {
        model.progress.first { $0.nutrient == nutrient }?.text
    }

    // MARK: A goal compared with the day

    /// Below the target, the line says how far along the day is. The figure is the day's own
    /// protein, scaled from the product's per-100 g basis to what was logged.
    func testAGoalBelowTheDayShowsTheTotalAgainstIt() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        // 40 g of a product stating 13 g per 100 g carries 5.2 g.
        try logOats(journal, grams: 40)

        let model = TodayViewModel(store: journal, goals: goals, lookup: SnapshotOnlyFacts())
        model.load(now: when)

        XCTAssertEqual(line(model, "protein"), "Protein 5.2 g of 60 g")
        XCTAssertTrue(try XCTUnwrap(model.progress.first { $0.nutrient == "protein" }).hasGoal)
    }

    /// Above the target the line still says so rather than capping at the target: the day carried
    /// more than the goal asked for, and rounding it down to the target would under-report it.
    func testAGoalAboveTheDayShowsTheTotalAgainstIt() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        // 400 g at 13 g per 100 g carries 52 g, still under; a second entry takes it over.
        try logOats(journal, grams: 400)
        try logOats(journal, grams: 200)

        let model = TodayViewModel(store: journal, goals: goals, lookup: SnapshotOnlyFacts())
        model.load(now: when)

        XCTAssertEqual(line(model, "protein"), "Protein 78 g of 60 g")
    }

    /// A day exactly at the target reads as the target met, with the real figure beside it.
    func testADayExactlyAtItsGoalShowsBothFigures() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(39), unit: .g))
        try logOats(journal, grams: 300)

        let model = TodayViewModel(store: journal, goals: goals, lookup: SnapshotOnlyFacts())
        model.load(now: when)

        XCTAssertEqual(line(model, "protein"), "Protein 39 g of 39 g")
    }

    /// Water has a target too, in mL, and its own line compares the day's water against it.
    func testAWaterGoalComparesTheDaysWaterInMillilitres() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "water", target: Decimal(2000), unit: .mL))
        try logWater(journal, milliliters: 750)

        let model = TodayViewModel(store: journal, goals: goals, lookup: SnapshotOnlyFacts())
        model.load(now: when)

        XCTAssertEqual(line(model, "water"), "Water 750 mL of 2000 mL")
    }

    /// A nutrient with no goal still shows its total, without a target to compare it against.
    func testANutrientWithNoGoalShowsThePlainTotal() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logOats(journal, grams: 400)

        let model = TodayViewModel(store: journal, goals: goals, lookup: SnapshotOnlyFacts())
        model.load(now: when)

        // Fiber is in the default tracked set and has no goal, so it is tracked and stated plainly.
        XCTAssertFalse(try XCTUnwrap(model.progress.first { $0.nutrient == "fiber" }).hasGoal)
        XCTAssertTrue(line(model, "fiber")?.hasSuffix("unknown") == true)
    }

    /// Removing a goal falls back to the plain total: the nutrient is still tracked, because the
    /// person logged it, and it no longer compares against anything.
    func testRemovingAGoalFallsBackToThePlainTotalLine() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logOats(journal, grams: 400)
        let model = TodayViewModel(store: journal, goals: goals, lookup: SnapshotOnlyFacts())
        model.load(now: when)
        XCTAssertEqual(line(model, "protein"), "Protein 52 g of 60 g")

        try goals.removeGoal(nutrient: "protein")
        model.load(now: when)

        XCTAssertEqual(line(model, "protein"), "Protein 52 g")
        XCTAssertFalse(try XCTUnwrap(model.progress.first { $0.nutrient == "protein" }).hasGoal)
        // Still tracked, so the total is not dropped along with the target.
        XCTAssertNotNil(line(model, "protein"))
    }

    // MARK: Persistence

    /// A goal is data, so it outlives the screen that set it. A new view model over the same store
    /// still finds it, which is what makes it a target rather than a value held in memory.
    func testAGoalSurvivesReopeningTheStoreInANewViewModel() throws {
        let journal = try makeJournalStore()
        let (goals, url) = try makeGoalStoreWithURL()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logOats(journal, grams: 400)
        let first = TodayViewModel(store: journal, goals: goals, lookup: SnapshotOnlyFacts())
        first.load(now: when)
        XCTAssertEqual(line(first, "protein"), "Protein 52 g of 60 g")

        // Close the store and open the same file again, as a fresh launch would.
        goals.close()
        let reopened = try SwiftDataGoalStore(url: url)
        addTeardownBlock { reopened.close() }
        let afterRelaunch = TodayViewModel(store: journal, goals: reopened, lookup: SnapshotOnlyFacts())
        afterRelaunch.load(now: when)

        XCTAssertEqual(line(afterRelaunch, "protein"), "Protein 52 g of 60 g")
        XCTAssertEqual(try reopened.goal(for: "protein")?.target, Decimal(60))
    }

    /// The same persistence check without closing the file: a second view model built over the same
    /// store, which is what the app does when the screen is rebuilt.
    func testAGoalPersistsAcrossARebuiltViewModelOverTheSameStore() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logOats(journal, grams: 400)
        let first = TodayViewModel(store: journal, goals: goals, lookup: SnapshotOnlyFacts())
        first.load(now: when)
        XCTAssertEqual(line(first, "protein"), "Protein 52 g of 60 g")

        let rebuilt = TodayViewModel(store: journal, goals: goals, lookup: SnapshotOnlyFacts())
        rebuilt.load(now: when)

        XCTAssertEqual(line(rebuilt, "protein"), "Protein 52 g of 60 g")
        XCTAssertEqual(try goals.goal(for: "protein")?.target, Decimal(60))
    }

    /// The target text and unit read back exactly as they were set, with no rounding on the way
    /// through the store.
    func testAGoalTargetIsStoredAndReadBackAsAnExactDecimal() throws {
        let goals = try makeGoalStore()
        try goals.setGoal(
            NutrientGoal(nutrient: "sodium", target: Decimal(string: "2.35")!, unit: .g))

        let stored = try XCTUnwrap(try goals.goal(for: "sodium"))

        XCTAssertEqual(stored.target, Decimal(string: "2.35")!)
        XCTAssertEqual(stored.unit, .g)
        XCTAssertEqual(stored.nutrient, "sodium")
    }

    /// One goal per nutrient key: a second write replaces the first rather than leaving two targets
    /// to choose between.
    func testSettingAGoalTwiceReplacesItRatherThanAddingASecond() throws {
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(90), unit: .g))

        let all = try goals.goals()

        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.target, Decimal(90))
    }

    /// A target of zero, a negative one or a NaN is refused rather than stored: each would make the
    /// day read as met before anything was logged.
    func testAnUnusableGoalIsRefusedAndNothingIsStored() throws {
        let goals = try makeGoalStore()

        for target in [Decimal(0), Decimal(-5), Decimal.nan] {
            XCTAssertThrowsError(
                try goals.setGoal(NutrientGoal(nutrient: "protein", target: target, unit: .g)))
        }

        XCTAssertTrue(try goals.goals().isEmpty)
    }

    // MARK: Today without a goal store

    /// With no goal store at all the totals still appear, as plain totals. The goal store is
    /// optional so a caller that keeps goals elsewhere is not left without the larger half.
    func testTotalsAppearWithNoGoalStoreAtAll() throws {
        let journal = try makeJournalStore()
        try logWater(journal, milliliters: 300)

        let model = TodayViewModel(store: journal, goals: nil, lookup: SnapshotOnlyFacts())
        model.load(now: when)

        XCTAssertEqual(line(model, "water"), "Water 300 mL")
        XCTAssertFalse(try XCTUnwrap(model.progress.first { $0.nutrient == "water" }).hasGoal)
    }

    /// A goal store that cannot be read leaves the totals readable, as plain totals, rather than failing
    /// the whole screen: the day is still knowable even when the targets are not. It also says so on
    /// the screen, because a store that cannot be read is not a person who has set no targets:
    /// swallowing the failure left every nutrient reading as "no goal set", which is a claim about the
    /// person rather than about the store.
    func testAnUnreadableGoalStoreStillShowsTheDaysTotalsAndSaysSo() throws {
        let journal = try makeJournalStore()
        let refusing = InMemoryGoalStore(failNextRead: true)
        try logWater(journal, milliliters: 300)

        let model = TodayViewModel(store: journal, goals: refusing, lookup: SnapshotOnlyFacts())
        model.load(now: when)

        XCTAssertEqual(line(model, "water"), "Water 300 mL")
        XCTAssertEqual(model.errorMessage, GoalsViewModel.readFailedMessage)
    }

    /// A goal store that reads fine afterwards clears the failure, rather than leaving the message
    /// from a load that has been superseded.
    func testAReadableGoalStoreAgainClearsTheFailure() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try logWater(journal, milliliters: 300)
        let model = TodayViewModel(store: journal, goals: goals, lookup: SnapshotOnlyFacts())

        model.load(now: when)
        XCTAssertNil(model.errorMessage)

        goals.close()
        model.load(now: when)
        XCTAssertEqual(model.errorMessage, GoalsViewModel.readFailedMessage)
    }

    /// A goal for a nutrient outside the default tracked set is shown, because a target the screen
    /// ignores is a target the person cannot see they set.
    func testAGoalForANutrientOutsideTheDefaultsIsStillShown() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "zinc", target: Decimal(11), unit: .mg))
        try logWater(journal, milliliters: 300)

        let model = TodayViewModel(store: journal, goals: goals, lookup: SnapshotOnlyFacts())
        model.load(now: when)

        let zinc = try XCTUnwrap(model.progress.first { $0.nutrient == "zinc" })
        XCTAssertEqual(zinc.text, "Zinc unknown")
        XCTAssertTrue(zinc.hasGoal)
    }

    /// Coverage is built from the same goal-expanded list the totals are, so a nutrient somebody set
    /// a target for is also one the screen says how much of the day is known about. The fixed
    /// fallback alone left it out of Coverage entirely while its progress line was on screen.
    func testCoverageCoversTheNutrientsTheGoalsAddAsWellAsTheFallback() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "zinc", target: Decimal(11), unit: .mg))
        try logOats(journal, grams: 100)

        let model = TodayViewModel(store: journal, goals: goals, lookup: SnapshotOnlyFacts())
        model.load(now: when)

        XCTAssertEqual(
            model.coverage.map(\.nutrient), TodayViewModel.defaultTrackedNutrients + ["zinc"])
        let zinc = try XCTUnwrap(model.coverage.first { $0.nutrient == "zinc" })
        XCTAssertEqual(zinc.total, 1)
    }

    /// Coverage is about the day's **foods**, so a water target gets a line in Totals and none in
    /// Coverage. Counting the day's foods against water would read "1 of 1 foods lack water" for a day
    /// whose water was known exactly, because a drink never joins the food components coverage counts
    /// — and the drinks are the only entries that could have said anything about water.
    func testACoverageLineIsNeverBuiltForWaterWhoseEntriesAreNotFoods() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "water", target: Decimal(2000), unit: .mL))
        try logWater(journal, milliliters: 750)
        try logOats(journal, grams: 100)

        let model = TodayViewModel(store: journal, goals: goals, lookup: SnapshotOnlyFacts())
        model.load(now: when)

        XCTAssertFalse(model.coverage.contains { $0.nutrient == "water" })
        // The line the water target does belong to, and the day's water is still what was drunk.
        XCTAssertEqual(line(model, "water"), "Water 750 mL of 2000 mL")
        // Every food line still counts the day's food.
        XCTAssertEqual(model.coverage.count, TodayViewModel.defaultTrackedNutrients.count)
        let protein = try XCTUnwrap(model.coverage.first { $0.nutrient == "protein" })
        XCTAssertEqual(protein.total, 1)
        XCTAssertEqual(model.waterSkippedCount, 0)
    }

    /// The foods a drink cannot be counted against are the same ones whether or not water has a
    /// target, so a water goal changes the Totals section and nothing in Coverage.
    func testACoverageIsTheSameWithAndWithoutAWaterGoal() throws {
        let journal = try makeJournalStore()
        try logWater(journal, milliliters: 750)
        try logOats(journal, grams: 100)
        let withoutGoal = TodayViewModel(store: journal, lookup: SnapshotOnlyFacts())
        withoutGoal.load(now: when)
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "water", target: Decimal(2000), unit: .mL))
        let withGoal = TodayViewModel(store: journal, goals: goals, lookup: SnapshotOnlyFacts())
        withGoal.load(now: when)

        XCTAssertEqual(withGoal.coverage.map(\.nutrient), withoutGoal.coverage.map(\.nutrient))
        XCTAssertTrue(withGoal.coverage.map(\.nutrient).contains("protein"))
    }

    // MARK: Energy is counted in kilocalories

    /// Energy is an energy, not a mass. A snapshot that came from a barcode states it under
    /// `energyKcal`, and the day compares the total against a target in the same unit, so the line
    /// reads like with like rather than against a goal no screen could ever show as met.
    func testAnEnergyGoalInKilocaloriesComparesWithTheDaysEnergy() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "energy", target: Decimal(2000), unit: .kcal))
        // 200 g of a product stating 400 kcal per 100 g carries 800 kcal.
        try logBar(journal, grams: 200)

        let model = TodayViewModel(store: journal, goals: goals, lookup: SnapshotOnlyFacts())
        model.load(now: when)

        XCTAssertEqual(line(model, "energy"), "Energy 800 kcal of 2000 kcal")
    }

    /// The Goals screen offers and stores energy in kilocalories, so the target a person types there
    /// is one the day's energy total can be compared against at all.
    func testGoalsScreenOffersEnergyInKilocalories() throws {
        let goals = try makeGoalStore()
        let model = GoalsViewModel(store: goals)
        model.load()

        XCTAssertTrue(model.setTarget("2000", for: "energy"))
        XCTAssertEqual(model.rows.first { $0.nutrient == "energy" }?.targetText, "2000 kcal")
        XCTAssertEqual(try goals.goal(for: "energy")?.unit, .kcal)
    }

    /// A compound a captured supplement panel stored under its own slug is offered by the Goals screen,
    /// so a person can set a target for it rather than only seeing the fixed list.
    func testGoalsScreenOffersACompoundKeyTheJournalSnapshotsCarry() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        let snapshot = ProductDefinition(
            snapshotID: "snapshot-creatine", productID: "label_capture", name: "Synthetic Gummies",
            labelBasis: "per serving (30 g)", catalogOrigin: "label_capture", catalogVersion: "unknown",
            nutrients: ["creatine-monohydrate": .known(Decimal(3), .g)])
        let intakeID = UUID().uuidString.lowercased()
        try journal.create(
            Intake(id: intakeID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "gummies", name: "Gummies", amount: Decimal(30), unit: .g)],
            product: snapshot, now: when)

        let model = GoalsViewModel(store: goals, journal: journal)
        model.load()

        XCTAssertTrue(
            model.offeredKeys.contains("creatine-monohydrate"),
            "a compound the snapshot carries is offerable: \(model.offeredKeys)")
        XCTAssertTrue(model.rows.map { $0.nutrient }.contains("creatine-monohydrate"))
        XCTAssertTrue(model.setTarget("5", for: "creatine-monohydrate"))
        XCTAssertEqual(try goals.goal(for: "creatine-monohydrate")?.target, Decimal(5))
    }

    /// Once a compound goal is set, Today counts the day's compound from the entry's snapshot and shows
    /// it against the target, so the goal a person set is one the screen can compare at all.
    func testADayWithACompoundGoalShowsTheDaysCompoundTotal() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        let snapshot = ProductDefinition(
            snapshotID: "snapshot-creatine", productID: "label_capture", name: "Synthetic Gummies",
            labelBasis: "per serving (30 g)", catalogOrigin: "label_capture", catalogVersion: "unknown",
            nutrients: ["creatine-monohydrate": .known(Decimal(3), .g)])
        let intakeID = UUID().uuidString.lowercased()
        try journal.create(
            Intake(id: intakeID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "gummies", name: "Gummies", amount: Decimal(30), unit: .g)],
            product: snapshot, now: when)
        try goals.setGoal(NutrientGoal(nutrient: "creatine-monohydrate", target: Decimal(5), unit: .g))

        let model = TodayViewModel(store: journal, goals: goals, lookup: SnapshotOnlyFacts())
        model.load(now: when)

        XCTAssertEqual(line(model, "creatine-monohydrate"), "Creatine Monohydrate 3 g of 5 g")
    }

    /// A key that has a stored goal is offered even when no current snapshot carries it, so an existing
    /// compound goal can still be changed or removed after the entry that named it is gone.
    func testGoalsScreenOffersAStoredCompoundGoalWithNoSnapshot() throws {
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "dha", target: Decimal(1), unit: .g))

        let model = GoalsViewModel(store: goals)
        model.load()

        XCTAssertTrue(model.offeredKeys.contains("dha"), "a stored goal is offerable: \(model.offeredKeys)")
        XCTAssertEqual(model.rows.first { $0.nutrient == "dha" }?.targetText, "1 g")
        XCTAssertTrue(model.removeTarget(for: "dha"))
        XCTAssertNil(model.rows.first { $0.nutrient == "dha" }?.targetText)
    }

    /// Today shows a compound goal under the label's own words when the snapshot carries them, so the
    /// day reads `DHA 500 mg of 1 g` rather than the `Dha` its slug spells back out.
    func testADaysCompoundGoalUsesThePrintedName() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        let snapshot = ProductDefinition(
            snapshotID: "snapshot-dha", productID: "label_capture", name: "Synthetic Gummies",
            labelBasis: "per serving (30 g)", catalogOrigin: "label_capture", catalogVersion: "unknown",
            nutrients: ["dha": .known(Decimal(500), .mg)],
            nutrientDisplayNames: ["dha": "DHA"])
        let intakeID = UUID().uuidString.lowercased()
        try journal.create(
            Intake(id: intakeID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "gummies", name: "Gummies", amount: Decimal(30), unit: .g)],
            product: snapshot, now: when)
        try goals.setGoal(NutrientGoal(nutrient: "dha", target: Decimal(1), unit: .g))

        let model = TodayViewModel(store: journal, goals: goals, lookup: SnapshotOnlyFacts())
        model.load(now: when)

        XCTAssertEqual(line(model, "dha"), "DHA 500 mg of 1 g")
    }

    /// The name a captured label printed travels with its snapshot, so a goal for a compound is shown
    /// under the label's own words (`DHA`) rather than the name its slug spells back out.
    func testGoalsScreenShowsAPrintedCompoundNameFromTheSnapshot() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        let snapshot = ProductDefinition(
            snapshotID: "snapshot-dha", productID: "label_capture", name: "Synthetic Gummies",
            labelBasis: "per serving (30 g)", catalogOrigin: "label_capture", catalogVersion: "unknown",
            nutrients: ["dha": .known(Decimal(500), .mg)],
            nutrientDisplayNames: ["dha": "DHA"])
        let intakeID = UUID().uuidString.lowercased()
        try journal.create(
            Intake(id: intakeID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "gummies", name: "Gummies", amount: Decimal(30), unit: .g)],
            product: snapshot, now: when)

        let model = GoalsViewModel(store: goals, journal: journal)
        model.load()

        let row = try XCTUnwrap(model.rows.first { $0.nutrient == "dha" })
        XCTAssertEqual(row.displayName, "DHA")
        XCTAssertEqual(model.displayName(for: "dha"), "DHA")
    }

    /// A compound the canonical mapping does not name takes its goal's dimension from the value the
    /// capture stored: a label that states "Vitamin A 900IU" is counted in international units, so the
    /// screen offers and stores that goal in IU rather than in a mass that would compare against
    /// nothing. A captured mass stays a mass.
    func testACapturedCompoundsGoalUnitFollowsItsValuesDimension() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        // The value the parser reads from the panel, so the test is the one the finding names.
        let parsed = NutritionFactsParser.parse(lines: ["Vitamin A 900IU"])
        let vitaminA = try XCTUnwrap(parsed.additionalNutrient(for: "vitamin-a")?.value)
        XCTAssertEqual(vitaminA, .known(Decimal(900), .iu))
        let snapshot = ProductDefinition(
            snapshotID: "snapshot-vitamin-a", productID: "label_capture", name: "Synthetic Gummies",
            labelBasis: "per serving (30 g)", catalogOrigin: "label_capture", catalogVersion: "unknown",
            nutrients: ["vitamin-a": vitaminA, "creatine-monohydrate": .known(Decimal(3), .mg)])
        let intakeID = UUID().uuidString.lowercased()
        try journal.create(
            Intake(id: intakeID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "gummies", name: "Gummies", amount: Decimal(30), unit: .g)],
            product: snapshot, now: when)

        let model = GoalsViewModel(store: goals, journal: journal)
        model.load()

        XCTAssertTrue(model.offeredKeys.contains("vitamin-a"))
        XCTAssertEqual(model.unit(for: "vitamin-a"), .iu)
        XCTAssertEqual(model.units(for: "vitamin-a"), [.iu])
        XCTAssertTrue(model.setTarget("900", for: "vitamin-a"))
        XCTAssertEqual(try goals.goal(for: "vitamin-a")?.unit, .iu)

        // A compound stated as a mass stays in the mass dimension, not international units.
        XCTAssertEqual(model.unit(for: "creatine-monohydrate").dimension, .mass)
    }

    // MARK: A target has to be in the nutrient's own dimension

    /// A target in a dimension the nutrient is never counted in is refused rather than stored: "2 g"
    /// of energy and "2000 kcal" of water compare against nothing, and the screen could neither show
    /// them as met nor as missed. The expected dimension comes from the canonical nutrient mapping,
    /// so it is the unit the totals provider and the HealthKit writer already use.
    func testAGoalInTheWrongDimensionIsRefusedAndNothingIsStored() throws {
        let goals = try makeGoalStore()

        for goal in [
            NutrientGoal(nutrient: "energy", target: Decimal(2000), unit: .g),
            NutrientGoal(nutrient: "water", target: Decimal(2000), unit: .kcal),
            NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .kcal),
        ] {
            XCTAssertThrowsError(try goals.setGoal(goal), goal.nutrient) { error in
                XCTAssertEqual(
                    error as? UnitError,
                    .dimensionMismatch(
                        from: goal.unit, to: NutrientGoalChoices.unit(forKey: goal.nutrient)),
                    goal.nutrient)
            }
        }

        XCTAssertTrue(try goals.goals().isEmpty)
    }

    /// The screen refuses one too, rather than letting a caller pass a unit it never offered and
    /// leaving the write to fail as a save error.
    func testGoalsScreenRefusesATargetInTheWrongDimension() throws {
        let goals = try makeGoalStore()
        let model = GoalsViewModel(store: goals)

        XCTAssertFalse(model.setTarget("2000", for: "energy", unit: .g))
        XCTAssertEqual(model.errorMessage, GoalsViewModel.saveFailedMessage)
        XCTAssertTrue(try goals.goals().isEmpty)
    }

    // MARK: The goals screen

    /// The screen lists every offered nutrient, with a target's text where one is stored and the
    /// fact that there is none where there is not.
    func testGoalsScreenListsEveryOfferedNutrientAndTheStoredTargets() throws {
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))

        let model = GoalsViewModel(store: goals)
        model.load()

        XCTAssertEqual(model.rows.map { $0.nutrient }, NutrientGoalChoices.keys)
        let protein = try XCTUnwrap(model.rows.first { $0.nutrient == "protein" })
        XCTAssertEqual(protein.targetText, "60 g")
        XCTAssertEqual(protein.displayName, "Protein")
        let fiber = try XCTUnwrap(model.rows.first { $0.nutrient == "fiber" })
        XCTAssertNil(fiber.targetText)
    }

    /// Setting a target through the screen writes it, and clearing it removes it.
    func testGoalsScreenWritesAndClearsATarget() throws {
        let goals = try makeGoalStore()
        let model = GoalsViewModel(store: goals)
        model.load()

        XCTAssertTrue(model.setTarget("75", for: "protein"))
        XCTAssertEqual(
            model.rows.first { $0.nutrient == "protein" }?.targetText, "75 g")

        XCTAssertTrue(model.removeTarget(for: "protein"))
        XCTAssertNil(model.rows.first { $0.nutrient == "protein" }?.targetText)
        XCTAssertTrue(try goals.goals().isEmpty)
    }

    /// Text that is not a positive number is refused and writes nothing, rather than being rounded
    /// or guessed at into a target the person did not mean.
    func testGoalsScreenRefusesUnusableTargetTextAndWritesNothing() throws {
        let goals = try makeGoalStore()
        let model = GoalsViewModel(store: goals)

        for text in ["", "  ", "abc", "0", "-3", "1,5", "1e3", "1.2.3", "12g", "."] {
            XCTAssertFalse(model.setTarget(text, for: "protein"), text)
            XCTAssertEqual(model.errorMessage, "Enter a target above zero.", text)
        }

        XCTAssertTrue(try goals.goals().isEmpty)
    }

    /// A store that refuses the write says so instead of leaving the screen looking as if the target
    /// had been saved.
    func testGoalsScreenReportsAWriteItCouldNotMake() throws {
        let model = GoalsViewModel(store: InMemoryGoalStore(refusesWrites: true))

        XCTAssertFalse(model.setTarget("60", for: "protein"))
        XCTAssertEqual(model.errorMessage, GoalsViewModel.saveFailedMessage)
    }

    /// Every nutrient is offered only in the units its own totals are read in, so a target cannot be
    /// set in a dimension nothing on the screen would compare it against. Energy in grams was a
    /// category error rather than a rounding one: it was offered, accepted and stored, and the line
    /// then compared a kcal total against a gram target.
    ///
    /// The two ounces are excluded too, by the same rule the recipe editor applies. They are input and
    /// display units that Add intake normalises to grams and millilitres; a target is not normalised
    /// anywhere, so an ounce target would sit beside a gram total and the comparison would be between
    /// two numbers in different units. `UnitRegistry` grew them for display, and a nutrient's units
    /// are the ones its total is stored in, not the ones a person may type.
    func testGoalsScreenOffersEachNutrientOnlyInItsOwnDimension() {
        XCTAssertEqual(NutrientGoalChoices.unit(forKey: "water"), .mL)
        XCTAssertEqual(NutrientGoalChoices.unit(forKey: "energy"), .kcal)
        XCTAssertEqual(NutrientGoalChoices.unit(forKey: "protein"), .g)
        XCTAssertEqual(NutrientGoalChoices.unit(forKey: "sodium"), .mg)
        XCTAssertEqual(NutrientGoalChoices.units(forKey: "water"), [.mL, .L])
        XCTAssertEqual(NutrientGoalChoices.units(forKey: "energy"), [.kcal])
        XCTAssertEqual(NutrientGoalChoices.units(forKey: "protein"), [.g, .mg, .mcg, .kg])
        for key in NutrientGoalChoices.keys {
            let offered = NutrientGoalChoices.units(forKey: key)
            let dimension = NutrientGoalChoices.unit(forKey: key).dimension
            XCTAssertTrue(offered.allSatisfy { $0.dimension == dimension }, key)
            XCTAssertFalse(offered.contains(.oz), key)
            XCTAssertFalse(offered.contains(.flOz), key)
        }
    }

    /// A goal the person set survives the erase with everything else, which is what the Connections
    /// and privacy screen promises when it says "erase all data".
    func testAnEraseRemovesTheGoalsAlongWithEverythingElse() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try logOats(journal, grams: 400)
        let connections = ConnectionsPrivacyViewModel(
            store: journal, erasers: [journal, goals])
        XCTAssertTrue(connections.canEraseAll)

        XCTAssertTrue(connections.eraseAllData())

        XCTAssertTrue(try goals.goals().isEmpty)
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
    }

    /// After an erase the store still takes a write, so the app carries on with empty goals rather
    /// than a broken store.
    func testTheGoalStoreStillTakesAWriteAfterAnErase() throws {
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try goals.eraseAll()

        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(90), unit: .g))

        XCTAssertEqual(try goals.goal(for: "protein")?.target, Decimal(90))
    }

    func testGoalSectionsKeepTheirOrderAndGroupCompoundKeys() throws {
        let goals = InMemoryGoalStore(goals: [
            NutrientGoal(nutrient: "creatine-monohydrate", target: 3, unit: .g),
        ])
        let model = GoalsViewModel(store: goals)
        model.load()
        XCTAssertEqual(model.sections.map(\.title),
            ["Energy and macros", "Water", "Minerals", "From your labels"])
        XCTAssertEqual(model.sections[0].rows.map(\.nutrient),
            ["energy", "protein", "carbohydrate", "fat", "fiber"])
        XCTAssertEqual(model.sections[1].rows.map(\.nutrient), ["water"])
        XCTAssertEqual(model.sections[2].rows.map(\.nutrient), ["sodium", "potassium"])
        XCTAssertEqual(model.sections[3].rows.map(\.nutrient), ["creatine-monohydrate"])
        XCTAssertEqual(model.sections[3].rows.first?.detail, "Added by a scanned label")
    }

    func testBlankTargetRemovesTheGoal() throws {
        let goals = InMemoryGoalStore(goals: [
            NutrientGoal(nutrient: "protein", target: 60, unit: .g),
        ])
        let model = GoalsViewModel(store: goals)
        model.load()
        model.draftText["protein"] = "  "
        XCTAssertTrue(model.commitTarget(for: "protein"))
        XCTAssertNil(try goals.goal(for: "protein"))
        XCTAssertEqual(model.sections[0].rows.first { $0.nutrient == "protein" }?.targetText, "None")
    }

    func testClearAllGoalsAlsoRemovesStoredCompoundGoals() throws {
        let goals = InMemoryGoalStore(goals: [
            NutrientGoal(nutrient: "protein", target: 60, unit: .g),
            NutrientGoal(nutrient: "dha", target: 1, unit: .g),
        ])
        let model = GoalsViewModel(store: goals)
        model.load()
        XCTAssertTrue(model.clearAllGoals())
        XCTAssertTrue(try goals.goals().isEmpty)
        XCTAssertTrue(model.sections.flatMap(\.rows).allSatisfy { $0.targetText == "None" })
    }

    func testInlineTargetsMustBeAboveZero() throws {
        let goals = InMemoryGoalStore()
        let model = GoalsViewModel(store: goals)
        model.load()
        for text in ["0", "-5", "abc"] {
            model.draftText["protein"] = text
            XCTAssertFalse(model.commitTarget(for: "protein"))
            XCTAssertEqual(model.rowError["protein"], "Enter a number above zero.")
            XCTAssertTrue(try goals.goals().isEmpty)
        }
        model.draftText["protein"] = "75.5"
        XCTAssertTrue(model.commitTarget(for: "protein"))
        XCTAssertEqual(try goals.goal(for: "protein")?.target, Decimal(string: "75.5"))
        XCTAssertNil(model.rowError["protein"])
    }

    func testCommittingOneTargetKeepsAnotherUncommittedDraft() throws {
        let model = GoalsViewModel(store: InMemoryGoalStore())
        model.load()
        model.draftText["water"] = "1500"
        model.draftText["protein"] = "60"
        XCTAssertTrue(model.commitTarget(for: "protein"))
        XCTAssertEqual(model.draftText["water"], "1500")
    }

    func testInlineStoreFailuresStayNoticesAndKeepTheDraft() {
        let model = GoalsViewModel(store: InMemoryGoalStore(refusesWrites: true))
        model.load()
        model.draftText["protein"] = "60"
        XCTAssertFalse(model.commitTarget(for: "protein"))
        XCTAssertEqual(model.errorMessage, GoalsViewModel.saveFailedMessage)
        XCTAssertEqual(model.draftText["protein"], "60")
        XCTAssertNil(model.rowError["protein"])
    }
}
