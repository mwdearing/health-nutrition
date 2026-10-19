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
        XCTAssertEqual(token.message, "Added Quick add, 250 Calories")
        XCTAssertEqual(intake.category, "food")
        XCTAssertEqual(intake.meal, "lunch")
        XCTAssertEqual(intake.occurredAt, now)
        XCTAssertEqual(intake.timeZoneIdentifier, "UTC")

        let day = try totals(store)
        XCTAssertEqual(day.total(for: "energy")?.value, .known(Decimal(250), .kcal))
    }

    /// A late lunch is logged at the time it was eaten, not at the moment of saving.
    func testAnEarlierWhenIsStoredAsTheTimeItWasEaten() throws {
        let store = try makeStore()
        let model = makeModel(store, meal: .lunch)
        model.caloriesText = "400"
        let eaten = now.addingTimeInterval(-3 * 3_600)
        model.occurredAt = eaten

        _ = try XCTUnwrap(model.save())
        let intake = try XCTUnwrap(store.activeIntakes().first)
        XCTAssertEqual(intake.occurredAt, eaten)
    }

    /// Log means what was already eaten: a future time is clamped to the moment of saving.
    func testAFutureWhenIsClampedToNow() throws {
        let store = try makeStore()
        let model = makeModel(store)
        model.caloriesText = "100"
        model.occurredAt = now.addingTimeInterval(3_600)

        _ = try XCTUnwrap(model.save())
        let intake = try XCTUnwrap(store.activeIntakes().first)
        XCTAssertEqual(intake.occurredAt, now)
    }

    /// With nothing typed, the screen says what is missing; it is not a silent disabled button.
    func testNothingTypedIsReportedAsNoAmount() {
        let store = try! makeStore()
        let model = makeModel(store)
        XCTAssertTrue(model.hasNoAmountTyped)
        model.caloriesText = "  "
        XCTAssertTrue(model.hasNoAmountTyped)
        model.caloriesText = "10"
        XCTAssertFalse(model.hasNoAmountTyped)
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
        XCTAssertEqual(try store.revisions(of: intake.id).first?.components.first?.componentID, "quick-add")
    }

    /// A name that spells a nutrient keeps the reserved component id, so the typed protein stays the
    /// protein fact rather than the serving.
    func testANutrientNameDoesNotBecomeTheComponentID() throws {
        let store = try makeStore()
        let model = makeModel(store)
        model.name = "Protein"
        model.proteinText = "32"
        XCTAssertNotNil(model.save())

        let intake = try XCTUnwrap(store.activeIntakes().first)
        let component = try XCTUnwrap(store.revisions(of: intake.id).first?.components.first)
        XCTAssertEqual(component.componentID, "quick-add")
        XCTAssertEqual(component.name, "Protein")
        XCTAssertNotEqual(IntakeContextFactCatalog.nutrientSlug(for: "protein"), component.componentID)
        XCTAssertEqual(try totals(store).total(for: "protein")?.value, .known(Decimal(32), .g))
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

    /// A quick add is the user's own numbers: the relay says so, and the entry screen shows what it adds.
    func testAQuickAddReadsAsTypedInValues() throws {
        let store = try makeStore()
        let model = makeModel(store)
        model.caloriesText = "300"
        model.proteinText = "20"
        XCTAssertNotNil(model.save())

        let intake = try XCTUnwrap(store.activeIntakes().first)
        let revision = try XCTUnwrap(store.revisions(of: intake.id).first)
        let product = try XCTUnwrap(store.product(snapshotID: try XCTUnwrap(revision.productSnapshotID)))
        XCTAssertEqual(product.catalogOrigin, "quick_add")
        XCTAssertEqual(IntakeContextFactCatalog.provenance(for: product), "user_confirmed")
        XCTAssertEqual(EntryDetailViewModel.sourceLine(for: product), "Quick add · amounts typed in")
        XCTAssertEqual(EntryDetailViewModel.sourceDetails(for: product).map(\.value), ["Quick add"])
        XCTAssertFalse(EntryDetailViewModel.adds(of: product, logged: revision.components).isEmpty)
    }

    /// A quick add has no product behind it, so it never shows under Library > Products, while it still
    /// appears in Recents for a one-tap repeat.
    func testAQuickAddStaysOutOfTheProductsLibrary() throws {
        let store = try makeStore()
        let model = makeModel(store)
        model.caloriesText = "300"
        XCTAssertNotNil(model.save())

        let provider = RecentItemsProvider(store: store)
        XCTAssertEqual(try provider.foods(), [])
        XCTAssertEqual(try provider.recents().count, 1)
    }

    /// Two unnamed quick adds with different amounts read differently in Recents, so a tap repeats what
    /// the row shows.
    func testRecentQuickAddsShowTheirAmounts() throws {
        let store = try makeStore()
        let first = makeModel(store)
        first.caloriesText = "250"
        XCTAssertNotNil(first.save())
        let second = makeModel(store)
        second.caloriesText = "400"
        second.proteinText = "30"
        XCTAssertNotNil(second.save())

        let titles = try RecentItemsProvider(store: store).recents().map(\.template.displayName)
        XCTAssertEqual(Set(titles), ["Quick add · 250 Calories", "Quick add · 400 Calories, 30 g protein"])

        let journal = JournalViewModel(store: store)
        journal.load(now: now)
        XCTAssertEqual(
            Set(journal.sections.flatMap(\.rows).map(\.title)),
            ["Quick add · 250 Calories", "Quick add · 400 Calories, 30 g protein"])

        let today = TodayViewModel(store: store, lookup: SnapshotNutrientFacts(), timeZoneIdentifier: "UTC")
        today.load(now: now)
        XCTAssertEqual(
            Set(today.rows.map(\.title)), ["Quick add · 250 Calories", "Quick add · 400 Calories, 30 g protein"])
    }

    /// The region's own digits and separator are read, as the decimal pad types them.
    func testParsingReadsTheRegionsDigitsAndSeparator() {
        XCTAssertEqual(QuickAddViewModel.parse("2٫5", field: .protein, decimalSeparator: "٫"), .value(Decimal(string: "2.5")!))
        XCTAssertEqual(QuickAddViewModel.parse("٢٫٥", field: .protein, decimalSeparator: "٫"), .value(Decimal(string: "2.5")!))
        XCTAssertEqual(QuickAddViewModel.parse("2.5", field: .protein, decimalSeparator: "٫"), .value(Decimal(string: "2.5")!))
        XCTAssertEqual(QuickAddViewModel.parse("2٫5٫1", field: .protein, decimalSeparator: "٫"), .invalid)
        XCTAssertEqual(QuickAddViewModel.parse("2٫5", field: .protein, decimalSeparator: "."), .invalid)
    }

    /// A comma is read as the decimal separator only where the region uses one.
    func testParsingFollowsTheRegionsSeparator() {
        XCTAssertEqual(QuickAddViewModel.parse("2,5", field: .protein, decimalSeparator: ","), .value(Decimal(string: "2.5")!))
        XCTAssertEqual(QuickAddViewModel.parse("2,5", field: .protein, decimalSeparator: "."), .invalid)
        XCTAssertEqual(QuickAddViewModel.parse("  ", field: .protein, decimalSeparator: "."), .blank)
        XCTAssertEqual(QuickAddViewModel.parse("5000", field: .fat, decimalSeparator: "."), .value(Decimal(5000)))
        XCTAssertEqual(QuickAddViewModel.parse("5000.1", field: .fat, decimalSeparator: "."), .invalid)
    }

    /// A typed name can never read as another field, so two different entries never share a snapshot id.
    func testSnapshotIdentityCannotBeForgedByTheName() throws {
        let forged = QuickAddViewModel.snapshotIdentity(
            name: "foo|energyKcal=100 Calories", nutrients: ["protein": .known(1, .g)])
        let plain = QuickAddViewModel.snapshotIdentity(
            name: "foo", nutrients: ["energyKcal": .known(100, .kcal), "protein": .known(1, .g)])
        XCTAssertNotEqual(forged, plain)
        XCTAssertEqual(plain, QuickAddViewModel.snapshotIdentity(
            name: "foo", nutrients: ["protein": .known(1, .g), "energyKcal": .known(100, .kcal)]))

        let store = try makeStore()
        let first = makeModel(store)
        first.name = "foo|energyKcal=100 Calories"
        first.proteinText = "1"
        XCTAssertNotNil(first.save())
        let second = makeModel(store)
        second.name = "foo"
        second.caloriesText = "100"
        second.proteinText = "1"
        XCTAssertNotNil(second.save())
        XCTAssertEqual(try store.activeIntakes().count, 2)
    }

    /// Add opens the form on the meal chosen there, and an entry it writes can be undone from Add.
    func testAddHomeOpensTheFormAndOffersUndo() throws {
        let store = try makeStore()
        let home = AddHomeViewModel(store: store, meal: .dinner, now: { self.now })
        let form = home.makeQuickAdd()
        XCTAssertEqual(form.meal, .dinner)
        form.caloriesText = "400"
        let token = try XCTUnwrap(form.save())
        XCTAssertEqual(try store.activeIntakes().first?.meal, "dinner")

        home.quickAdded(token)
        XCTAssertEqual(home.undoToken, token)
        XCTAssertTrue(home.undo())
        XCTAssertEqual(try store.activeIntakes().count, 0)
    }

    /// A quick add edited to two servings shows the doubled amounts in its row title.
    func testRowTitleScalesWithTheLoggedServings() {
        let product = ProductDefinition(
            snapshotID: "quick-x", productID: "quick-x", name: "Quick add", labelBasis: "per serving",
            catalogOrigin: "quick_add", catalogVersion: "1", nutrients: ["energyKcal": .known(250, .kcal)])
        let two = [IntakeComponent(componentID: "quick-add", name: "Quick add", amount: 2, unit: .serving)]
        XCTAssertEqual(QuickAddViewModel.rowTitle(components: two, product: product), "Quick add · 500 Calories")
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
