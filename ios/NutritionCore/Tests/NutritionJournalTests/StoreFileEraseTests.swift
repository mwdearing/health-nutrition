import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// The goal, favorites and recipe stores erase their files the way the journal store does (#228): the store file and
/// its write-ahead and shared-memory files are deleted and an empty store opens at the same place, so the erased rows
/// are not left in pages SQLite has not reused yet.
final class StoreFileEraseTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func favorite(_ id: String) -> FavoriteTemplate {
        FavoriteTemplate(
            id: id, displayName: "Oat porridge", category: "food",
            components: [FavoriteComponent(componentID: "oats", name: "Oats", amountText: "40", unitSymbol: "g")])
    }

    /// The file's identity before and after `erase`. A plain read handle on the old file keeps its inode allocated for
    /// the whole erase, so the replacement cannot reuse the number. It is not a SQLite connection and takes no lock.
    private func assertFileIsReplaced(at url: URL, by erase: () throws -> Void) throws {
        let before = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64)
        let pinned = try FileHandle(forReadingFrom: url)
        defer { try? pinned.close() }
        try erase()
        let after = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64)
        // A store wiped in place keeps its file; a replaced file has a new one.
        XCTAssertNotEqual(before, after, "the erase deleted rows but left the store file in place")
    }

    // MARK: - The store file is replaced

    func testAGoalEraseReplacesTheStoreFileAndTheStoreStaysUsable() throws {
        let url = try makeDirectory().appendingPathComponent("goals.store")
        let store = try SwiftDataGoalStore(url: url)
        try store.setGoal(NutrientGoal(nutrient: "protein", target: 100, unit: .g))

        try assertFileIsReplaced(at: url) { try store.eraseAll() }

        XCTAssertTrue(try store.goals().isEmpty)
        try store.setGoal(NutrientGoal(nutrient: "fiber", target: 30, unit: .g))
        XCTAssertEqual(try store.goals().map(\.nutrient), ["fiber"])
        store.close()
        let reopened = try SwiftDataGoalStore(url: url)
        XCTAssertEqual(try reopened.goals().map(\.nutrient), ["fiber"])
        reopened.close()
    }

    func testAFavoritesEraseReplacesTheStoreFileAndTheStoreStaysUsable() throws {
        let url = try makeDirectory().appendingPathComponent("favorites.store")
        let store = try SwiftDataFavoritesStore(url: url)
        try store.add(favorite("fav-1"))

        try assertFileIsReplaced(at: url) { try store.eraseAll() }

        XCTAssertTrue(try store.list().isEmpty)
        try store.add(favorite("fav-2"))
        XCTAssertEqual(try store.list().map(\.id), ["fav-2"])
        store.close()
    }

    func testARecipeEraseReplacesTheStoreFileAndTheStoreStaysUsable() throws {
        let url = try makeRecipeStoreURL(self)
        let store = try SwiftDataRecipeStore(url: url)
        try store.saveNewVersion(sampleVersion())

        try assertFileIsReplaced(at: url) { try store.eraseAll() }

        XCTAssertTrue(try store.versions(of: "recipe-1").isEmpty)
        try store.saveNewVersion(sampleVersion())
        XCTAssertEqual(try store.list().recipes.map(\.recipeID), ["recipe-1"])
        store.close()
    }
}
