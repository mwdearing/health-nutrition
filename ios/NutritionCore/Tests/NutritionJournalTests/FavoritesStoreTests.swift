import Foundation
import XCTest
@testable import NutritionJournal

final class FavoritesStoreTests: XCTestCase {
    private func makeURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("favorites.store")
    }

    private func sample(_ id: String) -> FavoriteTemplate {
        FavoriteTemplate(
            id: id, displayName: "Oat porridge", category: "food",
            components: [FavoriteComponent(componentID: "oats", name: "Oats", amountText: "0.5", unitSymbol: "g")],
            productSnapshotID: "snap-1")
    }

    func testFavoritesPersistAcrossReopenKeepingExactDecimalText() throws {
        let url = try makeURL()
        let first = try SwiftDataFavoritesStore(url: url)
        try first.add(sample("fav-1"))
        XCTAssertTrue(try first.contains(id: "fav-1"))
        first.close()
        let second = try SwiftDataFavoritesStore(url: url)
        let listed = try second.list()
        XCTAssertEqual(listed, [sample("fav-1")])
        XCTAssertEqual(listed.first?.components.first?.amountText, "0.5")
        second.close()
    }

    func testFavoritesRemoveAndContains() throws {
        let store = try SwiftDataFavoritesStore(url: try makeURL())
        try store.add(sample("fav-1"))
        try store.add(sample("fav-2"))
        try store.remove(id: "fav-1")
        XCTAssertFalse(try store.contains(id: "fav-1"))
        XCTAssertEqual(try store.list().map(\.id), ["fav-2"])
    }

    func testFavoritesAddWithSameIdReplaces() throws {
        let store = try SwiftDataFavoritesStore(url: try makeURL())
        try store.add(sample("fav-1"))
        var changed = sample("fav-1")
        changed.displayName = "Renamed"
        try store.add(changed)
        XCTAssertEqual(try store.list().map(\.displayName), ["Renamed"])
    }
}
