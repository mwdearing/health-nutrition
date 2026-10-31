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

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeStore() throws -> SwiftDataJournalStore {
        try SwiftDataJournalStore(url: try makeDirectory().appendingPathComponent("journal.store"))
    }

    func testProductsSearchWithAStandaloneMatchIsNotASearchEmptyState() throws {
        let store = try makeStore()
        let favorites = try SwiftDataFavoritesStore(url: try makeDirectory().appendingPathComponent("favorites.store"))
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

    /// A Products search matched by a journal row, with no standalone product matching, is not empty (#546).
    func testProductsSearchMatchedOnlyByAJournalRowIsNotASearchEmptyState() throws {
        let store = try makeStore()
        let favorites = try SwiftDataFavoritesStore(url: try makeDirectory().appendingPathComponent("favorites.store"))
        let bar = ProductDefinition(
            snapshotID: "s-bar", productID: "p-s-bar", name: "Example bar", barcode: "0000000000017",
            labelBasis: "per_serving", catalogOrigin: "open-food-facts", catalogVersion: "1")
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: "food", occurredAt: now.addingTimeInterval(-300),
            timeZoneIdentifier: "UTC", meal: nil)
        try store.create(
            intake, components: [IntakeComponent(componentID: "example-bar", name: "Example bar", amount: 40, unit: .g)],
            product: bar, now: now)

        let model = LibraryViewModel(store: store, favorites: favorites, productStore: store, timeZoneIdentifier: "UTC")
        model.load()
        model.segment = .products
        model.searchText = "bar"
        XCTAssertTrue(model.filteredProducts.isEmpty)
        XCTAssertEqual(model.visibleItems.map(\.title), ["Example bar"])
        XCTAssertFalse(model.isSearchEmpty)
    }

    func testProductsSearchWithNoMatchAnywhereIsASearchEmptyState() throws {
        let store = try makeStore()
        let favorites = try SwiftDataFavoritesStore(url: try makeDirectory().appendingPathComponent("favorites.store"))

        let model = LibraryViewModel(store: store, favorites: favorites, productStore: store, timeZoneIdentifier: "UTC")
        model.load()
        model.segment = .products
        model.searchText = "zzz"
        XCTAssertTrue(model.isSearchEmpty)
    }
}
