import Foundation
import SwiftData
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
        var operations = StoreFileOperations.systemOperations(opening: SwiftDataFavoritesStore.makeContainer)
        final class StoreBox { weak var store: SwiftDataFavoritesStore? }
        let storeRef = StoreBox()
        operations.afterRowsDeleted = {
            // The erase holds writeLock here, not the store lock, so a close from another thread can run now.
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                storeRef.store?.close()
                finished.signal()
            }
            finished.wait()
        }
        let store = try SwiftDataFavoritesStore(url: url, fileOperations: operations)
        storeRef.store = store
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
        var operations = StoreFileOperations.systemOperations(opening: SwiftDataFavoritesStore.makeContainer)
        let opening = operations.openContainer
        operations.openContainer = { url in
            let container = try opening(url)
            probe.container = container
            return container
        }
        final class StoreBox { weak var store: SwiftDataFavoritesStore? }
        let storeRef = StoreBox()
        operations.afterRowsDeleted = {
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                storeRef.store?.close()
                finished.signal()
            }
            finished.wait()
        }
        let store = try SwiftDataFavoritesStore(url: url, fileOperations: operations)
        storeRef.store = store
        try autoreleasepool { try store.eraseAll() }
        XCTAssertNil(probe.container, "a closed store kept the container its erase opened, so the file stays open")
    }

    /// A store closed during an erase leaves no store file behind and reports no error (#1156): the erase removes the
    /// file, main, write-ahead and shared-memory, and reopens nothing.
    func testAClosedMidEraseLeavesNoStoreFiles() throws {
        let url = try makeDirectory().appendingPathComponent("favorites.store")
        var operations = StoreFileOperations.systemOperations(opening: SwiftDataFavoritesStore.makeContainer)
        final class StoreBox { weak var store: SwiftDataFavoritesStore? }
        let storeRef = StoreBox()
        operations.afterRowsDeleted = {
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                storeRef.store?.close()
                finished.signal()
            }
            finished.wait()
        }
        let store = try SwiftDataFavoritesStore(url: url, fileOperations: operations)
        storeRef.store = store
        try store.eraseAll()
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path + suffix),
                "a store closed mid-erase left \(suffix.isEmpty ? "the store file" : suffix)")
        }
    }

    /// A checkpoint that fails during a mid-erase close still removes every store file (#1156): the erase must not
    /// leave the deleted rows' bytes on disk, and the failure is reported.
    func testACheckpointFailureMidEraseStillRemovesTheFiles() throws {
        let url = try makeDirectory().appendingPathComponent("favorites.store")
        var operations = StoreFileOperations.systemOperations(opening: SwiftDataFavoritesStore.makeContainer)
        operations.checkpoint = { _ in throw CocoaError(.fileWriteUnknown) }
        final class StoreBox { weak var store: SwiftDataFavoritesStore? }
        let storeRef = StoreBox()
        operations.afterRowsDeleted = {
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                storeRef.store?.close()
                finished.signal()
            }
            finished.wait()
        }
        let store = try SwiftDataFavoritesStore(url: url, fileOperations: operations)
        storeRef.store = store
        XCTAssertThrowsError(try store.eraseAll())
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix), "a checkpoint failure left \(suffix)")
        }
    }
}
