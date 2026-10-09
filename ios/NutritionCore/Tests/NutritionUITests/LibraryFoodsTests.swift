import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The Library's Foods segment: distinct products logged from a lookup, a label scan or another source
/// that stored a snapshot, at the view-model level.
///
/// Synthetic names and ids only. Lowercase UUID intake ids.
@MainActor
final class LibraryFoodsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let barcodeOrigin = "open-food-facts"

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = try makeDirectory()
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func makeFavorites() throws -> SwiftDataFavoritesStore {
        try SwiftDataFavoritesStore(url: try makeDirectory().appendingPathComponent("favorites.store"))
    }

    private func makeLibrary(store: JournalStore, favorites: FavoritesStore) -> LibraryViewModel {
        LibraryViewModel(store: store, favorites: favorites, timeZoneIdentifier: "UTC")
    }

    /// A product with its own snapshot; the lineage id is the snapshot unless a test names one.
    private func product(
        _ snapshot: String, name: String = "Example bar", origin: String, lineage: String? = nil
    ) -> ProductDefinition {
        ProductDefinition(
            snapshotID: snapshot, productID: lineage ?? "p-\(snapshot)", name: name, barcode: "0000000000017",
            labelBasis: "per_serving", catalogOrigin: origin, catalogVersion: "1")
    }

    /// Writes one entry named `name` and returns its lowercase UUID id.
    @discardableResult
    private func addEntry(
        _ store: JournalStore, name: String, at date: Date, category: String = "food", meal: String? = nil,
        product: ProductDefinition? = nil
    ) throws -> String {
        let id = UUID().uuidString.lowercased()
        let intake = Intake(id: id, category: category, occurredAt: date, timeZoneIdentifier: "UTC", meal: meal)
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        try store.create(
            intake, components: [IntakeComponent(componentID: slug, name: name, amount: 40, unit: .g)],
            product: product, now: date)
        return id
    }

    private func foodTitles(_ library: LibraryViewModel) -> [String] {
        library.sections.first { $0.title == "Foods" }?.items.map(\.title) ?? []
    }

    // MARK: Which entries are foods

    func testBarcodeProductAppearsOnceHoweverOftenItWasLogged() throws {
        let store = try makeStore()
        let bar = product("s-bar", name: "Example bar", origin: barcodeOrigin)
        try addEntry(store, name: "Example bar", at: now.addingTimeInterval(-300), product: bar)
        try addEntry(store, name: "Example bar", at: now.addingTimeInterval(-200), product: bar)
        try addEntry(store, name: "Example bar", at: now.addingTimeInterval(-100), product: bar)

        let library = makeLibrary(store: store, favorites: try makeFavorites())
        library.load()
        library.segment = .foods
        XCTAssertEqual(library.visibleItems.map(\.title), ["Example bar"])
    }

    func testTypedEntryRecipeAndWaterDoNotAppearInFoods() throws {
        let store = try makeStore()
        try addEntry(store, name: "Typed oats", at: now.addingTimeInterval(-500))
        try addEntry(
            store, name: "Typed bar", at: now.addingTimeInterval(-400),
            product: product("s-manual", name: "Typed bar", origin: "manual"))
        try addEntry(
            store, name: "Oat bake", at: now.addingTimeInterval(-300),
            product: product("s-recipe", name: "Oat bake", origin: RecipeLogger.catalogOrigin))
        try addEntry(
            store, name: "Sparkling water", at: now.addingTimeInterval(-200), category: "water",
            product: product("s-water", name: "Sparkling water", origin: barcodeOrigin))
        try addEntry(
            store, name: "Label bar", at: now.addingTimeInterval(-100),
            product: product("s-label", name: "Label bar", origin: ProductOrigin.label_capture))

        let library = makeLibrary(store: store, favorites: try makeFavorites())
        library.load()
        XCTAssertEqual(foodTitles(library), ["Label bar"])
    }

    func testFoodsAreSortedByNameIgnoringCase() throws {
        let store = try makeStore()
        try addEntry(
            store, name: "oat drink", at: now.addingTimeInterval(-300),
            product: product("s-oat", name: "oat drink", origin: barcodeOrigin))
        try addEntry(
            store, name: "Apple", at: now.addingTimeInterval(-200),
            product: product("s-apple", name: "Apple", origin: barcodeOrigin))
        try addEntry(
            store, name: "beans", at: now.addingTimeInterval(-100),
            product: product("s-beans", name: "beans", origin: barcodeOrigin))

        let library = makeLibrary(store: store, favorites: try makeFavorites())
        library.load()
        XCTAssertEqual(foodTitles(library), ["Apple", "beans", "oat drink"])
    }

    func testFoodsIgnoreTheRecentsCapOfTwentyRows() throws {
        let store = try makeStore()
        for index in 0..<25 {
            try addEntry(
                store, name: "Bar \(index)", at: now.addingTimeInterval(TimeInterval(index)),
                product: product("s-\(index)", name: "Bar \(index)", origin: barcodeOrigin))
        }

        let library = makeLibrary(store: store, favorites: try makeFavorites())
        library.load()
        XCTAssertEqual(foodTitles(library).count, 25)
    }

    func testDeletedEntryProductLeavesFoodsUnlessAnotherActiveEntryUsesIt() throws {
        let store = try makeStore()
        let gone = product("s-gone", name: "Gone bar", origin: barcodeOrigin)
        let kept = product("s-kept", name: "Kept bar", origin: barcodeOrigin)
        let goneID = try addEntry(store, name: "Gone bar", at: now.addingTimeInterval(-200), product: gone)
        try addEntry(store, name: "Kept bar", at: now.addingTimeInterval(-300), product: kept)
        let keptNewestID = try addEntry(store, name: "Kept bar", at: now.addingTimeInterval(-100), product: kept)
        try store.delete(intakeID: goneID, now: now)
        try store.delete(intakeID: keptNewestID, now: now)

        let library = makeLibrary(store: store, favorites: try makeFavorites())
        library.load()
        XCTAssertEqual(foodTitles(library), ["Kept bar"])
    }

    func testFoodRowUsesTheSnapshotOfTheNewestEntryOfItsProduct() throws {
        let store = try makeStore()
        try addEntry(
            store, name: "Old name", at: now.addingTimeInterval(-300),
            product: product("s-old", name: "Old name", origin: barcodeOrigin, lineage: "p-bar"))
        try addEntry(
            store, name: "New name", at: now.addingTimeInterval(-100),
            product: product("s-new", name: "New name", origin: barcodeOrigin, lineage: "p-bar"))

        let library = makeLibrary(store: store, favorites: try makeFavorites())
        library.load()
        let items = try XCTUnwrap(library.sections.first { $0.title == "Foods" }?.items)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.template.productSnapshotID, "s-new")
    }

    // MARK: Rows and actions

    func testSelectingAFoodRowLogsOneNewEntryWithTheSameSnapshot() throws {
        let store = try makeStore()
        try addEntry(
            store, name: "Example bar", at: now.addingTimeInterval(-300),
            product: product("s-bar", name: "Example bar", origin: barcodeOrigin))

        let library = makeLibrary(store: store, favorites: try makeFavorites())
        library.load()
        library.segment = .foods
        let row = try XCTUnwrap(library.visibleItems.first)
        let before = try store.activeIntakes().count

        let newID = try XCTUnwrap(library.select(row, now: now))
        XCTAssertEqual(try store.activeIntakes().count, before + 1)
        let created = try XCTUnwrap(try store.activeIntakes().first { $0.id == newID })
        XCTAssertEqual(try store.revisions(of: created.id).first?.productSnapshotID, "s-bar")
    }

    func testFavoriteStarOnAFoodRowFollowsFavorites() throws {
        let store = try makeStore()
        try addEntry(
            store, name: "Example bar", at: now.addingTimeInterval(-300),
            product: product("s-bar", name: "Example bar", origin: barcodeOrigin))
        let library = makeLibrary(store: store, favorites: try makeFavorites())
        library.load()
        library.segment = .foods
        let row = try XCTUnwrap(library.visibleItems.first)
        XCTAssertFalse(row.isFavorite)

        library.addFavorite(row)
        library.segment = .foods
        XCTAssertTrue(try XCTUnwrap(library.visibleItems.first).isFavorite)

        library.removeFavorite(try XCTUnwrap(library.visibleItems.first))
        library.segment = .foods
        XCTAssertFalse(try XCTUnwrap(library.visibleItems.first).isFavorite)
    }

    // MARK: Empty state and the other segments

    func testFoodsEmptyStateWordingAndNoRows() throws {
        let library = makeLibrary(store: try makeStore(), favorites: try makeFavorites())
        library.load()
        library.segment = .foods
        XCTAssertTrue(library.visibleItems.isEmpty)

        let foods = library.emptyText(for: .foods)
        XCTAssertEqual(foods.title, "No foods yet")
        XCTAssertEqual(foods.message, "Foods you scan or look up are kept here so you can log them again.")
        XCTAssertEqual(foods.systemImage, "barcode.viewfinder")
    }

    func testRecentsAndFavoritesAreUnchangedByFoods() throws {
        let store = try makeStore()
        try addEntry(
            store, name: "Typed oats", at: now.addingTimeInterval(-200))
        try addEntry(
            store, name: "Example bar", at: now.addingTimeInterval(-100),
            product: product("s-bar", name: "Example bar", origin: barcodeOrigin))
        let favorites = try makeFavorites()
        try favorites.add(FavoriteTemplate(
            id: "11111111-1111-4111-8111-111111111111", displayName: "Example tea", category: "drink",
            components: [FavoriteComponent(componentID: "tea", name: "Example tea", amountText: "250", unitSymbol: "mL")]))

        let library = makeLibrary(store: store, favorites: favorites)
        library.load()
        XCTAssertEqual(library.sections.map(\.title), ["Favorites", "Foods", "Recents"])
        library.segment = .favorites
        XCTAssertEqual(library.visibleItems.map(\.title), ["Example tea"])
        library.segment = .recent
        XCTAssertEqual(Set(library.visibleItems.map(\.title)), ["Typed oats", "Example bar"])
    }

    /// Every label capture carries the same lineage id, so two different captured labels must still be two rows.
    func testDistinctLabelCapturesAreSeparateRows() throws {
        let store = try makeStore()
        let first = product("s-label-a", name: "Example granola", origin: ProductOrigin.label_capture, lineage: "label_capture")
        let second = product("s-label-b", name: "Example crackers", origin: ProductOrigin.label_capture, lineage: "label_capture")
        try addEntry(store, name: "Example granola", at: now.addingTimeInterval(-300), product: first)
        try addEntry(store, name: "Example crackers", at: now.addingTimeInterval(-200), product: second)
        try addEntry(store, name: "Example granola", at: now.addingTimeInterval(-100), product: first)

        let library = makeLibrary(store: store, favorites: try makeFavorites())
        library.load()

        XCTAssertEqual(foodTitles(library), ["Example crackers", "Example granola"])
    }
}
