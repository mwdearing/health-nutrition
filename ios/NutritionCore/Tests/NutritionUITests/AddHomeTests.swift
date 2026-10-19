import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

@MainActor
final class AddHomeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// The app's scanner answer reaches the details form, so the form's wording follows the device.
    func testLabelScannerAvailabilityReachesTheDetailsForm() throws {
        let unavailable = AddHomeViewModel(
            store: try makeStore(), scannerAvailability: AddScannerAvailability(barcode: true, label: false),
            now: { self.now })
        XCTAssertFalse(unavailable.makeDetails(now: now).labelScannerAvailable)

        let available = AddHomeViewModel(
            store: try makeStore(), scannerAvailability: AddScannerAvailability(barcode: true, label: true),
            now: { self.now })
        XCTAssertTrue(available.makeDetails(now: now).labelScannerAvailable)
    }

    func testMealPresetIsCarriedIntoEveryMethodsDetails() async throws {
        let home = AddHomeViewModel(store: try makeStore(), meal: .lunch)
        let typed = home.makeDetails(now: now)
        XCTAssertEqual(typed.meal, .lunch)
        let scanned = home.makeDetails(now: now)
        await home.scannedBarcode("4006381333931", into: scanned)
        XCTAssertEqual(scanned.meal, .lunch)
        let label = home.makeDetails(now: now)
        XCTAssertEqual(label.meal, .lunch)
        let template = RepeatTemplate(displayName: "Oats", category: "food", meal: "breakfast",
            components: [IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g)])
        let library = try home.makeDetails(prefill: template, now: now)
        XCTAssertEqual(library.meal, .lunch)
        XCTAssertEqual(library.amountText, "40")
        XCTAssertEqual(library.name, "Oats")
    }

    /// A single-item prefill reads in the chosen unit, and saving it untouched writes the exact stored amount.
    func testUnchangedSingleItemPrefillSavesTheStoredAmountUnderUS() throws {
        let preferences = InMemoryDisplayPreferences()
        preferences.setUnitSystem(.usCustomary)
        for stored in ["354.88235475", "250", "400.55"] {
            let store = try makeStore()
            let home = AddHomeViewModel(store: store, preferences: preferences, now: { self.now })
            let amount = Decimal(string: stored)!
            let template = RepeatTemplate(displayName: "Drink", category: "food", meal: nil,
                components: [IntakeComponent(componentID: "drink", name: "Drink", amount: amount, unit: .mL)])
            let details = try home.makeDetails(prefill: template, now: now)
            XCTAssertEqual(details.unit, .flOz)
            if stored == "354.88235475" { XCTAssertEqual(details.amountText, "12") }
            XCTAssertTrue(details.save(now: now))
            let intake = try XCTUnwrap(store.activeIntakes().first)
            let component = try XCTUnwrap(store.revisions(of: intake.id).first?.components.first)
            XCTAssertEqual(component.unit, .mL, stored)
            XCTAssertEqual(component.amount, amount, stored)
        }
    }

    /// Typing into the prefilled amount means the typed figure is what is saved, not the stored amount.
    func testEditingAPrefilledAmountSavesTheTypedFigure() throws {
        let preferences = InMemoryDisplayPreferences()
        preferences.setUnitSystem(.usCustomary)
        let store = try makeStore()
        let home = AddHomeViewModel(store: store, preferences: preferences, now: { self.now })
        let template = RepeatTemplate(displayName: "Drink", category: "food", meal: nil,
            components: [IntakeComponent(componentID: "drink", name: "Drink", amount: 250, unit: .mL)])
        let details = try home.makeDetails(prefill: template, now: now)
        XCTAssertEqual(details.amountText, "8.45")
        details.amountText = "8.45"
        XCTAssertTrue(details.save(now: now))
        let intake = try XCTUnwrap(store.activeIntakes().first)
        let component = try XCTUnwrap(store.revisions(of: intake.id).first?.components.first)
        XCTAssertEqual(component.unit, .mL)
        XCTAssertEqual(component.amount, Decimal(string: "249.896324803125"))
    }

    /// A legacy supplement (no recorded unit) opens its Details form in the spoon its row reads in, and saving it
    /// records that unit on the new entry.
    func testLegacySupplementPrefillOpensInItsSpoonAndRecordsIt() throws {
        let preferences = InMemoryDisplayPreferences()
        preferences.setUnitSystem(.usCustomary)
        let store = try makeStore()
        let product = ProductDefinition(
            snapshotID: "fiber", productID: "fiber", name: "Fiber Powder", labelBasis: "per serving",
            catalogOrigin: ProductOrigin.label_capture, catalogVersion: "1", kind: .supplement,
            nutrients: ["fiber": .known(4, .g)])
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: "supplement", occurredAt: now, timeZoneIdentifier: "UTC")
        try store.create(
            intake,
            components: [IntakeComponent(
                componentID: "fiber-powder", name: "Fiber Powder", amount: Decimal(string: "19.715686375")!,
                unit: .mL)],
            product: product, now: now)
        let home = AddHomeViewModel(store: store, preferences: preferences, now: { self.now })
        home.load()
        let recent = try XCTUnwrap(home.recents.first)
        let details = try home.makeDetails(prefill: recent.template, now: now)
        XCTAssertEqual(details.unit, .teaspoon)
        XCTAssertEqual(details.amountText, "4")
        XCTAssertTrue(details.save(now: now))
        let copy = try XCTUnwrap(store.activeIntakes().first { $0.id != intake.id })
        XCTAssertEqual(try store.loggedUnits().filter { $0.intakeID == copy.id }.map(\.unit), [.teaspoon])
    }

    func testQuickAddFromRecentCanBeUndone() throws {
        let store = try makeStore()
        let seed = AddIntakeViewModel(store: store, now: now, timeZoneIdentifier: "UTC")
        seed.name = "Oats"
        seed.amountText = "40"
        XCTAssertTrue(seed.save(now: now))
        let home = AddHomeViewModel(store: store, meal: .lunch, now: { self.now })
        home.load()
        let recent = try XCTUnwrap(home.recents.first)
        let token = try XCTUnwrap(home.quickAdd(recent))
        let added = try XCTUnwrap(store.activeIntakes().first { $0.id == token.intakeID })
        XCTAssertEqual(added.meal, "lunch")
        XCTAssertTrue(home.undo())
        XCTAssertFalse(try store.activeIntakes().contains { $0.id == token.intakeID })
        XCTAssertEqual(try store.activeIntakes().count, 1)
    }

    /// A one-tap Recent with Meal set to None keeps the meal the item was logged under.
    func testQuickAddFromRecentWithNoMealKeepsTheItemsOwnMeal() throws {
        let store = try makeStore()
        let seed = AddIntakeViewModel(store: store, now: now, timeZoneIdentifier: "UTC")
        seed.name = "Oats"
        seed.amountText = "40"
        seed.meal = .breakfast
        XCTAssertTrue(seed.save(now: now))
        let home = AddHomeViewModel(store: store, meal: nil, now: { self.now })
        home.load()
        let recent = try XCTUnwrap(home.recents.first)
        let token = try XCTUnwrap(home.quickAdd(recent))
        let added = try XCTUnwrap(store.activeIntakes().first { $0.id == token.intakeID })
        XCTAssertEqual(added.meal, "breakfast")
    }

    /// A one-tap Recent with Meal chosen on Add home is logged under the chosen meal.
    func testQuickAddFromRecentWithAChosenMealUsesThatMeal() throws {
        let store = try makeStore()
        let seed = AddIntakeViewModel(store: store, now: now, timeZoneIdentifier: "UTC")
        seed.name = "Oats"
        seed.amountText = "40"
        seed.meal = .breakfast
        XCTAssertTrue(seed.save(now: now))
        let home = AddHomeViewModel(store: store, meal: .dinner, now: { self.now })
        home.load()
        let recent = try XCTUnwrap(home.recents.first)
        let token = try XCTUnwrap(home.quickAdd(recent))
        let added = try XCTUnwrap(store.activeIntakes().first { $0.id == token.intakeID })
        XCTAssertEqual(added.meal, "dinner")
    }

    func testScannedBarcodeStartsTheLookupButTypingDoesNot() async throws {
        let home = AddHomeViewModel(store: try makeStore(), lookup: MissingProductLookup())
        let typed = home.makeDetails(now: now)
        typed.barcode = "4006381333931"
        XCTAssertEqual(typed.lookupState, .idle)
        let scanned = home.makeDetails(now: now)
        await home.scannedBarcode("4006381333931", into: scanned)
        XCTAssertEqual(scanned.lookupState, .notFound)
    }

    func testMealPresetIsCarriedFromRecipeAndItsValuesSurviveSave() throws {
        let store = try makeStore()
        let home = AddHomeViewModel(store: store, meal: .lunch)
        let details = try home.makeDetails(recipe: uiSampleVersion(), now: now)
        XCTAssertEqual(details.meal, .lunch)
        XCTAssertEqual(details.unit, .serving)
        XCTAssertEqual(details.prefilledNutrients["energy"], .known(215, .kcal))
        XCTAssertTrue(details.save(now: now))
        let intake = try XCTUnwrap(store.activeIntakes().first)
        XCTAssertEqual(intake.meal, "lunch")
        let revision = try XCTUnwrap(store.revisions(of: intake.id).first)
        let product = try XCTUnwrap(store.product(snapshotID: try XCTUnwrap(revision.productSnapshotID)))
        XCTAssertEqual(product.nutrients["energy"], .known(215, .kcal))
    }

    func testRecipeDetailsUseTheRecipeLoggerBasis() throws {
        let home = AddHomeViewModel(store: try makeStore())
        let sample = uiSampleVersion()
        for yield in [RecipeYield.servings(4), .total(Quantity(value: 220, unit: .g))] {
            let recipe = RecipeVersion(
                recipeID: sample.recipeID, number: sample.number, title: sample.title,
                ingredients: sample.ingredients, yield: yield, createdAt: sample.createdAt)
            let details = try home.makeDetails(recipe: recipe, now: now)
            let product = try XCTUnwrap(details.productSnapshot())
            XCTAssertEqual(product.labelBasis, RecipeLogger.basisText(yield))
        }
    }

    func testLibraryPickKeepsEveryAmountInAMixedUnitTemplate() throws {
        let home = AddHomeViewModel(store: try makeStore(), meal: .lunch)
        let template = RepeatTemplate(displayName: "Oats and milk", category: "food",
            components: [
                IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g),
                IntakeComponent(componentID: "milk", name: "Milk", amount: 100, unit: .mL)
            ])
        let details = try home.makeDetails(prefill: template, now: now)
        XCTAssertEqual(details.unit, .serving)
        XCTAssertEqual(details.amountText, "1")
        XCTAssertTrue(details.name.contains("40 g"))
        XCTAssertTrue(details.name.contains("100 mL"))
        XCTAssertEqual(details.meal, .lunch)
    }

    func testLibraryPickKeepsTheProductSnapshot() throws {
        let store = try makeStore()
        let product = ProductDefinition(
            snapshotID: "stored-oats", productID: "4006381333931", name: "Oats",
            brand: "Example", barcode: "4006381333931", labelBasis: "per 100 g",
            catalogOrigin: "example-catalog", catalogVersion: "1",
            nutrients: ["energy": .known(380, .kcal)])
        let component = IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g)
        try store.create(
            Intake(id: "0a6f1c1e-5b0e-4f7a-9c35-2d1e8f4b7a10", category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [component], product: product, now: now)
        let template = RepeatTemplate(displayName: "Oats", category: "food",
            components: [component], productSnapshotID: product.snapshotID)
        let home = AddHomeViewModel(store: store)
        for edited in [false, true] {
            let details = try home.makeDetails(prefill: template, now: now)
            if edited { details.name = "Edited oats" }
            let existingIDs = Set(try store.activeIntakes().map(\.id))
            XCTAssertTrue(details.save(now: now))
            let intake = try XCTUnwrap(store.activeIntakes().first { !existingIDs.contains($0.id) })
            let revision = try XCTUnwrap(store.revisions(of: intake.id).first)
            if edited {
                XCTAssertNotEqual(revision.productSnapshotID, product.snapshotID)
                let saved = try XCTUnwrap(store.product(snapshotID: try XCTUnwrap(revision.productSnapshotID)))
                XCTAssertEqual(saved.name, "Edited oats")
                XCTAssertEqual(saved.nutrients, product.nutrients)
            } else {
                XCTAssertEqual(revision.productSnapshotID, product.snapshotID)
            }
        }
    }

    func testRecipeWithNoKnownNutrientsIsRefused() throws {
        let home = AddHomeViewModel(store: try makeStore())
        for known in [false, true] {
            let recipe = RecipeVersion(
                recipeID: "example-oats", number: 1, title: "Oats",
                ingredients: [RecipeIngredient(
                    id: "oats", name: "Oats", quantity: Quantity(value: 40, unit: .g),
                    perUnit: ["energy": known ? .known(0, .kcal) : .unknown])],
                yield: .servings(1), createdAt: now)
            if known {
                let details = try home.makeDetails(recipe: recipe, now: now)
                XCTAssertEqual(details.prefilledNutrients["energy"], .known(0, .kcal))
            } else {
                XCTAssertThrowsError(try home.makeDetails(recipe: recipe, now: now)) { error in
                    guard case RecipeError.nothingToLog = error else {
                        return XCTFail("Expected nothingToLog, got \(error)")
                    }
                }
            }
        }
    }
}

private struct MissingProductLookup: BarcodeProductLookup {
    func lookUp(barcode: String) async -> BarcodeLookupResult { .notFound }
}

extension AddHomeTests {
    func testStandaloneProductOpensDetailsWithoutInventingHistoryOrOperation() throws {
        let store = try makeStore(), item = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: .init(name: "Synthetic capsule", kind: .supplement, basis: .perServing))
        try store.saveCustomProduct(.init(revision: item), now: now)
        let home = AddHomeViewModel(store: store, meal: .lunch)
        let details = try home.makeDetails(product: item, now: now)
        XCTAssertEqual(details.name, item.content.name)
        XCTAssertEqual(details.kind, .supplement)
        XCTAssertEqual(details.meal, .lunch)
        XCTAssertEqual(details.amountText, "")
        XCTAssertTrue(details.isCustomProduct)
        XCTAssertTrue(try store.activeIntakes().isEmpty)
        XCTAssertTrue(try store.productOperations(ownerID: UUID()).isEmpty)
        details.amountText = "2"; details.unit = .capsule
        XCTAssertTrue(details.save(now: now))
        XCTAssertEqual(try store.activeIntakes().count, 1)
        XCTAssertEqual(details.productSnapshot()?.snapshotID, item.revisionID.uuidString)
    }
}
