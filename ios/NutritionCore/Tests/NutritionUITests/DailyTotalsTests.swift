import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The one instant every test logs at, unless it says otherwise. A file-scope constant so it is the
/// same instant for every case without each one setting it up.
private let when = Date(timeIntervalSince1970: 1_700_000_000)

/// A lookup that answers from the product snapshot the component was recorded with, which is what
/// the app injects.
private struct SnapshotOnlyFacts: NutrientFactsLookup {
    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue {
        .unknown
    }

    func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue {
        snapshot?.value(for: nutrient) ?? .unknown
    }
}

@MainActor
final class DailyTotalsTests: XCTestCase {
    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// A product whose stated protein is per 100 g, the shape a barcode lookup records.
    private func oatsSnapshot() -> ProductDefinition {
        ProductDefinition(
            snapshotID: "snapshot-oats", productID: "product-oats", name: "Rolled oats",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["protein": .known(Decimal(13), .g)])
    }

    @discardableResult
    private func addFood(
        _ store: JournalStore, name: String, id: String, at date: Date, zone: String = "UTC",
        amount: Decimal = 40, unit: MeasureUnit = .g, product: ProductDefinition? = nil
    ) throws -> String {
        let intakeID = UUID().uuidString.lowercased()
        let intake = Intake(id: intakeID, category: "food", occurredAt: date, timeZoneIdentifier: zone)
        try store.create(
            intake, components: [IntakeComponent(componentID: id, name: name, amount: amount, unit: unit)],
            product: product, now: date)
        return intakeID
    }

    @discardableResult
    private func addWater(
        _ store: JournalStore, at date: Date, zone: String = "UTC", amount: Decimal = 250, unit: MeasureUnit = .mL
    ) throws -> String {
        let intakeID = UUID().uuidString.lowercased()
        let intake = Intake(id: intakeID, category: "water", occurredAt: date, timeZoneIdentifier: zone)
        try store.create(
            intake, components: [IntakeComponent(componentID: "water", name: "Water", amount: amount, unit: unit)],
            product: nil, now: date)
        return intakeID
    }

    // MARK: Two days stay apart

    /// The requirement this type exists for: a day is summed from its own entries. Day two must not
    /// absorb day one's water or protein, and day one must not absorb day two's.
    func testTotalsKeepTwoLocalDaysApartAndNeitherAbsorbsTheOther() throws {
        let store = try makeStore()
        try addWater(store, at: when, amount: 300)
        try addFood(store, name: "Oats", id: "oats", at: when, amount: 100, product: oatsSnapshot())
        // The next UTC day, well clear of midnight either side of the boundary.
        let tomorrow = when.addingTimeInterval(86_400)
        try addWater(store, at: tomorrow, amount: 500)
        try addFood(store, name: "Oats", id: "oats", at: tomorrow, amount: 200, product: oatsSnapshot())

        let all = try store.activeIntakes()
        let firstDay = all.filter { $0.occurredAt < tomorrow }
        let secondDay = all.filter { $0.occurredAt >= tomorrow }
        XCTAssertEqual(firstDay.count, 2)
        XCTAssertEqual(secondDay.count, 2)

        let today = try DailyTotalsBuilder.totals(
            for: firstDay, store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein", "water"])
        let second = try DailyTotalsBuilder.totals(
            for: secondDay, store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein", "water"])

        // Day one is 100 g of the per-100 g product and 300 mL of water; day two is 200 g and 500 mL.
        // Neither picks up the other's, so neither figure is the two days added together.
        XCTAssertEqual(today.total(for: "protein")?.value, .known(Decimal(13), .g))
        XCTAssertEqual(today.total(for: "water")?.value, .known(Decimal(300), .mL))
        XCTAssertEqual(second.total(for: "protein")?.value, .known(Decimal(26), .g))
        XCTAssertEqual(second.total(for: "water")?.value, .known(Decimal(500), .mL))
    }

    /// The two days as the journal groups them, each carrying only its own water. This is the check that
    /// the grouping the totals hang off never merges two days into one figure.
    func testJournalDayTotalsReportEachDaysOwnWaterSeparately() throws {
        let store = try makeStore()
        try addWater(store, at: when, amount: 300)
        let tomorrow = when.addingTimeInterval(86_400)
        try addWater(store, at: tomorrow, amount: 500)

        let all = try store.activeIntakes()
        let firstKey = JournalViewModel.dayKey(when, zone: try XCTUnwrap(TimeZone(identifier: "UTC")))
        let secondKey = JournalViewModel.dayKey(
            tomorrow, zone: try XCTUnwrap(TimeZone(identifier: "UTC")))
        XCTAssertNotEqual(firstKey, secondKey)

        let first = try DailyTotalsBuilder.totals(
            for: all.filter { $0.occurredAt < tomorrow }, store: store, lookup: SnapshotOnlyFacts(),
            nutrients: ["water"])
        let second = try DailyTotalsBuilder.totals(
            for: all.filter { $0.occurredAt >= tomorrow }, store: store, lookup: SnapshotOnlyFacts(),
            nutrients: ["water"])

        XCTAssertEqual(first.total(for: "water")?.value, .known(Decimal(300), .mL))
        XCTAssertEqual(second.total(for: "water")?.value, .known(Decimal(500), .mL))
    }

    /// One instant logged twice, in two time zones where it is two different local days. Grouping by
    /// each intake's own time zone is what keeps them apart: an hour of real time cannot be counted
    /// into both days, and neither day may show the other's water.
    func testDayTotalsUseEachIntakesOwnTimeZoneAndNeverMixTwoDays() throws {
        let store = try makeStore()
        try addWater(store, at: when, zone: "UTC", amount: 300)
        try addWater(store, at: when, zone: "Pacific/Auckland", amount: 700)

        let all = try store.activeIntakes()
        let utcKey = JournalViewModel.dayKey(when, zone: try XCTUnwrap(TimeZone(identifier: "UTC")))
        let aucklandKey = JournalViewModel.dayKey(
            when, zone: try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland")))
        XCTAssertNotEqual(utcKey, aucklandKey)

        let utcDay = try DailyTotalsBuilder.totals(
            for: all.filter { $0.timeZoneIdentifier == "UTC" }, store: store,
            lookup: SnapshotOnlyFacts(), nutrients: ["water"])
        let aucklandDay = try DailyTotalsBuilder.totals(
            for: all.filter { $0.timeZoneIdentifier == "Pacific/Auckland" }, store: store,
            lookup: SnapshotOnlyFacts(), nutrients: ["water"])

        XCTAssertEqual(utcDay.total(for: "water")?.value, .known(Decimal(300), .mL))
        XCTAssertEqual(aucklandDay.total(for: "water")?.value, .known(Decimal(700), .mL))
    }

    // MARK: Scaling

    /// A per-100 g snapshot with 40 g logged is 0.4 of the product, so it carries 0.4 of 13 g. An
    /// unscaled sum would report the whole package's protein as though all of it were eaten.
    func testAPerHundredGramSnapshotWithFortyGramsLoggedContributesTheScaledAmount() throws {
        let store = try makeStore()
        try addFood(store, name: "Oats", id: "oats", at: when, amount: 40, product: oatsSnapshot())

        let intake = try XCTUnwrap(try store.activeIntakes().first)

        let totals = try DailyTotalsBuilder.totals(
            for: [intake], store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein"])

        // 13 g per 100 g, 40 g logged: 13 * 0.4 = 5.2 g, as an exact decimal.
        XCTAssertEqual(totals.total(for: "protein")?.value, .known(Decimal(string: "5.2")!, .g))
    }

    /// 100 g of a per-100 g product is the whole stated value, exactly and with no rounding.
    func testASnapshotAtItsOwnBasisContributesExactlyItsStatedValue() throws {
        let store = try makeStore()
        try addFood(store, name: "Oats", id: "oats", at: when, amount: 100, product: oatsSnapshot())
        let intake = try XCTUnwrap(try store.activeIntakes().first { $0.category == "food" })

        let totals = try DailyTotalsBuilder.totals(
            for: [intake], store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein"])

        XCTAssertEqual(totals.total(for: "protein")?.value, .known(Decimal(13), .g))
    }

    /// Two entries of the same product add up, each scaled by its own logged amount.
    func testTwoEntriesOfOneProductAreScaledAndAddedSeparately() throws {
        let store = try makeStore()
        try addFood(store, name: "Oats", id: "oats", at: when, amount: 40, product: oatsSnapshot())
        try addFood(store, name: "Oats", id: "oats", at: when, amount: 60, product: oatsSnapshot())
        let intakes = try store.activeIntakes().filter { $0.category == "food" }

        let totals = try DailyTotalsBuilder.totals(
            for: intakes, store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein"])

        XCTAssertEqual(totals.total(for: "protein")?.value, .known(Decimal(13), .g))
    }

    /// An entry with no product snapshot has no basis to scale by, so the nutrient stays unknown
    /// rather than reading as zero.
    func testAnEntryWithNoSnapshotLeavesTheNutrientUnknownRatherThanZero() throws {
        let store = try makeStore()
        try addFood(store, name: "Banana", id: "banana", at: when)
        let intake = try XCTUnwrap(try store.activeIntakes().first)

        let totals = try DailyTotalsBuilder.totals(
            for: [intake], store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein"])

        let total = try XCTUnwrap(totals.total(for: "protein"))
        XCTAssertEqual(total.value, .unknown)
        XCTAssertTrue(total.coverage.hasUnknown)
        XCTAssertEqual(total.coverage.knownCount, 0)
    }

    // MARK: Unresolvable basis

    /// "per 100 g or mL" states the source did not resolve its own dimension, so the stated value is
    /// for some other amount than the one logged. It is unknown, and crucially not zero: a zero
    /// would report the day as having less protein than was actually eaten.
    func testAnUnresolvableSnapshotBasisLeavesTheNutrientUnknownNotZero() throws {
        let store = try makeStore()
        let ambiguous = ProductDefinition(
            snapshotID: "snapshot-ambiguous", productID: "product-ambiguous", name: "Mystery bar",
            labelBasis: "per 100 g or mL", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["protein": .known(Decimal(13), .g)])
        try addFood(store, name: "Mystery bar", id: "bar", at: when, product: ambiguous)
        let intake = try XCTUnwrap(try store.activeIntakes().first)

        let totals = try DailyTotalsBuilder.totals(
            for: [intake], store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein"])

        let total = try XCTUnwrap(totals.total(for: "protein"))
        XCTAssertEqual(total.value, .unknown)
        XCTAssertTrue(total.coverage.hasUnknown)
        XCTAssertNotEqual(total.value, .known(0, .g))
    }

    /// One entry whose basis cannot be resolved makes the day's total unknown even though another
    /// entry resolved fine. Dropping the unresolvable one and reporting the rest would be a smaller
    /// number presented as the day's true total.
    func testAnUnresolvableBasisAmongSeveralEntriesMakesTheWholeNutrientUnknown() throws {
        let store = try makeStore()
        try addFood(store, name: "Oats", id: "oats", at: when, amount: 100, product: oatsSnapshot())
        let ambiguous = ProductDefinition(
            snapshotID: "snapshot-ambiguous", productID: "product-ambiguous", name: "Mystery bar",
            labelBasis: "per 100 kcal", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["protein": .known(Decimal(13), .g)])
        try addFood(store, name: "Mystery bar", id: "bar", at: when, product: ambiguous)
        let intakes = try store.activeIntakes().filter { $0.category == "food" }

        let totals = try DailyTotalsBuilder.totals(
            for: intakes, store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein"])

        let total = try XCTUnwrap(totals.total(for: "protein"))
        XCTAssertEqual(total.value, .unknown)
        XCTAssertTrue(total.coverage.hasUnknown)
    }

    /// A per-count basis scales by the number logged, so two servings of a per-serving product carry
    /// twice the stated value.
    func testAPerCountBasisMultipliesByTheNumberLogged() throws {
        let store = try makeStore()
        let perServing = ProductDefinition(
            snapshotID: "snapshot-serving", productID: "product-serving", name: "Protein powder",
            labelBasis: "per serving", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["protein": .known(Decimal(20), .g)])
        try addFood(store, name: "Powder", id: "powder", at: when, amount: 2, unit: .serving, product: perServing)
        let intake = try XCTUnwrap(try store.activeIntakes().first)

        let totals = try DailyTotalsBuilder.totals(
            for: [intake], store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein"])

        XCTAssertEqual(totals.total(for: "protein")?.value, .known(Decimal(40), .g))
    }

    // MARK: Water

    /// Water is measured on the entry itself, so its volume is the amount and needs no scaling.
    func testWaterOnTheEntryIsSummedDirectlyFromItsOwnVolume() throws {
        let store = try makeStore()
        try addWater(store, at: when, amount: 250)
        try addWater(store, at: when, amount: Decimal(string: "0.5")!, unit: .L)
        let intakes = try store.activeIntakes().filter { $0.category == "water" }

        let totals = try DailyTotalsBuilder.totals(
            for: intakes, store: store, lookup: SnapshotOnlyFacts(), nutrients: ["water"])

        XCTAssertEqual(totals.total(for: "water")?.value, .known(Decimal(750), .mL))
    }

    /// A water entry in a unit that is not a volume cannot say how much water it was, so it is
    /// unknown rather than zero.
    func testWaterInANonVolumeUnitIsUnknownNotZero() throws {
        let store = try makeStore()
        let intakeID = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: intakeID, category: "water", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "water", name: "Water", amount: 2, unit: .tablet)],
            product: nil, now: when)
        let intake = try XCTUnwrap(try store.activeIntakes().first)

        let totals = try DailyTotalsBuilder.totals(
            for: [intake], store: store, lookup: SnapshotOnlyFacts(), nutrients: ["water"])

        let total = try XCTUnwrap(totals.total(for: "water"))
        XCTAssertEqual(total.value, .unknown)
        XCTAssertNotEqual(total.value, .known(0, .mL))
    }

    /// Water on an entry that is not a water entry does not count: a food can carry a volume
    /// component, and that is not a glass of water the person drank.
    func testWaterOnAFoodEntryIsNotCountedAsWaterDrunk() throws {
        let store = try makeStore()
        let intakeID = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: intakeID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "yoghurt", name: "Yoghurt", amount: 200, unit: .g)],
            product: nil, now: when)
        let intake = try XCTUnwrap(try store.activeIntakes().first)

        let totals = try DailyTotalsBuilder.totals(
            for: [intake], store: store, lookup: SnapshotOnlyFacts(), nutrients: ["water"])

        XCTAssertEqual(totals.total(for: "water")?.value, .unknown)
    }

    /// A day with nothing logged at all is unknown for every nutrient, not zero: "nothing eaten" and
    /// "nothing known about what was eaten" are different, and the second is what an empty day is.
    func testAnEmptyDayIsUnknownForEveryNutrientRatherThanZero() throws {
        let store = try makeStore()

        let totals = try DailyTotalsBuilder.totals(
            for: [], store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein", "water"])

        for nutrient in ["protein", "water"] {
            let total = try XCTUnwrap(totals.total(for: nutrient))
            XCTAssertEqual(total.value, .unknown, nutrient)
            XCTAssertFalse(total.coverage.hasUnknown, nutrient)
        }
    }

    /// The journal's day sections each carry their own `DailyTotals`, so the figure a day shows is
    /// read off the same object as its rows rather than recomputed somewhere else.
    func testJournalDaySectionsCarryTheirOwnDayTotals() throws {
        let store = try makeStore()
        try addWater(store, at: when, amount: 300)
        let tomorrow = when.addingTimeInterval(86_400)
        try addWater(store, at: tomorrow, amount: 500)

        let model = JournalViewModel(store: store, lookup: SnapshotOnlyFacts(), locale: Locale(identifier: "en_US_POSIX"))
        model.load(now: tomorrow)

        XCTAssertEqual(model.sections.count, 2)
        // Newest day first, each carrying only its own water.
        XCTAssertEqual(model.sections[0].id, JournalViewModel.dayKey(
            tomorrow, zone: try XCTUnwrap(TimeZone(identifier: "UTC"))))
        XCTAssertEqual(
            model.sections[0].totals.total(for: "water")?.value, .known(Decimal(500), .mL))
        XCTAssertEqual(
            model.sections[1].totals.total(for: "water")?.value, .known(Decimal(300), .mL))
    }

    /// A day section with nothing known about any nutrient says so, rather than printing an empty
    /// line that reads as a day with no food in it.
    func testJournalDayTotalsSayWhenNothingCanBeSummed() throws {
        let store = try makeStore()
        try addFood(store, name: "Banana", id: "banana", at: when)

        let model = JournalViewModel(store: store, lookup: SnapshotOnlyFacts(), locale: Locale(identifier: "en_US_POSIX"))
        model.load(now: when)

        XCTAssertEqual(model.sections.first?.totalsText, "No totals for this day.")
    }

    /// A goal in the journal's per-day line comes first, so the comparison a person set is the
    /// first thing the line says.
    func testJournalDayTotalsPutNutrientsWithAGoalFirst() throws {
        let store = try makeStore()
        try addFood(store, name: "Oats", id: "oats", at: when, amount: 100, product: oatsSnapshot())
        let goals = InMemoryGoalStore(goals: [NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g)])

        let model = JournalViewModel(store: store, goals: goals, lookup: SnapshotOnlyFacts(), locale: Locale(identifier: "en_US_POSIX"))
        model.load(now: when)

        XCTAssertEqual(model.sections.first?.totalsText, "Protein 13 g of 60 g")
    }

    // MARK: Tracked order

    /// The tracked list is the goals' keys with the fallback's keys added where no goal exists, so a
    /// goal for a nutrient outside the fallback is shown and a fallback nutrient without a goal is
    /// still tracked.
    func testTrackedNutrientsAreTheGoalKeysPlusTheFallbackOnesWithoutAGoal() {
        let goals = [
            NutrientGoal(nutrient: "zinc", target: Decimal(11), unit: .mg),
            NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g),
        ]

        let tracked = TodayViewModel.defaultTrackedNutrientsOrGoals(goals: goals)

        XCTAssertEqual(Array(tracked.prefix(2)), ["protein", "zinc"])
        // Potassium, sodium and fiber are in the fallback and have no goal, so they are still tracked.
        XCTAssertEqual(Set(tracked), Set(["protein", "zinc", "potassium", "sodium", "fiber"]))
    }

    /// The progress line for one nutrient: with a target, without one, and when the day is unknown.
    func testProgressLineReadsTheTargetOnlyWhereOneIsSet() {
        let known = NutrientTotal(
            value: .known(Decimal(42), .g),
            coverage: Coverage(knownCount: 1, totalCount: 1, hasBelowReportingThreshold: false, hasUnknown: false))
        let unknown = NutrientTotal(
            value: .unknown,
            coverage: Coverage(knownCount: 0, totalCount: 1, hasBelowReportingThreshold: false, hasUnknown: true))

        XCTAssertEqual(
            NutrientProgressLine.make(
                nutrient: "protein", total: known, goal: NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g)
            ).text,
            "Protein 42 g of 60 g")
        XCTAssertEqual(
            NutrientProgressLine.make(nutrient: "protein", total: known, goal: nil).text,
            "Protein 42 g")
        XCTAssertEqual(
            NutrientProgressLine.make(
                nutrient: "protein", total: unknown,
                goal: NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g)
            ).text,
            "Protein unknown")
    }

    /// A target in the same unit the total is counted in. A target in another metric unit is shown
    /// as it was set rather than silently converted, so the comparison shown is the one entered.
    func testProgressLineKeepsATargetInTheUnitItWasSetIn() {
        let total = NutrientTotal(
            value: .known(Decimal(2500), .mg),
            coverage: Coverage(knownCount: 1, totalCount: 1, hasBelowReportingThreshold: false, hasUnknown: false))

        XCTAssertEqual(
            NutrientProgressLine.make(
                nutrient: "sodium", total: total,
                goal: NutrientGoal(nutrient: "sodium", target: Decimal(2.3), unit: .g)
            ).text,
            "Sodium 2500 mg of 2.3 g")
    }
}
