import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

final class RecipeStoreTests: XCTestCase {
    func testSaveAndReadBackKeepsExactDecimals() throws {
        let url = try makeRecipeStoreURL(self)
        let first = try SwiftDataRecipeStore(url: url)
        let version = sampleVersion(yield: .total(Quantity(value: dec("0.1"), unit: .kg)))
        try first.saveNewVersion(version)
        first.close()
        let second = try SwiftDataRecipeStore(url: url)
        XCTAssertEqual(try second.version(recipeID: "recipe-1", number: 1), version)
        second.close()
    }

    func testEditCreatesVersion2AndVersion1Unchanged() throws {
        let store = try SwiftDataRecipeStore(url: try makeRecipeStoreURL(self))
        let v1 = sampleVersion()
        try store.saveNewVersion(v1)
        let v2 = sampleVersion(number: 2, title: "Oat bake, richer")
        try store.saveNewVersion(v2)
        XCTAssertEqual(try store.version(recipeID: "recipe-1", number: 1), v1)
        XCTAssertEqual(try store.versions(of: "recipe-1").map { $0.number }, [1, 2])
        XCTAssertEqual(try store.list().recipes.map { $0.number }, [2])
    }

    func testVersionNumberMustFollowLatestAndNeverOverwrites() throws {
        let store = try SwiftDataRecipeStore(url: try makeRecipeStoreURL(self))
        XCTAssertThrowsError(try store.saveNewVersion(sampleVersion(number: 2))) {
            XCTAssertEqual($0 as? RecipeStoreError, .versionConflict(expected: 1, got: 2))
        }
        try store.saveNewVersion(sampleVersion())
        XCTAssertThrowsError(try store.saveNewVersion(sampleVersion(title: "Changed"))) {
            XCTAssertEqual($0 as? RecipeStoreError, .versionConflict(expected: 2, got: 1))
        }
        XCTAssertEqual(try store.version(recipeID: "recipe-1", number: 1)?.title, "Oat bake")
    }

    func testInvalidVersionIsNotSaved() throws {
        let store = try SwiftDataRecipeStore(url: try makeRecipeStoreURL(self))
        XCTAssertThrowsError(try store.saveNewVersion(sampleVersion(yield: .servings(0))))
        XCTAssertTrue(try store.list().recipes.isEmpty)
    }

    func testCorruptStoredRecipeIsSkippedAndCounted() throws {
        let store = try SwiftDataRecipeStore(url: try makeRecipeStoreURL(self))
        try store.saveNewVersion(sampleVersion())
        try store.insertRawRowForTesting(
            recipeID: "broken", number: 1, title: "Broken", payloadJSON: "{not json",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let invalid = "{\"ingredients\":[],\"yield\":{\"kind\":\"servings\",\"amountText\":\"4\"}}"
        try store.insertRawRowForTesting(
            recipeID: "empty", number: 1, title: "Empty", payloadJSON: invalid,
            createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        let result = try store.list()
        XCTAssertEqual(result.recipes.map { $0.recipeID }, ["recipe-1"])
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertThrowsError(try store.version(recipeID: "broken", number: 1)) {
            XCTAssertEqual($0 as? RecipeStoreError, .corruptRecord("broken:1"))
        }
    }

    func testDeleteHidesRecipeButKeepsVersions() throws {
        let store = try SwiftDataRecipeStore(url: try makeRecipeStoreURL(self))
        try store.saveNewVersion(sampleVersion())
        try store.saveNewVersion(sampleVersion(number: 2))
        try store.deleteRecipe(id: "recipe-1")
        XCTAssertTrue(try store.list().recipes.isEmpty)
        XCTAssertEqual(try store.versions(of: "recipe-1").count, 2)
        XCTAssertNotNil(try store.version(recipeID: "recipe-1", number: 1))
        XCTAssertThrowsError(try store.saveNewVersion(sampleVersion(number: 3)))
    }

    func testListIsNewestFirst() throws {
        let store = try SwiftDataRecipeStore(url: try makeRecipeStoreURL(self))
        try store.saveNewVersion(sampleVersion(recipeID: "older", createdAt: Date(timeIntervalSince1970: 1_000)))
        try store.saveNewVersion(sampleVersion(recipeID: "newer", createdAt: Date(timeIntervalSince1970: 2_000)))
        XCTAssertEqual(try store.list().recipes.map { $0.recipeID }, ["newer", "older"])
    }

    func testClosedStoreThrows() throws {
        let store = try SwiftDataRecipeStore(url: try makeRecipeStoreURL(self))
        store.close()
        XCTAssertThrowsError(try store.list()) { XCTAssertEqual($0 as? RecipeStoreError, .closed) }
    }
}
