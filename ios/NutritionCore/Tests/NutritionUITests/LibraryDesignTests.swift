import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The Library's segments, empty texts, quick add with undo, open-failure report and meal carry-over, at the view-model level.
///
/// Synthetic names only, lowercase UUID intake ids.
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
        XCTAssertEqual(LibrarySegment.allCases, [.favorites, .recent, .foods, .recipes])
        XCTAssertEqual(LibrarySegment.allCases.map(\.title), ["Favorites", "Recent", "Foods", "Recipes"])

        let store = try makeStore()
        let favorites = try makeFavorites()
        try favorites.add(favoriteTea())
        try addEntry(store, name: "Example oats", at: now.addingTimeInterval(-120))
        try addEntry(store, name: "Example rice", at: now.addingTimeInterval(-60))

        let library = makeLibrary(store: store, favorites: favorites)
        library.load()
        XCTAssertEqual(library.segment, .favorites)
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

        let favorites = library.emptyText(for: .favorites)
        XCTAssertEqual(favorites.title, "No favorites yet")
        XCTAssertEqual(favorites.message, "Star anything you log often.")
        XCTAssertEqual(favorites.systemImage, "star")

        let recent = library.emptyText(for: .recent)
        XCTAssertEqual(recent.title, "Nothing logged yet")
        XCTAssertEqual(recent.message, "Things you log will show up here.")
        XCTAssertEqual(recent.systemImage, "clock")

        let foods = library.emptyText(for: .foods)
        XCTAssertEqual(foods.title, "No foods yet")
        XCTAssertEqual(foods.message, "Foods you scan or look up are kept here so you can log them again.")
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

    func testLibraryQuickAddUndoIsClearedWhenTheScreenGoesAway() throws {
        let store = try makeStore()
        try addEntry(store, name: "Example oats", at: now.addingTimeInterval(-60))
        let library = makeLibrary(store: store, favorites: try makeFavorites())
        library.load()
        library.segment = .recent
        let recent = try XCTUnwrap(library.visibleItems.first)
        let before = try store.activeIntakes().count

        XCTAssertTrue(library.quickAdd(recent, now: now))
        let token = try XCTUnwrap(library.undoToken)

        library.clearUndo()
        XCTAssertNil(library.undoToken)
        // Clearing is not undoing: the entry the quick add wrote stays.
        XCTAssertEqual(try store.activeIntakes().count, before + 1)
        XCTAssertTrue(try store.activeIntakes().contains { $0.id == token.intakeID })
        // With the token gone, Undo has nothing to delete.
        XCTAssertFalse(library.undo(now: now))
        XCTAssertEqual(try store.activeIntakes().count, before + 1)
    }

    func testLibraryUndoClearsItsTokenEvenWhenTheEntryIsAlreadyGone() throws {
        let store = try makeStore()
        try addEntry(store, name: "Example oats", at: now.addingTimeInterval(-60))
        let library = makeLibrary(store: store, favorites: try makeFavorites())
        library.load()
        library.segment = .recent
        let recent = try XCTUnwrap(library.visibleItems.first)

        XCTAssertTrue(library.quickAdd(recent, now: now))
        let token = try XCTUnwrap(library.undoToken)
        // The entry is deleted outside the Library, so the store refuses a second delete (intakeDeleted).
        try store.delete(intakeID: token.intakeID, now: now)

        // The source clears the token before the store call and returns false when the delete throws.
        XCTAssertFalse(library.undo(now: now))
        XCTAssertNil(library.undoToken)
    }

    func testLibraryUndoKeepsItsOfferWhenTheDeleteFails() throws {
        let store = try makeStore()
        try addEntry(store, name: "Example oats", at: now.addingTimeInterval(-60))
        let library = makeLibrary(store: store, favorites: try makeFavorites())
        library.load()
        library.segment = .recent
        let recent = try XCTUnwrap(library.visibleItems.first)

        XCTAssertTrue(library.quickAdd(recent, now: now))
        let token = try XCTUnwrap(library.undoToken)

        // The store's delete honors the one-shot failure flag and throws JournalError.injectedSaveFailure.
        store.failNextSaveForTesting = true
        XCTAssertFalse(library.undo(now: now))
        XCTAssertNotNil(library.undoToken)
        XCTAssertEqual(library.undoToken?.intakeID, token.intakeID)
        XCTAssertEqual(library.errorMessage, "Could not undo. Try again.")
        XCTAssertTrue(try store.activeIntakes().contains { $0.id == token.intakeID })

        // The failure was one-shot, so the offer still works.
        XCTAssertTrue(library.undo(now: now))
        XCTAssertNil(library.undoToken)
        XCTAssertFalse(try store.activeIntakes().contains { $0.id == token.intakeID })
    }

    func testLibraryQuickAddClearsAStaleUndoWhenTheNextAddFails() throws {
        let store = try makeStore()
        try addEntry(store, name: "Example oats", at: now.addingTimeInterval(-60))
        let favorites = try makeFavorites()
        try favorites.add(FavoriteTemplate(
            id: "22222222-2222-4222-8222-222222222222", displayName: "Example empty", category: "food",
            components: []))
        let library = makeLibrary(store: store, favorites: favorites)
        library.load()
        library.segment = .recent
        let recent = try XCTUnwrap(library.visibleItems.first)
        library.segment = .favorites
        let empty = try XCTUnwrap(library.visibleItems.first)

        XCTAssertTrue(library.quickAdd(recent, now: now))
        let firstID = try XCTUnwrap(library.undoToken?.intakeID)
        let countAfterFirst = try store.activeIntakes().count

        // The failing add must not leave the earlier Undo offer behind: Undo would delete the earlier entry.
        XCTAssertFalse(library.quickAdd(empty, now: now))
        XCTAssertNil(library.undoToken)
        XCTAssertEqual(try store.activeIntakes().count, countAfterFirst)
        XCTAssertTrue(try store.activeIntakes().contains { $0.id == firstID })
    }

    func testLibraryReportsAnItemThatCannotBeOpened() throws {
        let library = makeLibrary(store: try makeStore(), favorites: try makeFavorites())
        library.load()
        XCTAssertNil(library.errorMessage)

        library.reportOpenFailure()
        XCTAssertEqual(
            library.errorMessage, "This item can't be opened. Its saved product is no longer available.")

        library.load()
        XCTAssertNil(library.errorMessage)
    }

    func testAddHomeCarriesAMealIntoPrefilledDetails() throws {
        let store = try makeStore()
        XCTAssertNil(LibraryViewModel.mealLabel(for: RepeatTemplate(
            displayName: "Example oats", category: "food",
            components: [IntakeComponent(componentID: "example-oats", name: "Example oats", amount: 40, unit: .g)])))
        XCTAssertNil(LibraryViewModel.mealLabel(for: RepeatTemplate(
            displayName: "Example oats", category: "food", meal: "midnight feast",
            components: [IntakeComponent(componentID: "example-oats", name: "Example oats", amount: 40, unit: .g)])))

        let template = RepeatTemplate(
            displayName: "Example oats", category: "food", meal: "breakfast",
            components: [IntakeComponent(componentID: "example-oats", name: "Example oats", amount: 40, unit: .g)])
        let label = try XCTUnwrap(LibraryViewModel.mealLabel(for: template))
        XCTAssertEqual(label, .breakfast)

        let home = AddHomeViewModel(store: store, meal: label, now: { self.now })
        let details = try home.makeDetails(prefill: template, now: now)
        XCTAssertEqual(details.meal, .breakfast)
    }

    func testAddHomeMealLabelNormalizesAStoredMeal() {
        func template(meal: String?) -> RepeatTemplate {
            RepeatTemplate(
                displayName: "Example oats", category: "food", meal: meal,
                components: [IntakeComponent(componentID: "example-oats", name: "Example oats", amount: 40, unit: .g)])
        }
        XCTAssertEqual(LibraryViewModel.mealLabel(for: template(meal: "Breakfast")), .breakfast)
        XCTAssertEqual(LibraryViewModel.mealLabel(for: template(meal: " breakfast ")), .breakfast)
        XCTAssertEqual(LibraryViewModel.mealLabel(for: template(meal: "DINNER")), .dinner)
        XCTAssertNil(LibraryViewModel.mealLabel(for: template(meal: "midnight feast")))
        XCTAssertNil(LibraryViewModel.mealLabel(for: template(meal: "")))
        XCTAssertNil(LibraryViewModel.mealLabel(for: template(meal: nil)))
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
