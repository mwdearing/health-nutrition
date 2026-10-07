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

    /// A barcode lookup or a label panel that knows how big a serving is stores "per serving (30 g)",
    /// and the entry records the food as an amount. The stated serving and the amount logged together
    /// say how many servings were eaten, so a per-count basis the log cannot answer is not left
    /// unknown: 30 g is the stated value and 60 g is twice it.
    func testAPerServingBasisWithAMassComponentScalesFromTheStatedServing() throws {
        let store = try makeStore()
        let powder = ProductDefinition(
            snapshotID: "snapshot-powder", productID: "product-powder", name: "Protein powder",
            labelBasis: "per serving (30 g)", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["protein": .known(Decimal(20), .g)])
        try addFood(store, name: "Powder", id: "powder", at: when, amount: 30, product: powder)
        try addFood(store, name: "Powder", id: "powder", at: when, amount: 60, product: powder)
        let intakes = try store.activeIntakes().filter { $0.category == "food" }

        let totals = try DailyTotalsBuilder.totals(
            for: intakes, store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein"])

        // One serving and two of them: 20 g and 40 g.
        XCTAssertEqual(totals.total(for: "protein")?.value, .known(Decimal(60), .g))
    }

    /// A serving stated in millilitres scales exactly as one stated in grams: what matters is that the
    /// serving and the amount logged are in the same dimension, not which one that is. A label
    /// capture of a liquid supplement records "per serving (240 mL)" and the entry is logged in mL.
    func testAPerServingBasisWithAVolumeComponentScalesFromTheStatedServing() throws {
        let store = try makeStore()
        let broth = ProductDefinition(
            snapshotID: "snapshot-broth", productID: "product-broth", name: "Broth",
            labelBasis: "per serving (240 mL)", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["protein": .known(Decimal(6), .g)])
        // 240 mL is one serving and 480 mL is two, whatever the nutrient itself is weighed in.
        try addFood(store, name: "Broth", id: "broth", at: when, amount: 240, unit: .mL, product: broth)
        try addFood(store, name: "Broth", id: "broth", at: when, amount: 480, unit: .mL, product: broth)
        let intakes = try store.activeIntakes().filter { $0.category == "food" }

        let totals = try DailyTotalsBuilder.totals(
            for: intakes, store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein"])

        XCTAssertEqual(totals.total(for: "protein")?.value, .known(Decimal(18), .g))
    }

    /// The logged amount is converted into the stated serving's unit rather than compared in whatever
/// unit it was written: 0.48 L is 480 mL, which is two of a 240 mL serving. Taking the 0.48 as if it
/// were millilitres would give a thousandth of the answer.
    func testAPerServingBasisConvertsTheLoggedAmountIntoTheStatedServing() throws {
        let store = try makeStore()
        let broth = ProductDefinition(
            snapshotID: "snapshot-broth", productID: "product-broth", name: "Broth",
            labelBasis: "per serving (240 mL)", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["protein": .known(Decimal(6), .g)])
        try addFood(
            store, name: "Broth", id: "broth", at: when, amount: Decimal(string: "0.48")!, unit: .L,
            product: broth)
        let intake = try XCTUnwrap(try store.activeIntakes().first)

        let totals = try DailyTotalsBuilder.totals(
            for: [intake], store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein"])

        XCTAssertEqual(totals.total(for: "protein")?.value, .known(Decimal(12), .g))
    }

    /// A serving stated one way and the amount logged in another say nothing comparable, so the day
    /// stays unknown rather than being scaled by a ratio of two different dimensions.
    func testAPerServingBasisWhoseDimensionTheLogDoesNotMatchLeavesTheNutrientUnknown() throws {
        let store = try makeStore()
        let broth = ProductDefinition(
            snapshotID: "snapshot-broth", productID: "product-broth", name: "Broth",
            labelBasis: "per serving (240 mL)", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["protein": .known(Decimal(6), .g)])
        try addFood(store, name: "Broth", id: "broth", at: when, amount: 40, unit: .g, product: broth)
        let intake = try XCTUnwrap(try store.activeIntakes().first)

        let totals = try DailyTotalsBuilder.totals(
            for: [intake], store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein"])

        XCTAssertEqual(totals.total(for: "protein")?.value, .unknown)
    }

    /// A serving stated in a way that is not a quantity — not at all, or a count of biscuits — says
    /// nothing this can scale by, so the day stays unknown rather than being scaled by a guess.
    func testAPerServingBasisThatStatesNoQuantityLeavesTheNutrientUnknown() throws {
        let store = try makeStore()
        for basis in ["per serving", "per serving (1 large biscuit)", "per serving (a handful)"] {
            let snapshot = ProductDefinition(
                snapshotID: "snapshot-\(basis)", productID: "product-\(basis)", name: "Biscuit",
                labelBasis: basis, catalogOrigin: "test", catalogVersion: "1",
                nutrients: ["protein": .known(Decimal(6), .g)])
            try addFood(store, name: "Biscuit", id: "biscuit", at: when, amount: 40, product: snapshot)
        }
        let intakes = try store.activeIntakes().filter { $0.category == "food" }

        let totals = try DailyTotalsBuilder.totals(
            for: intakes, store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein"])

        XCTAssertEqual(totals.total(for: "protein")?.value, .unknown)
    }

    // MARK: Stored under a nutrient's other keys

    /// A barcode snapshot keeps the keys `LookedUpProduct.standardKeys` names, so it stores its energy
    /// as `energyKcal` and its carbohydrate as `carbohydrates` while a goal and Today ask for
    /// `energy` and `carbohydrate`. Read through the canonical mapping rather than by an exact
    /// dictionary lookup, the day is what the person actually ate.
    func testABarcodeSnapshotIsReadThroughTheCanonicalKeysTheGoalsUse() throws {
        let store = try makeStore()
        let bar = ProductDefinition(
            snapshotID: "snapshot-bar", productID: "product-bar", name: "Breakfast bar",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: [
                "energyKcal": .known(Decimal(400), .kcal),
                "carbohydrates": .known(Decimal(30), .g),
                "protein": .known(Decimal(13), .g),
            ])
        try addFood(store, name: "Bar", id: "bar", at: when, amount: 200, product: bar)
        let intake = try XCTUnwrap(try store.activeIntakes().first)

        let totals = try DailyTotalsBuilder.totals(
            for: [intake], store: store, lookup: SnapshotOnlyFacts(),
            nutrients: ["energy", "carbohydrate", "protein"])

        // 200 g of a product stating these per 100 g, so twice each.
        XCTAssertEqual(totals.total(for: "energy")?.value, .known(Decimal(800), .kcal))
        XCTAssertEqual(totals.total(for: "carbohydrate")?.value, .known(Decimal(60), .g))
        XCTAssertEqual(totals.total(for: "protein")?.value, .known(Decimal(26), .g))
    }

    /// The canonical key leads, so a snapshot that states both an alias and the canonical key is read
    /// once and never counted twice. Reading the alias first would double the day's energy.
    func testTheCanonicalKeyIsReadBeforeItsAliasSoOneValueIsNotCountedTwice() throws {
        let store = try makeStore()
        let bar = ProductDefinition(
            snapshotID: "snapshot-both", productID: "product-both", name: "Breakfast bar",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["energy": .known(Decimal(400), .kcal), "energyKcal": .known(Decimal(999), .kcal)])
        try addFood(store, name: "Bar", id: "bar", at: when, amount: 100, product: bar)
        let intake = try XCTUnwrap(try store.activeIntakes().first)

        let totals = try DailyTotalsBuilder.totals(
            for: [intake], store: store, lookup: SnapshotOnlyFacts(), nutrients: ["energy"])

        XCTAssertEqual(totals.total(for: "energy")?.value, .known(Decimal(400), .kcal))
    }

    // MARK: Below the reporting threshold

    /// One entry's value below the reporting threshold is a bound, not an amount, so added to what the
    /// other entries stated it is still not the day's total. The sum is not printed as though it were
    /// exact; the nutrient is uncertain, which is the same answer an unreadable entry gives.
    func testAnEntryBelowTheReportingThresholdLeavesTheNutrientUnknownNotTheSum() throws {
        let store = try makeStore()
        let cereal = ProductDefinition(
            snapshotID: "snapshot-cereal", productID: "product-cereal", name: "Breakfast cereal",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["fiber": .known(Decimal(4), .g)])
        let seasoning = ProductDefinition(
            snapshotID: "snapshot-seasoning", productID: "product-seasoning", name: "Seasoning",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["fiber": .belowReportingThreshold(.g)])
        try addFood(store, name: "Cereal", id: "cereal", at: when, amount: 100, product: cereal)
        try addFood(store, name: "Seasoning", id: "seasoning", at: when, amount: 100, product: seasoning)
        let intakes = try store.activeIntakes().filter { $0.category == "food" }

        let totals = try DailyTotalsBuilder.totals(
            for: intakes, store: store, lookup: SnapshotOnlyFacts(), nutrients: ["fiber"])

        let total = try XCTUnwrap(totals.total(for: "fiber"))
        XCTAssertEqual(total.value, .unknown)
        // Nothing here was unreadable, so the below-threshold entry is the whole reason.
        XCTAssertFalse(total.coverage.hasUnknown)
        XCTAssertTrue(total.coverage.hasBelowReportingThreshold)
        XCTAssertEqual(total.coverage.knownCount, 1)
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

    /// A food beside a drink on the same day leaves the water alone. A product states no water, so
    /// asking it for water says nothing about what was drunk; a food answering unknown there is what
    /// made a day with anything eaten report its water as unknown.
    func testAFoodEntryDoesNotMakeTheDaysWaterUnknown() throws {
        let store = try makeStore()
        try addFood(store, name: "Oats", id: "oats", at: when, amount: 100, product: oatsSnapshot())
        try addWater(store, at: when, amount: 300)
        let intakes = try store.activeIntakes()

        let totals = try DailyTotalsBuilder.totals(
            for: intakes, store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein", "water"])

        XCTAssertEqual(totals.total(for: "water")?.value, .known(Decimal(300), .mL))
        XCTAssertEqual(totals.total(for: "protein")?.value, .known(Decimal(13), .g))
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

    /// The tracked list is the fallback's own order first and then the goals' other keys, so the same
    /// goals always produce the same screen whatever order the store returned them in, a goal for a
    /// nutrient outside the fallback is shown, and a fallback nutrient without a goal is still
    /// tracked.
    func testTrackedNutrientsAreTheGoalKeysPlusTheFallbackOnesWithoutAGoal() {
        let goals = [
            NutrientGoal(nutrient: "zinc", target: Decimal(11), unit: .mg),
            NutrientGoal(nutrient: "protein", target: Decimal(60), unit: .g),
        ]

        let tracked = TodayViewModel.defaultTrackedNutrientsOrGoals(goals: goals)

        // The fallback leads in its fixed order, and protein keeps its place in it rather than being
        // pulled to the front by its goal. Zinc is outside the fallback, so it is appended, and the
        // goals are sorted so the store's order cannot decide where it lands.
        XCTAssertEqual(tracked, TodayViewModel.defaultTrackedNutrients + ["zinc"])
        XCTAssertEqual(Array(tracked.prefix(4)), TodayViewModel.defaultTrackedNutrients)
        XCTAssertEqual(Set(tracked), Set(["protein", "zinc", "potassium", "sodium", "fiber"]))
    }

    /// Two goal-only keys land in alphabetical order however the store returned them, because a
    /// screen whose order moved with the store's would show the same day differently on two loads.
    func testTrackedNutrientsPutTheGoalsOutsideTheFallbackInAlphabeticalOrder() {
        let stored = [
            NutrientGoal(nutrient: "zinc", target: Decimal(11), unit: .mg),
            NutrientGoal(nutrient: "iron", target: Decimal(14), unit: .mg),
        ]
        let reversed = [
            NutrientGoal(nutrient: "iron", target: Decimal(14), unit: .mg),
            NutrientGoal(nutrient: "zinc", target: Decimal(11), unit: .mg),
        ]

        XCTAssertEqual(
            TodayViewModel.defaultTrackedNutrientsOrGoals(goals: stored),
            TodayViewModel.defaultTrackedNutrientsOrGoals(goals: reversed))
        XCTAssertEqual(
            Array(TodayViewModel.defaultTrackedNutrientsOrGoals(goals: stored).suffix(2)),
            ["iron", "zinc"])
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
