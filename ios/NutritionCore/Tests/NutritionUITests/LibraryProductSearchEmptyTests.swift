import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The Products segment lists standalone products as well as journal rows, so a search that matches only a
/// product is not a search empty state (#546).
@MainActor
final class LibraryProductSearchEmptyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    func testProductsSearchWithAStandaloneMatchIsNotASearchEmptyState() throws {
        let store = try makeStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let favorites = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        let product = CustomProductRevision(
            localProductID: UUID(), revisionID: UUID(),
            content: .init(name: "Synthetic tea", kind: .drink, basis: .perServing))
        try store.saveCustomProduct(.init(revision: product), now: now)

        let model = LibraryViewModel(store: store, favorites: favorites, productStore: store, timeZoneIdentifier: "UTC")
        model.load()
        model.segment = .products
        model.searchText = "tea"
        XCTAssertEqual(model.filteredProducts, [product])
        XCTAssertFalse(model.isSearchEmpty)
    }

    func testProductsSearchWithNoMatchAnywhereIsASearchEmptyState() throws {
        let store = try makeStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let favorites = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))

        let model = LibraryViewModel(store: store, favorites: favorites, productStore: store, timeZoneIdentifier: "UTC")
        model.load()
        model.segment = .products
        model.searchText = "zzz"
        XCTAssertTrue(model.isSearchEmpty)
    }
}
