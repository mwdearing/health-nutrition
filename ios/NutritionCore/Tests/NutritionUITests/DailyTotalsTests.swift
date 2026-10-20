import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionJournal
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

/// Answers each component, for each nutrient, with the value given for its id and nutrient.
private struct NutrientFacts: NutrientFactsLookup {
    let values: [String: [String: NutrientValue]]

    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue {
        values[component.componentID]?[nutrient] ?? .unknown
    }

    func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue {
        values[component.componentID]?[nutrient] ?? .unknown
    }
}

/// Answers each component with the value given for its id, so a test can state any unit it needs.
private struct ComponentFacts: NutrientFactsLookup {
    let values: [String: NutrientValue]

    func value(for component: IntakeComponent, nutrient: String) -> NutrientValue {
        values[component.componentID] ?? .unknown
    }

    func value(for component: IntakeComponent, snapshot: ProductDefinition?, nutrient: String) -> NutrientValue {
        values[component.componentID] ?? .unknown
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

    /// A product as a USDA name-search pick saves it: per 100 g, no barcode, the search identity as its
    /// product id and the usda source. Logged as two ounces, which is 56.7 g in the stored amount.
    func testUSDAPickLoggedInOuncesTotalsKnownEnergy() throws {
        let store = try makeStore()
        let usda = ProductDefinition(
            snapshotID: "usda-snap", productID: "search-usda-snap", name: "Rice cake", brand: nil,
            barcode: "", labelBasis: "per 100 g", catalogOrigin: "usda-fdc", catalogVersion: "unknown",
            nutrients: ["energyKcal": .known(Decimal(200), .kcal)])
        try addFood(store, name: "Rice cake", id: "rice", at: when,
                    amount: Decimal(string: "56.6990462500")!, unit: .g, product: usda)
        let intakes = try store.activeIntakes()
        let totals = try DailyTotalsBuilder.totals(
            for: intakes, store: store, lookup: SnapshotOnlyFacts(), nutrients: ["energyKcal"])
        guard case .known(let kcal, _) = totals.total(for: "energyKcal")?.value else {
            XCTFail("a USDA pick logged in ounces must total known energy")
            return
        }
        XCTAssertEqual(NSDecimalNumber(decimal: kcal).doubleValue, 113.4, accuracy: 0.1)
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

    /// A store insert that fails must leave the day as it was: the same totals and the same queued
    /// outbox, so no half-written entry is counted or sent to a destination.
    func testPersistenceBoundaryFailedStoreInsertChangesNeitherTotalsNorOutbox() throws {
        let store = try makeStore()
        try addFood(store, name: "Oats", id: "oats", at: when, amount: 100, product: oatsSnapshot())
        let totalsBefore = try DailyTotalsBuilder.totals(
            for: store.activeIntakes(), store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein", "water"])
        let outboxBefore = try store.pendingOutbox().map(\.operationID)

        store.failNextSaveForTesting = true
        let failed = Intake(
            id: UUID().uuidString.lowercased(), category: "food", occurredAt: when, timeZoneIdentifier: "UTC")
        XCTAssertThrowsError(try store.create(
            failed, components: [IntakeComponent(componentID: "oats", name: "Rolled oats", amount: 200, unit: .g)],
            product: oatsSnapshot(), now: when)) {
            XCTAssertEqual($0 as? JournalError, .injectedSaveFailure)
        }

        let totalsAfter = try DailyTotalsBuilder.totals(
            for: store.activeIntakes(), store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein", "water"])
        XCTAssertEqual(totalsAfter, totalsBefore)
        XCTAssertEqual(totalsAfter.total(for: "protein")?.value, .known(Decimal(13), .g))
        XCTAssertEqual(try store.pendingOutbox().map(\.operationID), outboxBefore)
    }

    /// Editing or deleting an entry recalculates only the day it belongs to. The other day's protein is
    /// read again after each change and must come out the same.
    func testPersistenceBoundaryEditingOrDeletingAnEntryRecalculatesOnlyItsOwnDay() throws {
        let store = try makeStore()
        let firstID = try addFood(store, name: "Oats", id: "oats", at: when, amount: 100, product: oatsSnapshot())
        let tomorrow = when.addingTimeInterval(86_400)
        let secondID = try addFood(
            store, name: "Oats", id: "oats", at: tomorrow, amount: 300, product: oatsSnapshot())

        /// The protein total of the active entries that occur in a window, read fresh from the store.
        func protein(from start: Date, to end: Date) throws -> NutrientValue? {
            let entries = try store.activeIntakes().filter { $0.occurredAt >= start && $0.occurredAt < end }
            let totals = try DailyTotalsBuilder.totals(
                for: entries, store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein"])
            return totals.total(for: "protein")?.value
        }
        XCTAssertEqual(try protein(from: .distantPast, to: tomorrow), .known(Decimal(13), .g))
        XCTAssertEqual(try protein(from: tomorrow, to: .distantFuture), .known(Decimal(39), .g))

        // Edit day one's entry from 100 g to 200 g: day one moves to 26 g and day two stays at 39 g.
        _ = try store.edit(
            intakeID: firstID,
            components: [IntakeComponent(componentID: "oats", name: "Rolled oats", amount: 200, unit: .g)],
            product: oatsSnapshot(), changeReason: "portion", now: when)
        XCTAssertEqual(try protein(from: .distantPast, to: tomorrow), .known(Decimal(26), .g))
        XCTAssertEqual(try protein(from: tomorrow, to: .distantFuture), .known(Decimal(39), .g))

        // Delete day two's only entry: day two has nothing left to sum, and day one still reads 26 g.
        try store.delete(intakeID: secondID, now: tomorrow)
        XCTAssertEqual(try protein(from: tomorrow, to: .distantFuture), .unknown)
        XCTAssertEqual(try protein(from: .distantPast, to: tomorrow), .known(Decimal(26), .g))
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

    /// Protein stated in international units is not a protein total in grams: a day holding only that
    /// value reads as unknown, the answer a mismatched pair already gets, and not as "1000 IU" beside
    /// a 60 g target.
    func testALoneProteinValueInInternationalUnitsIsUnknownNotShownInIU() throws {
        let store = try makeStore()
        try addFood(store, name: "Supplement", id: "iu-protein", at: when)
        let intake = try XCTUnwrap(try store.activeIntakes().first)

        let totals = try DailyTotalsBuilder.totals(
            for: [intake], store: store,
            lookup: ComponentFacts(values: ["iu-protein": .known(Decimal(1000), .iu)]),
            nutrients: ["protein"])

        let total = try XCTUnwrap(totals.total(for: "protein"))
        XCTAssertEqual(total.value, .unknown)
        XCTAssertTrue(total.coverage.hasUnknown)
    }

    /// The same protein in milligrams is still a protein total, stated as it was read.
    func testALoneProteinValueInMilligramsIsStillSummed() throws {
        let store = try makeStore()
        try addFood(store, name: "Tablet", id: "mg-protein", at: when)
        let intake = try XCTUnwrap(try store.activeIntakes().first)

        let totals = try DailyTotalsBuilder.totals(
            for: [intake], store: store,
            lookup: ComponentFacts(values: ["mg-protein": .known(Decimal(500), .mg)]),
            nutrients: ["protein"])

        XCTAssertEqual(totals.total(for: "protein")?.value, .known(Decimal(500), .mg))
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
            labelBasis: "per 100 kcal", catalogOrigin: "test", catalogVersion: "1",
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

    /// "per 100 g or mL" on a grams entry is per 100 g: 283.49523125 g of a product stating 37.5 kcal and
    /// 5.4 g carbohydrate per 100 g or mL is 106.31 kcal and 15.31 g, not unknown.
    func testPerHundredGOrMLScalesAGramsEntryPer100G() throws {
        let store = try makeStore()
        let milk = ProductDefinition(
            snapshotID: "snapshot-milk", productID: "product-milk", name: "Fat Free 0% Milk",
            labelBasis: "per 100 g or mL", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["energy": .known(Decimal(string: "37.5")!, .kcal),
                        "carbohydrate": .known(Decimal(string: "5.4")!, .g)])
        _ = try addFood(store, name: "Fat Free 0% Milk", id: "milk", at: when,
                        amount: Decimal(string: "283.49523125")!, unit: .g, product: milk)
        let intakes = try store.activeIntakes()

        let totals = try DailyTotalsBuilder.totals(
            for: intakes, store: store, lookup: SnapshotOnlyFacts(), nutrients: ["energy", "carbohydrate"])

        XCTAssertEqual(totals.total(for: "energy")?.value,
                       .known(Decimal(string: "37.5")! * Decimal(string: "283.49523125")! / 100, .kcal))
        XCTAssertEqual(totals.total(for: "carbohydrate")?.value,
                       .known(Decimal(string: "5.4")! * Decimal(string: "283.49523125")! / 100, .g))
    }

    /// The same basis on a millilitre entry is per 100 mL, so a 354.88235475 mL drink of a product stating
    /// 40 kcal per 100 mL is 141.95 kcal.
    func testPerHundredGOrMLScalesAMillilitreEntryPer100ML() throws {
        let store = try makeStore()
        let drink = ProductDefinition(
            snapshotID: "snapshot-drink", productID: "product-drink", name: "Energy drink",
            labelBasis: "per 100 g or mL", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["energy": .known(Decimal(40), .kcal)])
        _ = try addFood(store, name: "Energy drink", id: "drink", at: when,
                        amount: Decimal(string: "354.88235475")!, unit: .mL, product: drink)

        let totals = try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: SnapshotOnlyFacts(), nutrients: ["energy"])

        XCTAssertEqual(totals.total(for: "energy")?.value,
                       .known(Decimal(40) * Decimal(string: "354.88235475")! / 100, .kcal))
    }

    /// A scoop or a piece is neither grams nor millilitres, so "per 100 g or mL" cannot scale it and the
    /// nutrient stays unknown rather than zero.
    func testPerHundredGOrMLLeavesACountedEntryUnknown() throws {
        let store = try makeStore()
        let powder = ProductDefinition(
            snapshotID: "snapshot-powder", productID: "product-powder", name: "Powder",
            labelBasis: "per 100 g or mL", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["energy": .known(Decimal(40), .kcal)])
        _ = try addFood(store, name: "Powder", id: "powder", at: when, amount: 1, unit: .scoop, product: powder)

        let totals = try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: SnapshotOnlyFacts(), nutrients: ["energy"])

        XCTAssertEqual(totals.total(for: "energy")?.value, .unknown)
    }

    /// A weight beside a counted scoop on a "per 100 g or mL" product cannot be scaled as one amount, so the
    /// nutrient stays unknown rather than being scaled from the grams alone.
    func testPerHundredGOrMLWithAMixedWeightAndCountStaysUnknown() throws {
        let store = try makeStore()
        let powder = ProductDefinition(
            snapshotID: "snapshot-mixed", productID: "product-mixed", name: "Mixed",
            labelBasis: "per 100 g or mL", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["energy": .known(Decimal(40), .kcal)])
        let intake = Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: when, timeZoneIdentifier: "UTC")
        try store.create(
            intake,
            components: [
                IntakeComponent(componentID: "mixed", name: "Mixed", amount: 30, unit: .g),
                IntakeComponent(componentID: "scoop", name: "Scoop", amount: 1, unit: .scoop),
            ],
            product: powder, now: when)

        let totals = try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: SnapshotOnlyFacts(), nutrients: ["energy"])

        XCTAssertEqual(totals.total(for: "energy")?.value, .unknown)
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

    /// A recipe can yield counted things rather than servings, so "per gummy" and "per piece" are
    /// per-count bases like "per serving". They scale by the number logged here too: a basis the
    /// builder cannot resolve would leave the day's protein unknown, and a person who logged two
    /// gummies would see their recipe contribute nothing at all.
    func testACountedBasisOtherThanAServingMultipliesByTheNumberLogged() throws {
        for (basis, unit) in [("Per gummy; yield 30 gummy", MeasureUnit.gummy),
                              ("Per piece; yield 30 piece", MeasureUnit.piece)] {
            let store = try makeStore()
            let counted = ProductDefinition(
                snapshotID: "snapshot-counted", productID: "product-counted", name: "Sample gummies",
                labelBasis: basis, catalogOrigin: "test", catalogVersion: "1",
                nutrients: ["protein": .known(Decimal(5), .g)])
            try addFood(store, name: "Gummies", id: "gummies", at: when, amount: 2, unit: unit, product: counted)
            let intake = try XCTUnwrap(try store.activeIntakes().first)

            let totals = try DailyTotalsBuilder.totals(
                for: [intake], store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein"])

            XCTAssertEqual(totals.total(for: "protein")?.value, .known(Decimal(10), .g), basis)
        }
    }

    /// A recipe with a total yield states its nutrients per one unit of the yield. The day counts the same
    /// portion the HealthKit plan and the relay encoder count: 250 mL of a 1 L batch is a quarter of the value
    /// per liter, and 200 g of a batch of 100 g of protein per kilogram is 20 g.
    func testARecipeTotalYieldDayTotalScalesByTheLoggedPortion() throws {
        let cases: [(yield: RecipeYield, amount: Decimal, unit: MeasureUnit, perUnit: Decimal, expected: Decimal)] = [
            (.total(Quantity(value: 1, unit: .L)), 250, .mL, 80, 20),
            (.total(Quantity(value: Decimal(string: "0.8")!, unit: .kg)), 200, .g, 100, 20),
        ]
        for item in cases {
            let store = try makeStore()
            let batch = ProductDefinition(
                snapshotID: "snapshot-batch", productID: "product-batch", name: "Synthetic batch",
                labelBasis: RecipeLogger.basisText(item.yield), catalogOrigin: "recipe_calculated", catalogVersion: "1",
                nutrients: ["protein": .known(item.perUnit, .g)])
            try addFood(store, name: "Batch portion", id: "batch-portion", at: when, amount: item.amount,
                        unit: item.unit, product: batch)
            let intake = try XCTUnwrap(try store.activeIntakes().first)

            let totals = try DailyTotalsBuilder.totals(
                for: [intake], store: store, lookup: SnapshotOnlyFacts(), nutrients: ["protein"])

            XCTAssertEqual(
                totals.total(for: "protein")?.value, .known(item.expected, .g), RecipeLogger.basisText(item.yield))
        }
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

    /// A serving stated in milliliters scales exactly as one stated in grams: what matters is that the
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
/// were milliliters would give a thousandth of the answer.
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

    /// A serving whose quantity sits inside a household measure, "1 bar (30 g)", is read from the
    /// innermost brackets, so the gram weight is what scales. A plain "(30 g)" reads the same way.
    func testHouseholdServingTextScales() throws {
        let bar = try XCTUnwrap(DailyTotalsBuilder.statedServingQuantity("per serving (1 bar (30 g))"))
        XCTAssertEqual(bar.value, Decimal(30))
        XCTAssertEqual(bar.unit, MeasureUnit.g)

        let plain = try XCTUnwrap(DailyTotalsBuilder.statedServingQuantity("per serving (30 g)"))
        XCTAssertEqual(plain.value, Decimal(30))
        XCTAssertEqual(plain.unit, MeasureUnit.g)

        XCTAssertNil(DailyTotalsBuilder.statedServingQuantity("per serving (1 large biscuit)"))
        XCTAssertNil(DailyTotalsBuilder.statedServingQuantity("per serving"))

        let factor = DailyTotalsBuilder.scalingFactor(
            labelBasis: "per serving (1 bar (30 g))",
            logged: [IntakeComponent(componentID: "bar", name: "Bar", amount: 60, unit: .g)])
        XCTAssertEqual(factor, Decimal(2))
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
        XCTAssertEqual(Array(tracked.prefix(TodayViewModel.defaultTrackedNutrients.count)), TodayViewModel.defaultTrackedNutrients)
        XCTAssertEqual(
            Set(tracked), Set(["energy", "protein", "carbohydrate", "fat", "zinc", "potassium", "sodium", "fiber"]))
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

    /// A drink counts its water share of the volume toward the day, as Today shows it, and a drink
    /// with no share set counts the default share.
    func testDrinkWaterCountsItsShareOfItsVolume() throws {
        let store = try makeStore()
        let product = ProductDefinition(
            snapshotID: "soda-share-1", productID: "soda", name: "7up", labelBasis: "per serving",
            catalogOrigin: "manual", catalogVersion: "1", kind: .drink)
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "other", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "soda", name: "7up", amount: 200, unit: .mL, hydrationPercent: 50)],
            product: product, now: when)
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "other", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "soda", name: "7up", amount: 100, unit: .mL)],
            product: product, now: when)
        let intakes = try store.activeIntakes()

        let totals = try DailyTotalsBuilder.totals(
            for: intakes, store: store, lookup: SnapshotOnlyFacts(), nutrients: ["water"])

        // 200 mL at 50% is 100 mL. The 100 mL entry has no stored share (logged before shares), so it adds nothing.
        XCTAssertEqual(totals.total(for: "water")?.value, .known(Decimal(100), .mL))
    }

    /// A drink logged before shares has no stored share, so it adds no water to the day, as on main.
    func testALegacyDrinkWithNoStoredShareAddsNoWater() throws {
        let store = try makeStore()
        let product = ProductDefinition(
            snapshotID: "soda-legacy-1", productID: "soda", name: "Old soda", labelBasis: "per serving",
            catalogOrigin: "manual", catalogVersion: "1", kind: .drink)
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "other", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "soda", name: "Old soda", amount: 200, unit: .mL)],
            product: product, now: when)
        let totals = try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: SnapshotOnlyFacts(), nutrients: ["water"])

        XCTAssertEqual(totals.total(for: "water")?.value, .unknown)
    }

    /// A negative logged amount makes its entry unknown on every path, so the known sum is what the positive
    /// entries alone add up to. Each lookup below returns the same value whatever the amount, so a negative
    /// entry that reached the sum would change the total.
    /// A product whose stated value is negative is distrusted even when the logged amount is positive.
    func testANegativeStatedValueIsUnknownEvenWithAPositiveLoggedAmount() throws {
        let store = try makeStore()
        let product = ProductDefinition(
            snapshotID: "snapshot-negstated", productID: "product-negstated", name: "Stated",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["energyKcal": .known(Decimal(-10), .kcal), "protein": .known(Decimal(-1), .g)])
        try addFood(store, name: "Stated", id: "stated", at: when, amount: 100, product: product)
        let totals = try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: SnapshotOnlyFacts(),
            nutrients: ["energyKcal", "protein"])
        XCTAssertEqual(totals.total(for: "energyKcal")?.value, .unknown)
        XCTAssertEqual(totals.total(for: "protein")?.value, .unknown)
    }

    /// A lookup that answers a negative value for a food with no product distrusts that food for every nutrient,
    /// so the day's energy is partial, never a complete figure that leaves the food out.
    func testANegativeLookupValueForAFoodWithNoProductIsUnknownForEveryNutrient() throws {
        let store = try makeStore()
        try addFood(store, name: "Oats", id: "oats", at: when, amount: 40)
        try addFood(store, name: "Rice", id: "rice", at: when, amount: 150)
        let facts = NutrientFacts(values: [
            "oats": ["energyKcal": .known(Decimal(-10), .kcal), "protein": .known(Decimal(5), .g)],
            "rice": ["energyKcal": .known(Decimal(200), .kcal), "protein": .known(Decimal(2), .g)],
        ])
        let totals = try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: facts, nutrients: ["energyKcal", "protein"])
        // Energy is partial: the known part is rice alone, and the oats entry is one missing entry.
        XCTAssertEqual(totals.total(for: "energyKcal")?.value, .unknown)
        XCTAssertEqual(totals.knownSum(for: "energyKcal"), .known(200, .kcal))
        XCTAssertEqual(totals.missingCount(for: "energyKcal"), 1)
        // The other nutrient of the same food is distrusted too.
        XCTAssertEqual(totals.total(for: "protein")?.value, .unknown)
        XCTAssertEqual(totals.knownSum(for: "protein"), .known(2, .g))
    }

    /// A per-100 g product with a negative protein is distrusted for every nutrient, so energy is unknown too.
    func testANegativeNutrientOnAProductDistrustsItsOtherNutrientsToo() throws {
        let store = try makeStore()
        let product = ProductDefinition(
            snapshotID: "snapshot-mixed", productID: "product-mixed", name: "Mixed",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["energyKcal": .known(Decimal(200), .kcal), "protein": .known(Decimal(-1), .g)])
        try addFood(store, name: "Mixed", id: "mixed", at: when, amount: 100, product: product)
        let totals = try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: SnapshotOnlyFacts(),
            nutrients: ["energyKcal", "protein"])
        XCTAssertEqual(totals.total(for: "energyKcal")?.value, .unknown)
        XCTAssertEqual(totals.total(for: "protein")?.value, .unknown)
    }

    /// A no-product food whose lookup answers a negative protein is unknown for energy whichever nutrients the
    /// caller asks for, so the meal section and the day total cannot disagree.
    func testTheSameFoodGivesTheSameAnswerWhicheverNutrientsTheCallerAsksFor() throws {
        let store = try makeStore()
        try addFood(store, name: "Lookup food", id: "lookupfood", at: when, amount: 100)
        let facts = NutrientFacts(values: [
            "lookupfood": ["energyKcal": .known(Decimal(200), .kcal), "protein": .known(Decimal(-1), .g)],
        ])
        let energyOnly = try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: facts, nutrients: ["energyKcal"])
        let both = try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: facts, nutrients: ["energyKcal", "protein"])
        XCTAssertEqual(energyOnly.total(for: "energyKcal")?.value, .unknown)
        XCTAssertEqual(both.total(for: "energyKcal")?.value, .unknown)
    }

    /// A supplement with a negative stated vitamin D declares a second nutrient too: both are unknown, while energy
    /// and protein from another entry stay known and not partial.
    func testANegativeStatedSupplementValueIsUnknownForWhatItDeclaresOnly() throws {
        let store = try makeStore()
        let supplement = ProductDefinition(
            snapshotID: "snapshot-negvitd", productID: "product-negvitd", name: "Vitamin D",
            labelBasis: "per serving", catalogOrigin: "test", catalogVersion: "1", kind: .supplement,
            nutrients: [
                "vitaminD": .known(Decimal(-10), .mcg),
                "magnesium": .known(Decimal(50), .mg),
            ])
        let oats = ProductDefinition(
            snapshotID: "snapshot-oats-2", productID: "product-oats-2", name: "Oats",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["energyKcal": .known(Decimal(380), .kcal), "protein": .known(Decimal(13), .g)])
        try addFood(store, name: "Vitamin D", id: "negvitd", at: when, amount: 1, unit: .serving, product: supplement)
        try addFood(store, name: "Oats", id: "oats2", at: when, amount: 100, product: oats)
        let totals = try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: SnapshotOnlyFacts(),
            nutrients: ["vitaminD", "magnesium", "energyKcal", "protein"])
        XCTAssertEqual(totals.total(for: "vitaminD")?.value, .unknown)
        XCTAssertEqual(totals.total(for: "magnesium")?.value, .unknown)
        XCTAssertEqual(totals.total(for: "energyKcal")?.value, .known(380, .kcal))
        XCTAssertEqual(totals.total(for: "protein")?.value, .known(13, .g))
        XCTAssertEqual(totals.total(for: "energyKcal")?.coverage.hasUnknown, false)
        XCTAssertEqual(totals.total(for: "protein")?.coverage.hasUnknown, false)
    }

    /// A drink row with a positive and a negative volume is distrusted as a whole: its water is unknown, and the
    /// known 250 mL does not survive as a partial sum.
    func testAMixedDrinkRowWithANegativeVolumeIsUnknownWaterNotPartlyKnown() throws {
        let store = try makeStore()
        let intake = Intake(id: UUID().uuidString.lowercased(), category: "water", occurredAt: when, timeZoneIdentifier: "UTC")
        try store.create(
            intake, components: [
                IntakeComponent(componentID: "drinka", name: "Drink", amount: 250, unit: .mL, hydrationPercent: 100),
                IntakeComponent(componentID: "drinkb", name: "Drink", amount: 50, unit: .mL, hydrationPercent: 100),
            ], product: nil, now: when)
        try store.seedLegacyAmountsForTesting(intakeID: intake.id, amountsByComponent: ["drinkb": "-50"])
        let totals = try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: SnapshotOnlyFacts(),
            nutrients: [DailyTotalsBuilder.waterKey])
        XCTAssertEqual(totals.total(for: DailyTotalsBuilder.waterKey)?.value, .unknown)
        XCTAssertNil(totals.knownSum(for: DailyTotalsBuilder.waterKey))
        XCTAssertEqual(totals.missingCount(for: DailyTotalsBuilder.waterKey), 1)
    }

    /// A lookup's negative value for a nutrient the caller did not ask for still distrusts the food, so the energy
    /// total does not depend on which nutrients were requested.
    func testANegativeLookupForAnUnrequestedNutrientStillDistrustsTheFood() throws {
        let store = try makeStore()
        try addFood(store, name: "Lookup food", id: "lookupfood2", at: when, amount: 100)
        let facts = NutrientFacts(values: [
            "lookupfood2": ["energyKcal": .known(Decimal(200), .kcal), "carbohydrate": .known(Decimal(-3), .g)],
        ])
        let energyOnly = try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: facts, nutrients: ["energyKcal"])
        XCTAssertEqual(energyOnly.total(for: "energyKcal")?.value, .unknown)
    }

    /// A legacy negative row seeded into the store reads back through the normal read path with its amount intact.
    func testASeededNegativeRowReadsBackThroughTheNormalReadPath() throws {
        let store = try makeStore()
        let id = try addFood(store, name: "Oats", id: "oats", at: when, amount: 40)
        try store.seedLegacyAmountsForTesting(intakeID: id, amountsByComponent: ["oats": "-40"])
        let revision = try XCTUnwrap(try store.revisions(of: id).last)
        XCTAssertEqual(revision.components.first?.amount, -40)
    }

    /// A distrusted food with no water share contributes nothing to water, so a day's 1000 mL of water stays known.
    func testANegativeFoodRowDoesNotMakeTheDaysWaterUnknown() throws {
        let store = try makeStore()
        let drink = Intake(id: UUID().uuidString.lowercased(), category: "water", occurredAt: when, timeZoneIdentifier: "UTC")
        try store.create(
            drink, components: [IntakeComponent(componentID: "water1", name: "Water", amount: 1000, unit: .mL)],
            product: nil, now: when)
        let product = ProductDefinition(
            snapshotID: "snapshot-protein", productID: "product-protein", name: "Protein food",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["energyKcal": .known(Decimal(100), .kcal), "protein": .known(Decimal(-1), .g)])
        let foodID = try addFood(store, name: "Protein food", id: "proteinfood", at: when, amount: 100, product: product)
        _ = foodID
        let totals = try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: SnapshotOnlyFacts(),
            nutrients: [DailyTotalsBuilder.waterKey, "energyKcal", "protein"])
        guard case .known(let ml, _) = totals.total(for: DailyTotalsBuilder.waterKey)?.value else {
            return XCTFail("the day's water must stay known")
        }
        XCTAssertEqual(NSDecimalNumber(decimal: ml).doubleValue, 1000, accuracy: 0.001)
        XCTAssertEqual(totals.total(for: DailyTotalsBuilder.waterKey)?.coverage.hasUnknown, false)
        XCTAssertEqual(totals.total(for: "protein")?.value, .unknown)
        XCTAssertEqual(totals.total(for: "energyKcal")?.value, .unknown)
    }

    /// A food row with a negative volume and a 100% water share must not lower the day's water.
    func testANegativeVolumeWithAWaterShareIsUnknownWaterNotDrunk() throws {
        let store = try makeStore()
        let intake = Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: when, timeZoneIdentifier: "UTC")
        try store.create(
            intake, components: [IntakeComponent(
                componentID: "soup", name: "Soup", amount: 250, unit: .mL, hydrationPercent: 100)],
            product: nil, now: when)
        try store.seedLegacyAmountsForTesting(intakeID: intake.id, amountsByComponent: ["soup": "-250"])
        let totals = try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: SnapshotOnlyFacts(),
            nutrients: [DailyTotalsBuilder.waterKey])
        XCTAssertEqual(totals.total(for: DailyTotalsBuilder.waterKey)?.value, .unknown)
    }

    /// A negative supplement row is unknown for what it declares, and an undeclared nutrient still does not count.
    func testANegativeSupplementRowIsUnknownOnlyForWhatItDeclares() throws {
        let store = try makeStore()
        let vitaminD = ProductDefinition(
            snapshotID: "snapshot-vitd", productID: "product-vitd", name: "Vitamin D",
            labelBasis: "per serving", catalogOrigin: "test", catalogVersion: "1", kind: .supplement,
            nutrients: ["vitaminD": .known(Decimal(10), .mcg)])
        let oats = ProductDefinition(
            snapshotID: "snapshot-oats", productID: "product-oats", name: "Oats",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: ["energyKcal": .known(Decimal(380), .kcal), "protein": .known(Decimal(13), .g)])
        let vitDID = try addFood(store, name: "Vitamin D", id: "vitd", at: when, amount: 1, unit: .serving, product: vitaminD)
        try store.seedLegacyAmountsForTesting(intakeID: vitDID, amountsByComponent: ["vitd": "-1"])
        try addFood(store, name: "Oats", id: "oats", at: when, amount: 100, product: oats)
        let totals = try DailyTotalsBuilder.totals(
            for: try store.activeIntakes(), store: store, lookup: SnapshotOnlyFacts(),
            nutrients: ["vitaminD", "energyKcal", "protein"])
        XCTAssertEqual(totals.total(for: "vitaminD")?.value, .unknown)
        XCTAssertEqual(totals.total(for: "energyKcal")?.coverage.hasUnknown, false)
        XCTAssertEqual(totals.total(for: "protein")?.coverage.hasUnknown, false)
        XCTAssertEqual(totals.total(for: "energyKcal")?.value, .known(380, .kcal))
        XCTAssertEqual(totals.total(for: "protein")?.value, .known(13, .g))
    }

    func testANegativeEntryIsUnknownOnEveryPath() throws {
        let facts = ComponentFacts(values: ["oats": .known(10, .kcal), "rice": .known(10, .kcal)])
        // No product snapshot: the lookup answers each component directly. The negative oats row is distrusted and
        // unknown; the positive rice row is the only known amount, so the known sum is its 10 kcal.
        do {
            let store = try makeStore()
            let oatsID = try addFood(store, name: "Oats", id: "oats", at: when, amount: 40, unit: .g)
            try store.seedLegacyAmountsForTesting(intakeID: oatsID, amountsByComponent: ["oats": "-40"])
            try addFood(store, name: "Rice", id: "rice", at: when, amount: 150, unit: .g)
            let totals = try DailyTotalsBuilder.totals(
                for: try store.activeIntakes(), store: store, lookup: facts, nutrients: ["energyKcal"])
            XCTAssertEqual(totals.total(for: "energyKcal")?.value, .unknown, "no-snapshot path")
            XCTAssertEqual(totals.knownSum(for: "energyKcal"), .known(10, .kcal), "no-snapshot path")
        }
        // Mass snapshot: the stated 10 kcal per 100 g is scaled by the logged grams.
        do {
            let store = try makeStore()
            let product = ProductDefinition(
                snapshotID: "mass-snap", productID: "search-mass", name: "Oats", brand: nil,
                barcode: "", labelBasis: "per 100 g", catalogOrigin: "usda-fdc", catalogVersion: "unknown",
                nutrients: ["energyKcal": .known(Decimal(10), .kcal)])
            try addFood(store, name: "Oats", id: "oats", at: when, amount: 40, unit: .g, product: product)
            let oatsID = try addFood(store, name: "Oats", id: "oats", at: when, amount: 40, unit: .g, product: product)
            try store.seedLegacyAmountsForTesting(intakeID: oatsID, amountsByComponent: ["oats": "-40"])
            let totals = try DailyTotalsBuilder.totals(
                for: try store.activeIntakes(), store: store, lookup: SnapshotOnlyFacts(), nutrients: ["energyKcal"])
            XCTAssertEqual(totals.total(for: "energyKcal")?.value, .unknown, "mass path")
            guard case .known(let kcal, _) = totals.knownSum(for: "energyKcal") else {
                return XCTFail("the positive mass entry must still sum to known energy")
            }
            XCTAssertEqual(NSDecimalNumber(decimal: kcal).doubleValue, 4, accuracy: 0.001, "mass path")
        }
        // Counted serving: one serving of 10 kcal, logged as two servings and minus two servings.
        do {
            let store = try makeStore()
            let product = ProductDefinition(
                snapshotID: "count-snap", productID: "search-count", name: "Gummy", brand: nil,
                barcode: "", labelBasis: "per serving", catalogOrigin: "usda-fdc", catalogVersion: "unknown",
                nutrients: ["energyKcal": .known(Decimal(10), .kcal)])
            try addFood(store, name: "Gummy", id: "gummy", at: when, amount: 2, unit: .serving, product: product)
            let gummyID = try addFood(store, name: "Gummy", id: "gummy", at: when, amount: 2, unit: .serving, product: product)
            try store.seedLegacyAmountsForTesting(intakeID: gummyID, amountsByComponent: ["gummy": "-2"])
            let totals = try DailyTotalsBuilder.totals(
                for: try store.activeIntakes(), store: store, lookup: SnapshotOnlyFacts(), nutrients: ["energyKcal"])
            XCTAssertEqual(totals.total(for: "energyKcal")?.value, .unknown, "count path")
            guard case .known(let kcal, _) = totals.knownSum(for: "energyKcal") else {
                return XCTFail("the positive count entry must still sum to known energy")
            }
            XCTAssertEqual(NSDecimalNumber(decimal: kcal).doubleValue, 20, accuracy: 0.001, "count path")
        }
    }

    /// #521 item 6: a negative alias distrusts an entry even when its canonical key states a positive value.
    /// Before the fix only the first key that answered was read, so the canonical positive hid the alias.
    func testANegativeAliasDistrustsAnEntryWhoseCanonicalKeyIsPositive() {
        let keys = HealthKitWritePlanner.acceptedKeys(for: "energy")
        XCTAssertGreaterThan(keys.count, 1, "energy has an alias to check")
        var stated: [String: NutrientValue] = [:]
        for (index, key) in keys.enumerated() {
            stated[key] = .known(index == 0 ? 100 : -5, .kcal)
        }
        let component = IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g)
        let lookup = NutrientFacts(values: ["oats": stated])
        let entry = (components: [component], snapshot: nil as ProductDefinition?, category: "food")
        XCTAssertTrue(DailyTotalsBuilder.isDistrusted(entry, lookup: lookup))
    }
}
