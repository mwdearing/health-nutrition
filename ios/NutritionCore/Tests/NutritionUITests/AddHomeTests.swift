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
            let product = try XCTUnwrap(details.labelValues)
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
}

private struct MissingProductLookup: BarcodeProductLookup {
    func lookUp(barcode: String) async -> BarcodeLookupResult { .notFound }
}
