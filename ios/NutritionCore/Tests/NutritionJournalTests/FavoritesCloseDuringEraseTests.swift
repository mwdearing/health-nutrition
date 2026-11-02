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
        var operations = StoreFileOperations.system
        var storeRef: SwiftDataFavoritesStore?
        operations.afterRowsDeleted = {
            // The erase holds writeLock here, not the store lock, so a close from another thread can run now.
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                storeRef?.close()
                finished.signal()
            }
            finished.wait()
        }
        let store = try SwiftDataFavoritesStore(url: url, fileOperations: operations)
        storeRef = store
        try store.add(favorite("porridge"))
        try store.eraseAll()
        XCTAssertThrowsError(try store.list()) { error in
            XCTAssertEqual(error as? FavoritesError, .closed, "the erase reopened a store that was closed")
        }
        XCTAssertThrowsError(try store.add(favorite("again"))) { error in
            XCTAssertEqual(error as? FavoritesError, .closed)
        }
    }

    /// The emptied container is not held after a close during an erase (#1156): the store must drop the container the
    /// erase opened, so nothing keeps the file open once the store is closed.
    func testTheEmptiedContainerIsNotHeldAfterACloseDuringAnErase() throws {
        let url = try makeDirectory().appendingPathComponent("favorites.store")
        final class Probe { weak var container: ModelContainer? }
        let probe = Probe()
        var operations = StoreFileOperations.system
        let opening = operations.openContainer
        operations.openContainer = { url in
            let container = try opening(url)
            probe.container = container
            return container
        }
        var storeRef: SwiftDataFavoritesStore?
        operations.afterRowsDeleted = {
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                storeRef?.close()
                finished.signal()
            }
            finished.wait()
        }
        let store = try SwiftDataFavoritesStore(url: url, fileOperations: operations)
        storeRef = store
        try autoreleasepool { try store.eraseAll() }
        XCTAssertNil(probe.container, "a closed store kept the container its erase opened, so the file stays open")
    }
}
