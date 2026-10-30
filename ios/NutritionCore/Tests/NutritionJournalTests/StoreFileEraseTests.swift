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

    // MARK: - A failed removal is reported

    /// Removal that fails on the first file it is asked to delete. The erase must throw, so the screen names the store as
    /// still on the phone rather than reporting a clean erase, and no later file is removed after the failure.
    private func failingRemoval(_ calls: RemovedFiles, opening open: @escaping (URL) throws -> ModelContainer)
        -> StoreFileOperations
    {
        StoreFileOperations(
            checkpoint: { _ in },
            remove: { file in
                calls.names.append(file.lastPathComponent)
                throw CocoaError(.fileWriteNoPermission)
            },
            openContainer: open)
    }

    func testAFailedGoalFileRemovalIsReported() throws {
        let url = try makeDirectory().appendingPathComponent("goals.store")
        let calls = RemovedFiles()
        let store = try SwiftDataGoalStore(
            url: url, fileOperations: failingRemoval(calls, opening: SwiftDataGoalStore.makeContainer))
        try store.setGoal(NutrientGoal(nutrient: "protein", target: 100, unit: .g))

        XCTAssertThrowsError(try store.eraseAll()) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteNoPermission)
        }
        XCTAssertEqual(calls.names.count, 1, "the erase stops at the first failed removal")
        // The rows were deleted before the files, and the store reopened on the file the erase left.
        XCTAssertTrue(try store.goals().isEmpty)
        store.close()
    }

    func testAFailedFavoritesFileRemovalIsReported() throws {
        let url = try makeDirectory().appendingPathComponent("favorites.store")
        let calls = RemovedFiles()
        let store = try SwiftDataFavoritesStore(
            url: url, fileOperations: failingRemoval(calls, opening: SwiftDataFavoritesStore.makeContainer))
        try store.add(favorite("fav-1"))

        XCTAssertThrowsError(try store.eraseAll()) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteNoPermission)
        }
        XCTAssertEqual(calls.names.count, 1, "the erase stops at the first failed removal")
        XCTAssertTrue(try store.list().isEmpty)
        store.close()
    }

    func testAFailedRecipeFileRemovalIsReported() throws {
        let url = try makeRecipeStoreURL(self)
        let calls = RemovedFiles()
        let store = try SwiftDataRecipeStore(
            url: url, fileOperations: failingRemoval(calls, opening: SwiftDataRecipeStore.makeContainer))
        try store.saveNewVersion(sampleVersion())

        XCTAssertThrowsError(try store.eraseAll()) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteNoPermission)
        }
        XCTAssertEqual(calls.names.count, 1, "the erase stops at the first failed removal")
        XCTAssertTrue(try store.versions(of: "recipe-1").isEmpty)
        store.close()
    }

    /// A checkpoint that fails removes nothing and the erase reports it.
    func testAFailedGoalCheckpointRemovesNothing() throws {
        let url = try makeDirectory().appendingPathComponent("goals.store")
        let calls = RemovedFiles()
        let store = try SwiftDataGoalStore(
            url: url,
            fileOperations: StoreFileOperations(
                checkpoint: { _ in throw StoreFileError.checkpointFailed },
                remove: { file in
                    calls.names.append(file.lastPathComponent)
                    try FileManager.default.removeItem(at: file)
                },
                openContainer: SwiftDataGoalStore.makeContainer))
        try store.setGoal(NutrientGoal(nutrient: "protein", target: 100, unit: .g))

        XCTAssertThrowsError(try store.eraseAll()) { XCTAssertEqual($0 as? StoreFileError, .checkpointFailed) }
        XCTAssertTrue(calls.names.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        store.close()
    }

    /// When the reopen after an erase fails, the erase reports it, and the next call retries the reopen.
    func testAFailedGoalReopenIsRetriedByTheNextCall() throws {
        let url = try makeDirectory().appendingPathComponent("goals.store")
        let reopen = ReopenSwitch()
        let store = try SwiftDataGoalStore(
            url: url,
            fileOperations: StoreFileOperations(
                checkpoint: { _ in },
                remove: { try FileManager.default.removeItem(at: $0) },
                openContainer: { url in
                    if reopen.fails { throw CocoaError(.fileWriteNoPermission) }
                    return try SwiftDataGoalStore.makeContainer(url: url)
                }))
        try store.setGoal(NutrientGoal(nutrient: "protein", target: 100, unit: .g))

        reopen.fails = true
        XCTAssertThrowsError(try store.eraseAll()) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteNoPermission)
        }
        XCTAssertThrowsError(try store.goals()) { XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteNoPermission) }
        reopen.fails = false
        XCTAssertTrue(try store.goals().isEmpty)
        store.close()
    }
}

/// The file names a test's removal step was asked to delete, in order.
private final class RemovedFiles: @unchecked Sendable {
    var names: [String] = []
}

/// Lets a test make a store's reopen fail, then succeed, on later calls.
private final class ReopenSwitch: @unchecked Sendable {
    var fails = false
}
