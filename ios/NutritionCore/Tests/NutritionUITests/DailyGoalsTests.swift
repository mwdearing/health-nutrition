import Foundation
import NutritionDomain
import NutritionJournal
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

    /// A goal store that cannot be read leaves the totals readable, as plain totals, rather than
    /// failing the whole screen: the day is still knowable even when the targets are not.
    func testAnUnreadableGoalStoreStillShowsTheDaysTotals() throws {
        let journal = try makeJournalStore()
        let refusing = InMemoryGoalStore(failNextRead: true)
        try logWater(journal, milliliters: 300)

        let model = TodayViewModel(store: journal, goals: refusing, lookup: SnapshotOnlyFacts())
        model.load(now: when)

        XCTAssertEqual(line(model, "water"), "Water 300 mL")
        XCTAssertNil(model.errorMessage)
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

    /// Water is offered in volumes and the other nutrients in masses, so a target cannot be set in a
    /// unit its totals are never counted in.
    func testGoalsScreenOffersWaterInVolumesAndOtherNutrientsInMasses() throws {
        XCTAssertEqual(NutrientGoalChoices.unit(forKey: "water"), .mL)
        XCTAssertEqual(NutrientGoalChoices.unit(forKey: "protein"), .g)
        for unit in NutrientGoalChoices.units(forKey: "water") {
            XCTAssertEqual(unit.dimension, .volume)
        }
        for unit in NutrientGoalChoices.units(forKey: "protein") {
            XCTAssertTrue(unit.dimension == .mass || unit.dimension == .energy)
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
}
