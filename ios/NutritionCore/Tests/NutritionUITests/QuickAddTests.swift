import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

@MainActor
final class QuickAddTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let tracked = ["energy", "protein", "carbohydrate", "fat"]

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func makeModel(_ store: SwiftDataJournalStore, meal: MealLabel? = nil) -> QuickAddViewModel {
        QuickAddViewModel(store: store, meal: meal, now: { self.now }, timeZoneIdentifier: { "UTC" })
    }

    private func totals(_ store: SwiftDataJournalStore) throws -> DailyTotals {
        try DailyTotalsBuilder.totals(
            for: store.activeIntakes(), store: store, lookup: SnapshotNutrientFacts(), nutrients: tracked)
    }

    /// Calories alone are enough, and the day's energy is exactly what was typed.
    func testCaloriesOnlySavesAndCountsTowardTheDay() throws {
        let store = try makeStore()
        let model = makeModel(store, meal: .lunch)
        model.caloriesText = "250"
        XCTAssertTrue(model.canSave)

        let token = try XCTUnwrap(model.save())
        let intake = try XCTUnwrap(store.activeIntakes().first)
        XCTAssertEqual(try store.activeIntakes().count, 1)
        XCTAssertEqual(token.intakeID, intake.id)
        XCTAssertEqual(token.message, "Added Quick add, 250 kcal")
        XCTAssertEqual(intake.category, "food")
        XCTAssertEqual(intake.meal, "lunch")
        XCTAssertEqual(intake.occurredAt, now)
        XCTAssertEqual(intake.timeZoneIdentifier, "UTC")

        let day = try totals(store)
        XCTAssertEqual(day.total(for: "energy")?.value, .known(Decimal(250), .kcal))
    }

    /// A field left empty is not stated at all, so it reads as unknown and never as zero.
    func testAnEmptyFieldIsUnknownRatherThanZero() throws {
        let store = try makeStore()
        let model = makeModel(store)
        model.caloriesText = "250"
        XCTAssertNotNil(model.save())

        let intake = try XCTUnwrap(store.activeIntakes().first)
        let revision = try XCTUnwrap(store.revisions(of: intake.id).first)
        let product = try XCTUnwrap(store.product(snapshotID: try XCTUnwrap(revision.productSnapshotID)))
        XCTAssertEqual(product.nutrients, ["energyKcal": .known(Decimal(250), .kcal)])
        XCTAssertEqual(product.labelBasis, "per serving")
        XCTAssertEqual(revision.components, [
            IntakeComponent(componentID: "quick-add", name: "Quick add", amount: 1, unit: .serving),
        ])
        XCTAssertNotEqual(try totals(store).total(for: "protein")?.value, .known(Decimal(0), .g))
    }

    /// All four amounts reach the day, a typed zero is kept as a real zero, and the name is the typed one.
    func testAllFourAmountsAndATypedZeroAreStored() throws {
        let store = try makeStore()
        let model = makeModel(store)
        model.name = "  Work lunch  "
        model.caloriesText = "640.5"
        model.proteinText = "32"
        model.carbohydratesText = "70"
        model.fatText = "0"
        XCTAssertNotNil(model.save())

        let day = try totals(store)
        XCTAssertEqual(day.total(for: "energy")?.value, .known(Decimal(string: "640.5")!, .kcal))
        XCTAssertEqual(day.total(for: "protein")?.value, .known(Decimal(32), .g))
        XCTAssertEqual(day.total(for: "carbohydrate")?.value, .known(Decimal(70), .g))
        XCTAssertEqual(day.total(for: "fat")?.value, .known(Decimal(0), .g))

        let intake = try XCTUnwrap(store.activeIntakes().first)
        XCTAssertEqual(try store.revisions(of: intake.id).first?.components.first?.name, "Work lunch")
    }

    /// Two quick adds with different amounts are two products, and the day holds both.
    func testTwoQuickAddsAddUp() throws {
        let store = try makeStore()
        let first = makeModel(store)
        first.caloriesText = "100"
        first.proteinText = "5"
        XCTAssertNotNil(first.save())
        let second = makeModel(store)
        second.caloriesText = "200"
        second.proteinText = "7.5"
        XCTAssertNotNil(second.save())
        let repeated = makeModel(store)
        repeated.caloriesText = "200"
        repeated.proteinText = "7.5"
        XCTAssertNotNil(repeated.save())

        XCTAssertEqual(try store.activeIntakes().count, 3)
        let day = try totals(store)
        XCTAssertEqual(day.total(for: "energy")?.value, .known(Decimal(500), .kcal))
        XCTAssertEqual(day.total(for: "protein")?.value, .known(Decimal(20), .g))
    }

    /// The Apple Health plan for a quick add carries energy and every macro that was typed.
    func testTheHealthPlanCarriesEnergyAndMacros() throws {
        let store = try makeStore()
        let model = makeModel(store)
        model.caloriesText = "300"
        model.proteinText = "20"
        model.carbohydratesText = "30"
        model.fatText = "10"
        XCTAssertNotNil(model.save())

        let intake = try XCTUnwrap(store.activeIntakes().first)
        let revision = try XCTUnwrap(store.revisions(of: intake.id).first)
        let product = try XCTUnwrap(store.product(snapshotID: try XCTUnwrap(revision.productSnapshotID)))
        let plan = HealthKitWritePlanner.plan(
            intakeID: intake.id, revision: revision.number, occurredAt: intake.occurredAt,
            totals: product.nutrients)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: plan.map { ($0.unitSymbol + ":" + $0.quantityTypeIdentifier, $0.amount) }),
            [
                "kcal:HKQuantityTypeIdentifierDietaryEnergyConsumed": Decimal(300),
                "g:HKQuantityTypeIdentifierDietaryProtein": Decimal(20),
                "g:HKQuantityTypeIdentifierDietaryCarbohydrates": Decimal(30),
                "g:HKQuantityTypeIdentifierDietaryFatTotal": Decimal(10),
            ])
    }

    /// Nothing typed, only zeros, or anything that is not a plain number in range writes nothing.
    func testInvalidOrEmptyInputWritesNothing() throws {
        let store = try makeStore()
        let empty = makeModel(store)
        XCTAssertFalse(empty.canSave)
        XCTAssertNil(empty.save())

        let zeros = makeModel(store)
        zeros.caloriesText = "0"
        zeros.fatText = "0"
        XCTAssertFalse(zeros.canSave)
        XCTAssertNil(zeros.save())

        for text in ["-5", "abc", "1e3", "1.2.3", "20001", "9999999999999", "."] {
            let model = makeModel(store)
            model.caloriesText = text
            model.proteinText = "10"
            XCTAssertFalse(model.canSave, text)
            XCTAssertNotNil(model.error(for: .calories), text)
            XCTAssertNil(model.error(for: .protein), text)
            XCTAssertNil(model.save(), text)
        }
        XCTAssertEqual(try store.activeIntakes().count, 0)
    }

    /// A comma is read as the decimal separator only where the region uses one.
    func testParsingFollowsTheRegionsSeparator() {
        XCTAssertEqual(QuickAddViewModel.parse("2,5", field: .protein, decimalSeparator: ","), .value(Decimal(string: "2.5")!))
        XCTAssertEqual(QuickAddViewModel.parse("2,5", field: .protein, decimalSeparator: "."), .invalid)
        XCTAssertEqual(QuickAddViewModel.parse("  ", field: .protein, decimalSeparator: "."), .blank)
        XCTAssertEqual(QuickAddViewModel.parse("5000", field: .fat, decimalSeparator: "."), .value(Decimal(5000)))
        XCTAssertEqual(QuickAddViewModel.parse("5000.1", field: .fat, decimalSeparator: "."), .invalid)
    }

    /// A store that fails leaves no entry and says so.
    func testAFailedSaveReportsAndWritesNothing() throws {
        let store = try makeStore()
        let model = makeModel(store)
        model.caloriesText = "250"
        store.failNextSaveForTesting = true
        XCTAssertNil(model.save())
        XCTAssertEqual(model.saveError, "Could not save the entry.")
        XCTAssertEqual(try store.activeIntakes().count, 0)
    }
}
