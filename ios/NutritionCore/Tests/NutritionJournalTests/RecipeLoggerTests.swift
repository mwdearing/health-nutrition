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

    func testLogCreatesOneIntakeAndOneRevisionWithRecipeSnapshot() throws {
        let journal = try makeJournal()
        let id = try RecipeLogger.logPortion(
            store: journal, version: sampleVersion(), portion: 1, now: when, id: intakeID,
            timeZoneIdentifier: "UTC", meal: "dinner")
        XCTAssertEqual(id, intakeID)
        XCTAssertEqual(try journal.activeIntakes().count, 1)
        let revisions = try journal.revisions(of: intakeID)
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(revisions[0].productSnapshotID, "recipe:recipe-1:v1")
        XCTAssertEqual(revisions[0].components.map { $0.componentID }, ["nutrient-energy"])
        XCTAssertEqual(revisions[0].components[0].amount, dec("224"))
        let product = try journal.product(snapshotID: "recipe:recipe-1:v1")
        XCTAssertEqual(product?.catalogOrigin, "recipe_calculated")
        XCTAssertEqual(product?.catalogVersion, "1")
        XCTAssertEqual(product?.productID, "recipe-1")
        XCTAssertEqual(try journal.activeIntakes().first?.category, "recipe")
    }

    func testUnknownNutrientsAreNotWrittenAsZero() throws {
        let journal = try makeJournal()
        let version = sampleVersion(
            ingredients: [
                sampleIngredient("a", amount: "10", perUnit: ["energy": .known(2, .kcal), "protein": .known(1, .g)]),
                sampleIngredient("b", amount: "10", perUnit: ["energy": .known(2, .kcal)]),
            ], yield: .servings(1))
        try RecipeLogger.logPortion(
            store: journal, version: version, portion: 1, now: when, id: intakeID, timeZoneIdentifier: "UTC", meal: nil)
        let components = try journal.revisions(of: intakeID)[0].components
        XCTAssertEqual(components.map { $0.componentID }, ["nutrient-energy"])
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
        XCTAssertEqual(try journal.product(snapshotID: "recipe:recipe-1:v1")?.catalogVersion, "1")
        XCTAssertEqual(revision.components[0].amount, dec("224"))
        XCTAssertEqual(try recipes.version(recipeID: "recipe-1", number: 1), v1)
    }

    func testNonPositivePortionWritesNothing() throws {
        let journal = try makeJournal()
        XCTAssertThrowsError(try RecipeLogger.logPortion(
            store: journal, version: sampleVersion(), portion: 0, now: when, id: intakeID,
            timeZoneIdentifier: "UTC", meal: nil))
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
    }
}
