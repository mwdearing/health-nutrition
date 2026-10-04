import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

final class RecipeLoggerTests: XCTestCase {
    private let intakeID = "0b6f7d3e-5a1c-4c52-9a2e-3f1d8c7b6a10"
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeJournal() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// One intake, one revision, ONE component named after the recipe: the recipe the user chose,
    /// not a list of nutrients.
    func testLogCreatesOneIntakeWithOneComponentNamedAfterTheRecipe() throws {
        let journal = try makeJournal()
        let id = try RecipeLogger.logPortion(
            store: journal, version: sampleVersion(), portion: 1, now: when, id: intakeID,
            timeZoneIdentifier: "UTC", meal: "dinner")
        XCTAssertEqual(id, intakeID)
        XCTAssertEqual(try journal.activeIntakes().count, 1)
        let revisions = try journal.revisions(of: intakeID)
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(revisions[0].productSnapshotID, "recipe:recipe-1:v1")
        XCTAssertEqual(revisions[0].components.count, 1)
        XCTAssertEqual(revisions[0].components[0].name, "Oat bake")
        XCTAssertEqual(revisions[0].components[0].amount, 1)
        XCTAssertEqual(revisions[0].components[0].unit, .serving)
        let product = try journal.product(snapshotID: "recipe:recipe-1:v1")
        XCTAssertEqual(product?.catalogOrigin, "recipe_calculated")
        XCTAssertEqual(product?.catalogVersion, "1")
        XCTAssertEqual(product?.productID, "recipe-1")
        XCTAssertEqual(try journal.activeIntakes().first?.category, "recipe")
    }

    /// The snapshot carries the per-serving values, so a later reader resolves the recipe's nutrients
    /// from the product rather than from one component per nutrient.
    func testSnapshotCarriesThePerServingNutrients() throws {
        let journal = try makeJournal()
        let version = sampleVersion(
            ingredients: [
                sampleIngredient(
                    "oat-flour", amount: "200",
                    perUnit: ["energy": .known(dec("3.6"), .kcal), "protein": .known(dec("0.13"), .g)]),
            ], yield: .servings(4))
        try RecipeLogger.logPortion(
            store: journal, version: version, portion: 1, now: when, id: intakeID, timeZoneIdentifier: "UTC", meal: nil)
        let product = try XCTUnwrap(try journal.product(snapshotID: "recipe:recipe-1:v1"))
        // 200 g of oat flour over 4 servings.
        XCTAssertEqual(product.value(for: "energy"), .known(dec("180"), .kcal))
        XCTAssertEqual(product.value(for: "protein"), .known(dec("6.5"), .g))
    }

    /// An unknown nutrient is stored as unknown in the snapshot, never as a zero the totals would read.
    func testUnknownNutrientsStayUnknownInTheSnapshotAndAreNotComponents() throws {
        let journal = try makeJournal()
        let version = sampleVersion(
            ingredients: [
                sampleIngredient("a", amount: "10", perUnit: ["energy": .known(2, .kcal), "protein": .known(1, .g)]),
                sampleIngredient("b", amount: "10", perUnit: ["energy": .known(2, .kcal)]),
            ], yield: .servings(1))
        try RecipeLogger.logPortion(
            store: journal, version: version, portion: 1, now: when, id: intakeID, timeZoneIdentifier: "UTC", meal: nil)
        let revision = try journal.revisions(of: intakeID)[0]
        XCTAssertEqual(revision.components.count, 1)
        XCTAssertEqual(revision.components[0].name, "Oat bake")
        let product = try XCTUnwrap(try journal.product(snapshotID: "recipe:recipe-1:v1"))
        XCTAssertEqual(product.value(for: "energy"), .known(40, .kcal))
        XCTAssertEqual(product.value(for: "protein"), .unknown)
    }

    /// A known zero is a value like any other: it stays a zero in the snapshot and does not become a
    /// component with a zero amount the entry editor could not read back.
    func testKnownZeroStaysZeroInTheSnapshotAndTheComponentKeepsThePortion() throws {
        let journal = try makeJournal()
        let version = sampleVersion(
            ingredients: [sampleIngredient("a", amount: "10", perUnit: ["sodium": .known(0, .mg)])],
            yield: .servings(2))
        try RecipeLogger.logPortion(
            store: journal, version: version, portion: 1, now: when, id: intakeID, timeZoneIdentifier: "UTC", meal: nil)
        let component = try journal.revisions(of: intakeID)[0].components[0]
        XCTAssertEqual(component.amount, 1)
        XCTAssertEqual(component.unit, .serving)
        let product = try XCTUnwrap(try journal.product(snapshotID: "recipe:recipe-1:v1"))
        XCTAssertEqual(product.value(for: "sodium"), .known(0, .mg))
    }

    /// A total yield logs the portion in the yield's own unit, so the component reads like any other
    /// amount of food.
    func testTotalYieldLogsThePortionInTheYieldsUnit() throws {
        let journal = try makeJournal()
        let version = sampleVersion(
            ingredients: [sampleIngredient("oat-flour", amount: "800", perUnit: energyPerUnit("3.6"))],
            yield: .total(Quantity(value: dec("0.8"), unit: .kg)))
        try RecipeLogger.logPortion(
            store: journal, version: version, portion: 200, now: when, id: intakeID,
            timeZoneIdentifier: "UTC", meal: nil, portionUnit: .g)
        let component = try journal.revisions(of: intakeID)[0].components[0]
        XCTAssertEqual(component.amount, dec("0.2"))
        XCTAssertEqual(component.unit, .kg)
    }

    func testNothingKnownThrowsAndWritesNothing() throws {
        let journal = try makeJournal()
        let version = sampleVersion(ingredients: [sampleIngredient("a", amount: "10", perUnit: [:])])
        XCTAssertThrowsError(try RecipeLogger.logPortion(
            store: journal, version: version, portion: 1, now: when, id: intakeID, timeZoneIdentifier: "UTC", meal: nil)
        ) { XCTAssertEqual($0 as? RecipeError, .nothingToLog) }
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
    }

    func testLoggedIntakeKeepsVersion1AfterVersion2Exists() throws {
        let journal = try makeJournal()
        let recipes = try SwiftDataRecipeStore(url: try makeRecipeStoreURL(self))
        let v1 = sampleVersion()
        try recipes.saveNewVersion(v1)
        try RecipeLogger.logPortion(
            store: journal, version: v1, portion: 1, now: when, id: intakeID, timeZoneIdentifier: "UTC", meal: nil)
        let v2 = sampleVersion(
            number: 2,
            ingredients: [sampleIngredient("oat-flour", amount: "400", perUnit: energyPerUnit("3.6"))])
        try recipes.saveNewVersion(v2)
        let revision = try journal.revisions(of: intakeID)[0]
        XCTAssertEqual(revision.productSnapshotID, "recipe:recipe-1:v1")
        let product = try XCTUnwrap(try journal.product(snapshotID: "recipe:recipe-1:v1"))
        XCTAssertEqual(product.catalogVersion, "1")
        // 200 g of oat flour plus 20 g of olive oil over 4 servings.
        XCTAssertEqual(product.value(for: "energy"), .known(dec("224"), .kcal))
        XCTAssertEqual(revision.components[0].amount, 1)
        XCTAssertEqual(try recipes.version(recipeID: "recipe-1", number: 1), v1)
    }

    func testNonPositivePortionWritesNothing() throws {
        let journal = try makeJournal()
        XCTAssertThrowsError(try RecipeLogger.logPortion(
            store: journal, version: sampleVersion(), portion: 0, now: when, id: intakeID,
            timeZoneIdentifier: "UTC", meal: nil))
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
    }

    /// The component id is a valid journal component id for any recipe identifier, including one
    /// whose characters are not slug characters.
    func testComponentIDIsValidForAwkwardRecipeIdentifiers() throws {
        for identifier in ["recipe-1", "Recipe 1", "recipe/one", "Ω", String(repeating: "a", count: 90)] {
            let id = RecipeLogger.componentID(for: identifier)
            XCTAssertTrue(JournalValidation.isValidComponentID(id), "\(identifier) -> \(id)")
            XCTAssertEqual(id, RecipeLogger.componentID(for: identifier))
        }
    }

    /// The journal refuses two components with the same id in one intake, which is what one-per-nutrient
    /// logging ran into. One component per logged recipe cannot collide, so two recipes logged on the
    /// same day both go in.
    func testTwoLoggedRecipesBothWriteAnIntake() throws {
        let journal = try makeJournal()
        let second = "1f8c2d64-9a3b-4f0e-8c5d-7b6e2a9d4c11"
        try RecipeLogger.logPortion(
            store: journal, version: sampleVersion(), portion: 1, now: when, id: intakeID,
            timeZoneIdentifier: "UTC", meal: nil)
        try RecipeLogger.logPortion(
            store: journal, version: sampleVersion(recipeID: "recipe-2", title: "Oat bars"), portion: 2,
            now: when, id: second, timeZoneIdentifier: "UTC", meal: nil)
        XCTAssertEqual(try journal.activeIntakes().count, 2)
        for intake in try journal.activeIntakes() {
            let components = try journal.revisions(of: intake.id)[0].components
            XCTAssertEqual(components.count, 1)
            XCTAssertEqual(Set(components.map(\.componentID)).count, 1)
        }
    }
}