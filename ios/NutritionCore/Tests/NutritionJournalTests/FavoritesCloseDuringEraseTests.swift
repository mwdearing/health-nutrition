import Foundation
import NutritionJournal
import XCTest
@testable import NutritionJournal

/// #1156: a `close()` that lands between an erase's row delete and its file replacement must stay closed. The erase
/// may still remove the file, but it must not reopen the store for later calls.
final class FavoritesCloseDuringEraseTests: XCTestCase {
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

    func testACloseDuringAnEraseStaysClosed() throws {
        let url = try makeDirectory().appendingPathComponent("favorites.store")
        let store = try SwiftDataFavoritesStore(url: url)
        try store.add(favorite("porridge"))
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
            XCTAssertEqual(error as? FavoritesError, .closed, "the erase reopened a store that was closed")
        }
        XCTAssertThrowsError(try store.add(favorite("again"))) { error in
            XCTAssertEqual(error as? FavoritesError, .closed)
        }
    }
}
