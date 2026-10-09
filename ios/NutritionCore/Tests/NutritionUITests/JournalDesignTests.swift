import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The instant every journal design test loads at: 2023-11-14 22:13 UTC.
private let designNow = Date(timeIntervalSince1970: 1_700_000_000)
private let designDay: TimeInterval = 86_400

/// Read-only canned store. It holds intakes the real store would refuse to write, such as one with an
/// invalid time zone identifier, so the journal's skipped-entry path can be exercised.
private final class DesignCannedStore: JournalStore, @unchecked Sendable {
    var failNextSaveForTesting = false
    let intakes: [Intake]
    let components: [String: [IntakeComponent]]

    init(intakes: [Intake], components: [String: [IntakeComponent]]) {
        self.intakes = intakes
        self.components = components
    }

    private struct Unsupported: Error {}

    func create(_ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date) throws -> IntakeRevision { throw Unsupported() }
    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date? = nil, timeZoneIdentifier: String? = nil
    ) throws -> IntakeRevision { throw Unsupported() }
    func delete(intakeID: String, now: Date) throws { throw Unsupported() }
    func activeIntakes() throws -> [Intake] { intakes }
    func revisions(of intakeID: String) throws -> [IntakeRevision] {
        guard let list = components[intakeID] else { throw Unsupported() }
        return [IntakeRevision(
            intakeID: intakeID, number: 1, components: list, productSnapshotID: nil,
            changeReason: "test", createdAt: Date(timeIntervalSince1970: 0))]
    }
    func projections(of intakeID: String) throws -> [DestinationProjection] { [] }
    func pendingOutbox() throws -> [OutboxOperation] { [] }
    func product(snapshotID: String) throws -> ProductDefinition? { nil }
    func activeIntakesFromBackground() async throws -> [Intake] { intakes }
    func close() {}
}

/// Answers from the product snapshot an entry was recorded with, as Today's tests do. A snapshot
/// stating 13 g of protein per 100 g gives 5.2 g of protein for 40 g logged.
private struct DesignSnapshotFacts: NutrientFactsLookup {
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue {
        .unknown
    }

    func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue {
        snapshot?.value(for: nutrient) ?? .unknown
    }
}

/// The journal's day header, entry grouping, collapsed older days, empty state and skipped-entry
/// sentence, at view-model level with a fixed locale and time zone.
@MainActor
final class JournalDesignTests: XCTestCase {
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

    /// A product stating 13 g of protein per 100 g, with a synthetic name.
    private func oatsSnapshot() -> ProductDefinition {
        ProductDefinition(
            snapshotID: "snapshot-example-oats", productID: "product-example-oats", name: "Example oats",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["protein": .known(Decimal(13), .g)])
    }

    /// Logs one synthetic entry with a lowercase UUID id and returns that id.
    @discardableResult
    private func addEntry(
        _ store: JournalStore, name: String = "Example oats", at date: Date, zone: String = "UTC",
        category: String = "food", meal: String? = nil, product: ProductDefinition? = nil,
        grams: Decimal = 40, unit: MeasureUnit = .g
    ) throws -> String {
        let id = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: id, category: category, occurredAt: date, timeZoneIdentifier: zone, meal: meal),
            components: [IntakeComponent(componentID: "example-oats", name: name, amount: grams, unit: unit)],
            product: product, now: date)
        return id
    }

    private func makeModel(_ store: JournalStore, goals: GoalStore? = nil) -> JournalViewModel {
        JournalViewModel(
            store: store, goals: goals, lookup: DesignSnapshotFacts(), timeZoneIdentifier: "UTC",
            locale: Locale(identifier: "en_US"))
    }

    // MARK: Day header goal bars

    /// With protein and fiber goals stored, the header carries one bar per goal in the stored order
    /// (goals are stored sorted by nutrient key, so fiber comes before protein), and the protein bar
    /// names its goal. With four goals stored, only the first three are shown.
    func testDayHeaderBarsFollowStoredGoalsInOrderAndCapAtThree() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))
        try goals.setGoal(NutrientGoal(nutrient: "fiber", target: Decimal(30), unit: .g))
        try addEntry(journal, at: designNow, product: oatsSnapshot())

        let model = makeModel(journal, goals: goals)
        model.load(now: designNow)

        let bars = try XCTUnwrap(model.sections.first?.headerBars)
        XCTAssertEqual(bars.map(\.id), ["fiber", "protein"])
        let protein = try XCTUnwrap(bars.first { $0.id == "protein" })
        // 40 g of a product stating 13 g per 100 g carries 5.2 g of protein.
        XCTAssertEqual(protein.valueText, "5.2 g of 60 g")

        try goals.setGoal(NutrientGoal(nutrient: "calcium", target: Decimal(1000), unit: .mg))
        try goals.setGoal(NutrientGoal(nutrient: "sodium", target: Decimal(2300), unit: .mg))
        model.load(now: designNow)

        let capped = try XCTUnwrap(model.sections.first?.headerBars)
        XCTAssertEqual(capped.count, 3)
        XCTAssertEqual(capped.map(\.id), ["calcium", "fiber", "protein"])
    }

    /// With no goals stored there is nothing to show against, so the header has no bars.
    func testDayHeaderBarsAreEmptyWithNoGoals() throws {
        let journal = try makeJournalStore()
        let goals = try makeGoalStore()
        try addEntry(journal, at: designNow, product: oatsSnapshot())

        let model = makeModel(journal, goals: goals)
        model.load(now: designNow)

        XCTAssertEqual(try XCTUnwrap(model.sections.first).headerBars, [])
    }

    // MARK: Older days collapse

    /// An entry today and one ten days ago: the old day is collapsed by default and counts "1 entry",
    /// today's is not collapsed. The old day stays collapsed until it is toggled, then expanded, and
    /// toggling again collapses it.
    func testOlderDaysCollapseToACountUntilToggled() throws {
        let journal = try makeJournalStore()
        let todayID = try addEntry(journal, at: designNow)
        let old = designNow.addingTimeInterval(-10 * designDay)
        try addEntry(journal, at: old)

        let model = makeModel(journal)
        model.load(now: designNow)

        let todaySection = try XCTUnwrap(model.sections.first(where: { section in
            section.rows.contains { $0.id == todayID }
        }))
        let oldSection = try XCTUnwrap(model.sections.first(where: { section in
            section.id != todaySection.id
        }))
        XCTAssertFalse(todaySection.isCollapsedByDefault)
        XCTAssertTrue(oldSection.isCollapsedByDefault)
        XCTAssertEqual(oldSection.entryCountText, "1 entry")
        XCTAssertEqual(todaySection.entryCountText, "1 entry")

        XCTAssertFalse(model.isExpanded(oldSection))
        XCTAssertTrue(model.isExpanded(todaySection))
        model.toggleDay(oldSection.id)
        XCTAssertTrue(model.expandedDays.contains(oldSection.id))
        XCTAssertTrue(model.isExpanded(oldSection))
        model.toggleDay(oldSection.id)
        XCTAssertFalse(model.isExpanded(oldSection))
    }

    /// Two entries on one old day read as "2 entries".
    func testOlderDaysCollapseCountsEntriesOnOneDay() throws {
        let journal = try makeJournalStore()
        let old = designNow.addingTimeInterval(-10 * designDay)
        try addEntry(journal, at: old)
        try addEntry(journal, name: "Example rice", at: old.addingTimeInterval(60))

        let model = makeModel(journal)
        model.load(now: designNow)

        let section = try XCTUnwrap(model.sections.first)
        XCTAssertTrue(section.isCollapsedByDefault)
        XCTAssertEqual(section.entryCountText, "2 entries")
    }

    // MARK: Meal groups

    /// Breakfast, dinner, a water with no meal and a food with no meal on one day: the groups are
    /// titled "Breakfast", "Dinner", "Other" in that order, and "Other" holds both unlabeled rows
    /// newest first. A meal with no entries is left out.
    func testJournalMealGroupsAreTitledAndOrdered() throws {
        let journal = try makeJournalStore()
        let breakfast = try addEntry(journal, at: designNow, meal: "breakfast")
        let dinner = try addEntry(journal, name: "Example rice", at: designNow.addingTimeInterval(60), meal: "dinner")
        let food = try addEntry(journal, name: "Example nuts", at: designNow.addingTimeInterval(30))
        let water = try addEntry(
            journal, name: "Example water", at: designNow.addingTimeInterval(120), category: "water",
            grams: Decimal(250), unit: .mL)

        let model = makeModel(journal)
        model.load(now: designNow)

        let section = try XCTUnwrap(model.sections.first)
        XCTAssertEqual(section.mealGroups.map(\.title), ["Breakfast", "Dinner", "Other"])
        XCTAssertEqual(section.mealGroups.map { $0.rows.map(\.id) }, [[breakfast], [dinner], [water, food]])
    }

    // MARK: Empty journal

    /// The journal is empty only when nothing is listed: true after an empty load, false once there
    /// is one entry.
    func testJournalEmptyStateIsTrueOnlyWhenNothingIsListed() throws {
        let journal = try makeJournalStore()
        let model = makeModel(journal)

        model.load(now: designNow)
        XCTAssertTrue(model.isEmpty)

        try addEntry(journal, at: designNow)
        model.load(now: designNow)
        XCTAssertFalse(model.isEmpty)
    }

    // MARK: Unreadable entries sentence

    /// No skipped entries gives no sentence. One entry with an invalid time zone gives the singular
    /// sentence, and such an entry alone still makes the journal non-empty. Three give the plural.
    func testUnreadableEntriesSentenceIsSingularForOneAndPluralForMore() throws {
        let item = IntakeComponent(componentID: "example-oats", name: "Example oats", amount: Decimal(40), unit: .g)
        let badIDs = [
            "11111111-1111-4111-8111-111111111111",
            "22222222-2222-4222-8222-222222222222",
            "33333333-3333-4333-8333-333333333333",
        ]
        let components = Dictionary(uniqueKeysWithValues: badIDs.map { ($0, [item]) })
        func badIntake(_ id: String) -> Intake {
            Intake(id: id, category: "food", occurredAt: designNow, timeZoneIdentifier: "Not/AZone")
        }

        let none = makeModel(DesignCannedStore(intakes: [], components: [:]))
        none.load(now: designNow)
        XCTAssertNil(none.skippedText)

        let one = makeModel(DesignCannedStore(intakes: [badIntake(badIDs[0])], components: components))
        one.load(now: designNow)
        XCTAssertEqual(one.skippedCount, 1)
        XCTAssertEqual(
            one.skippedText,
            "1 entry can't be shown because its saved time or record can't be read.")
        XCTAssertFalse(one.isEmpty)

        let three = makeModel(DesignCannedStore(intakes: badIDs.map(badIntake), components: components))
        three.load(now: designNow)
        XCTAssertEqual(three.skippedCount, 3)
        XCTAssertEqual(
            three.skippedText,
            "3 entries can't be shown because their saved time or record can't be read.")
    }

    // MARK: Totals that cannot be answered

    /// A logged food with no protein value makes the protein bar say it cannot be totalled, not that
    /// nothing is logged. A day whose only entry is water has no food, so its protein bar says nothing
    /// is logged.
    func testDayHeaderBarsSayCannotTotalWhenALoggedFoodLacksTheValue() throws {
        let goals = try makeGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g))

        let foodDay = try makeJournalStore()
        // No product, so the lookup answers protein as unknown for this food, never as zero.
        try addEntry(foodDay, at: designNow)
        let foodModel = makeModel(foodDay, goals: goals)
        foodModel.load(now: designNow)
        let foodBar = try XCTUnwrap(foodModel.sections.first?.headerBars.first(where: { $0.id == "protein" }))
        XCTAssertEqual(foodBar.valueText, "Can't total yet")
        XCTAssertEqual(foodBar.state, .cannotTotal)

        let waterDay = try makeJournalStore()
        try addEntry(
            waterDay, name: "Example water", at: designNow, category: "water", grams: Decimal(250), unit: .mL)
        let waterModel = makeModel(waterDay, goals: goals)
        waterModel.load(now: designNow)
        let waterBar = try XCTUnwrap(waterModel.sections.first?.headerBars.first(where: { $0.id == "protein" }))
        XCTAssertEqual(waterBar.valueText, "Nothing logged yet")
        XCTAssertEqual(waterBar.state, .nothingLogged)
    }

    /// A day whose only food states no energy has no energy figure at all, not "0 kcal". A food that
    /// states energy shows its day figure with the kcal symbol, read from its own snapshot at 100 g of
    /// a per-100 g basis, so the figure is exactly 400 kcal.
    func testDayHeaderEnergyTextIsNilWhenTheDayCannotBeTotalled() throws {
        let noEnergy = try makeJournalStore()
        try addEntry(noEnergy, at: designNow, product: oatsSnapshot())
        let noEnergyModel = makeModel(noEnergy)
        noEnergyModel.load(now: designNow)
        XCTAssertNil(try XCTUnwrap(noEnergyModel.sections.first).energyText)

        let energyProduct = ProductDefinition(
            snapshotID: "snapshot-example-energy", productID: "product-example-energy", name: "Example bar",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["energy": .known(Decimal(400), .kcal)])
        let withEnergy = try makeJournalStore()
        try addEntry(withEnergy, at: designNow, product: energyProduct, grams: Decimal(100))
        let withEnergyModel = makeModel(withEnergy)
        withEnergyModel.load(now: designNow)
        let energy = try XCTUnwrap(withEnergyModel.sections.first?.energyText)
        XCTAssertTrue(energy.contains("kcal"), energy)
        XCTAssertEqual(energy, "400 kcal")
    }

    // MARK: Day age per entry, and goals that cannot be read

    /// An instant in UTC, built with a UTC calendar so the arithmetic in the comments is checkable.
    private func utcInstant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? designNow
    }

    /// Each entry is judged in its own zone. Pacific/Kiritimati is UTC+14 and Pacific/Pago_Pago is
    /// UTC-11, so their local dates are at most one day apart for `now` below.
    ///
    /// now = 2023-11-08 12:00 UTC.
    /// - Pago Pago local date: Nov 8 01:00, so today's key is 2023-11-08. Kiritimati local: Nov 9 02:00,
    ///   so today's key is 2023-11-09.
    ///
    /// Case 1, the shared day key 2023-11-01:
    /// - Pago entry: Nov 1 12:00 local = Nov 1 23:00 UTC. Age 2023-11-08 minus 2023-11-01 = 7 days, not
    ///   more than 7, so not collapsed.
    /// - Kiritimati entry: Nov 1 12:00 local = Oct 31 22:00 UTC. Age 2023-11-09 minus 2023-11-01 = 8
    ///   days, more than 7, so collapsed.
    /// - The day is collapsed only when every row is, so the day is not collapsed.
    ///
    /// Case 2, the shared day key 2023-10-31:
    /// - Pago entry: Oct 31 12:00 local = Oct 31 23:00 UTC. Age 2023-11-08 minus 2023-10-31 = 8 days.
    /// - Kiritimati entry: Oct 31 12:00 local = Oct 30 22:00 UTC. Age 2023-11-09 minus 2023-10-31 = 9 days.
    /// - Both are more than 7 days old, so the day is collapsed.
    func testOlderDaysCollapseJudgesEachEntryInItsOwnZone() throws {
        let now = utcInstant(2023, 11, 8, 12)

        let mixed = try makeJournalStore()
        try addEntry(mixed, at: utcInstant(2023, 11, 1, 23), zone: "Pacific/Pago_Pago")
        try addEntry(mixed, at: utcInstant(2023, 10, 31, 22), zone: "Pacific/Kiritimati")
        let mixedModel = makeModel(mixed)
        mixedModel.load(now: now)
        XCTAssertEqual(mixedModel.sections.map(\.id), ["2023-11-01"])
        XCTAssertFalse(try XCTUnwrap(mixedModel.sections.first).isCollapsedByDefault)

        let bothOld = try makeJournalStore()
        try addEntry(bothOld, at: utcInstant(2023, 10, 31, 23), zone: "Pacific/Pago_Pago")
        try addEntry(bothOld, at: utcInstant(2023, 10, 30, 22), zone: "Pacific/Kiritimati")
        let bothOldModel = makeModel(bothOld)
        bothOldModel.load(now: now)
        XCTAssertEqual(bothOldModel.sections.map(\.id), ["2023-10-31"])
        XCTAssertTrue(try XCTUnwrap(bothOldModel.sections.first).isCollapsedByDefault)
    }

    /// A goal store whose every read fails, as a store that cannot be opened would.
    private final class UnreadableGoalStore: GoalStore, @unchecked Sendable {
        private struct Unreadable: Error {}

        func goals() throws -> [NutrientGoal] { throw Unreadable() }
        func goal(for nutrient: String) throws -> NutrientGoal? { throw Unreadable() }
        func setGoal(_ goal: NutrientGoal) throws { throw Unreadable() }
        func removeGoal(nutrient: String) throws { throw Unreadable() }
        func close() {}
    }

    /// A goal store that cannot be read is reported beside the day, and the days are still listed. A
    /// readable goal store with no goals reports nothing.
    func testJournalReportsGoalsThatCannotBeRead() throws {
        let journal = try makeJournalStore()
        try addEntry(journal, at: designNow)

        let broken = makeModel(journal, goals: UnreadableGoalStore())
        broken.load(now: designNow)
        XCTAssertEqual(broken.goalsErrorMessage, GoalsViewModel.readFailedMessage)
        XCTAssertEqual(broken.sections.count, 1)
        XCTAssertEqual(try XCTUnwrap(broken.sections.first).headerBars, [])
        XCTAssertNil(broken.errorMessage)

        let readableGoals = try makeGoalStore()
        let working = makeModel(journal, goals: readableGoals)
        working.load(now: designNow)
        XCTAssertNil(working.goalsErrorMessage)
    }
}
