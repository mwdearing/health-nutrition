import Foundation
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
        let store = try SwiftDataRecipeStore(url: url)
        try store.saveNewVersion(version())
        store.afterRowsDeleted = {
            // The erase holds writeLock here, not the store lock, so a close from another thread can run now.
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                store.close()
                finished.signal()
            }
            finished.wait()
        }
        try store.eraseAll()
        XCTAssertThrowsError(try store.list()) { error in
            XCTAssertEqual(error as? RecipeStoreError, .closed, "the erase reopened a store that was closed")
        }
        XCTAssertThrowsError(try store.saveNewVersion(version())) { error in
            XCTAssertEqual(error as? RecipeStoreError, .closed)
        }
    }
}
