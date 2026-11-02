import Foundation
import SwiftData
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// #1156: a `close()` that lands between an erase's row delete and its file replacement must stay closed.
final class RecipeCloseDuringEraseTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func version() -> RecipeVersion {
        RecipeVersion(
            recipeID: "recipe-1", number: 1, title: "Oat bake",
            ingredients: [
                RecipeIngredient(
                    id: "oat-flour", name: "Oat flour", quantity: Quantity(value: 200, unit: .g),
                    perUnit: ["energy": .known(3.5, .kcal)]),
            ],
            yield: .servings(4), createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testACloseDuringAnEraseStaysClosed() throws {
        let url = try makeDirectory().appendingPathComponent("recipes.store")
        var operations = StoreFileOperations.system
        var storeRef: SwiftDataRecipeStore?
        operations.afterRowsDeleted = {
            // The erase holds writeLock here, not the store lock, so a close from another thread can run now.
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                storeRef?.close()
                finished.signal()
            }
            finished.wait()
        }
        let store = try SwiftDataRecipeStore(url: url, fileOperations: operations)
        storeRef = store
        try store.saveNewVersion(version())
        try store.eraseAll()
        XCTAssertThrowsError(try store.list()) { error in
            XCTAssertEqual(error as? RecipeStoreError, .closed, "the erase reopened a store that was closed")
        }
        XCTAssertThrowsError(try store.saveNewVersion(version())) { error in
            XCTAssertEqual(error as? RecipeStoreError, .closed)
        }
    }

    /// The emptied container is not held after a close during an erase (#1156): the store must drop the container the
    /// erase opened, so nothing keeps the file open once the store is closed.
    func testTheEmptiedContainerIsNotHeldAfterACloseDuringAnErase() throws {
        let url = try makeDirectory().appendingPathComponent("recipes.store")
        final class Probe { weak var container: ModelContainer? }
        let probe = Probe()
        var operations = StoreFileOperations.system
        let opening = operations.openContainer
        operations.openContainer = { url in
            let container = try opening(url)
            probe.container = container
            return container
        }
        var storeRef: SwiftDataRecipeStore?
        operations.afterRowsDeleted = {
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                storeRef?.close()
                finished.signal()
            }
            finished.wait()
        }
        let store = try SwiftDataRecipeStore(url: url, fileOperations: operations)
        storeRef = store
        try autoreleasepool { try store.eraseAll() }
        XCTAssertNil(probe.container, "a closed store kept the container its erase opened, so the file stays open")
    }
}
