import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Design WP8: the Library segments, the empty states, quick add with undo, and pick mode at the view-model level.
///
/// Written against the pinned API in `2026-10-08-design-wp8-team-plan.md`. Synthetic names only, lowercase UUID intake ids.
@MainActor
final class LibraryDesignTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// A fixed lowercase UUID: each test quick-adds at most once, so one id is enough.
    private let fixedID = "00000000-0000-4000-8000-000000000001"

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
        let id = fixedID
        return LibraryViewModel(
            store: store, favorites: favorites, timeZoneIdentifier: "UTC", makeID: { id })
    }

    private func product(_ snapshot: String) -> ProductDefinition {
        ProductDefinition(
            snapshotID: snapshot, productID: "p-\(snapshot)", name: "Example bar", labelBasis: "per_serving",
            catalogOrigin: "test", catalogVersion: "1")
    }

    /// Writes one active entry with the given name and returns its lowercase UUID id.
    @discardableResult
    private func addEntry(
        _ store: JournalStore, name: String, at date: Date, meal: String? = nil,
        product: ProductDefinition? = nil
    ) throws -> String {
        let id = UUID().uuidString.lowercased()
        let intake = Intake(id: id, category: "food", occurredAt: date, timeZoneIdentifier: "UTC", meal: meal)
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        try store.create(
            intake, components: [IntakeComponent(componentID: slug, name: name, amount: 40, unit: .g)],
            product: product, now: date)
        return id
    }

    private func favoriteTea() -> FavoriteTemplate {
        FavoriteTemplate(
            id: "11111111-1111-4111-8111-111111111111", displayName: "Example tea", category: "drink",
            components: [FavoriteComponent(componentID: "tea", name: "Example tea", amountText: "250", unitSymbol: "mL")])
    }

    // MARK: Segments

    func testLibrarySegmentsFollowTheSegmentedControl() throws {
        XCTAssertEqual(LibrarySegment.allCases, [.favourites, .recent, .foods, .recipes])
        XCTAssertEqual(LibrarySegment.allCases.map(\.title), ["Favourites", "Recent", "Foods", "Recipes"])

        let store = try makeStore()
        let favorites = try makeFavorites()
        try favorites.add(favoriteTea())
        try addEntry(store, name: "Example oats", at: now.addingTimeInterval(-120))
        try addEntry(store, name: "Example rice", at: now.addingTimeInterval(-60))

        let library = makeLibrary(store: store, favorites: favorites)
        library.load()
        XCTAssertEqual(library.segment, .favourites)
        XCTAssertEqual(library.visibleItems.count, 1)
        XCTAssertEqual(library.visibleItems.first?.title, "Example tea")

        library.segment = .recent
        XCTAssertEqual(library.visibleItems.count, 2)
        XCTAssertEqual(Set(library.visibleItems.map(\.title)), ["Example oats", "Example rice"])

        library.segment = .foods
        XCTAssertEqual(library.visibleItems.count, 0)

        library.segment = .recipes
        XCTAssertEqual(library.visibleItems.count, 0)
    }

    // MARK: Empty states

    func testLibraryEmptyStatesCoverEverySegment() throws {
        let library = makeLibrary(store: try makeStore(), favorites: try makeFavorites())

        let favourites = library.emptyText(for: .favourites)
        XCTAssertEqual(favourites.title, "No favourites yet")
        XCTAssertEqual(favourites.message, "Star anything you log often.")
        XCTAssertEqual(favourites.systemImage, "star")

        let recent = library.emptyText(for: .recent)
        XCTAssertEqual(recent.title, "Nothing logged yet")
        XCTAssertEqual(recent.message, "Things you log will show up here.")
        XCTAssertEqual(recent.systemImage, "clock")

        let foods = library.emptyText(for: .foods)
        XCTAssertEqual(foods.title, "Foods")
        XCTAssertEqual(foods.message, "Foods you've scanned will be kept here so you can log them again.")
        XCTAssertEqual(foods.systemImage, "barcode.viewfinder")

        let recipes = library.emptyText(for: .recipes)
        XCTAssertEqual(recipes.title, "No recipes yet")
        XCTAssertEqual(recipes.message, "Recipes you write are kept here.")
        XCTAssertEqual(recipes.systemImage, "book")
    }

    // MARK: Quick add with undo

    func testLibraryQuickAddCanBeUndone() throws {
        let store = try makeStore()
        try addEntry(store, name: "Example oats", at: now.addingTimeInterval(-60))
        let library = makeLibrary(store: store, favorites: try makeFavorites())
        library.load()
        library.segment = .recent
        let recent = try XCTUnwrap(library.visibleItems.first)
        let before = try store.activeIntakes().count

        XCTAssertTrue(library.quickAdd(recent, now: now))
        XCTAssertEqual(try store.activeIntakes().count, before + 1)
        let token = try XCTUnwrap(library.undoToken)
        XCTAssertEqual(token.message, "Added Example oats")
        XCTAssertEqual(token.intakeID, fixedID)
        XCTAssertTrue(try store.activeIntakes().contains { $0.id == token.intakeID })

        XCTAssertTrue(library.undo(now: now))
        XCTAssertFalse(try store.activeIntakes().contains { $0.id == token.intakeID })
        XCTAssertEqual(try store.activeIntakes().count, before)
        XCTAssertNil(library.undoToken)

        XCTAssertFalse(library.undo(now: now))
    }

    func testLibraryQuickAddWithoutComponentsSetsNoToken() throws {
        let store = try makeStore()
        let favorites = try makeFavorites()
        try favorites.add(FavoriteTemplate(
            id: "22222222-2222-4222-8222-222222222222", displayName: "Example empty", category: "food",
            components: []))
        let library = makeLibrary(store: store, favorites: favorites)
        library.load()
        let empty = try XCTUnwrap(library.visibleItems.first)
        let before = try store.activeIntakes().count

        XCTAssertFalse(library.quickAdd(empty, now: now))
        XCTAssertNil(library.undoToken)
        XCTAssertEqual(try store.activeIntakes().count, before)
    }

    // MARK: Pick mode

    func testLibraryPickModeReturnsATemplate() throws {
        let store = try makeStore()
        try addEntry(
            store, name: "Example oats", at: now.addingTimeInterval(-60), meal: "breakfast",
            product: product("example-snap-1"))
        let library = makeLibrary(store: store, favorites: try makeFavorites())
        library.load()
        library.segment = .recent
        let item = try XCTUnwrap(library.visibleItems.first)
        let before = try store.activeIntakes().count

        // The pick hands over the item's template unchanged; the view calls onPick(item.template).
        let picked = item.template
        XCTAssertEqual(picked.displayName, "Example oats")
        XCTAssertEqual(picked.category, "food")
        XCTAssertEqual(picked.meal, "breakfast")
        XCTAssertEqual(picked.productSnapshotID, "example-snap-1")
        XCTAssertEqual(picked.components.count, 1)
        XCTAssertEqual(picked.components.first?.componentID, "example-oats")
        XCTAssertEqual(picked.components.first?.name, "Example oats")
        XCTAssertEqual(picked.components.first?.amount, 40)
        XCTAssertEqual(picked.components.first?.unit, .g)

        // Picking writes nothing: no entry is added and no undo is offered.
        XCTAssertEqual(try store.activeIntakes().count, before)
        XCTAssertNil(library.undoToken)
        XCTAssertEqual(library.sections.last?.items.first?.template.meal, "breakfast")
    }
}
