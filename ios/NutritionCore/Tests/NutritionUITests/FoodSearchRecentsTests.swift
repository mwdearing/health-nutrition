import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Records every name search, so a test can show that typing sent none.
private final class RecordingNameSearch: ProductNameSearching, @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []

    var receivedQueries: [String] { lock.withLock { queries } }

    func search(query: String) async -> ProductNameSearchOutcome {
        lock.withLock { queries.append(query) }
        return .empty
    }
}

/// Find products lists the person's own recents and favorites, narrowed as they type, and keeps every
/// search that leaves the phone behind the Search button.
///
/// Synthetic names and ids only. Lowercase UUID intake ids.
@MainActor
final class FoodSearchRecentsTests: XCTestCase {
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

    private func makeLibrary(store: JournalStore) throws -> LibraryViewModel {
        let favorites = try SwiftDataFavoritesStore(url: try makeDirectory().appendingPathComponent("favorites.store"))
        return LibraryViewModel(store: store, favorites: favorites, timeZoneIdentifier: "UTC")
    }

    private func addEntry(
        _ store: JournalStore, name: String, at date: Date, product: ProductDefinition? = nil
    ) throws {
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: "food", occurredAt: date, timeZoneIdentifier: "UTC", meal: nil)
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        try store.create(
            intake, components: [IntakeComponent(componentID: slug, name: name, amount: 40, unit: .g)],
            product: product, now: date)
    }

    private func favorite(_ title: String, in library: LibraryViewModel) throws {
        let recent = try XCTUnwrap(
            library.sections.first { $0.title == "Recents" }?.items.first { $0.title == title })
        library.addFavorite(recent)
    }

    // MARK: Before anything is typed

    func testEmptyQueryListsNewestRecentsThenFavoritesNotAlreadyListed() throws {
        let store = try makeStore()
        for index in 1...7 {
            try addEntry(store, name: "Food \(index)", at: now.addingTimeInterval(TimeInterval(index * 100)))
        }
        let library = try makeLibrary(store: store)
        library.load()
        try favorite("Food 1", in: library)
        try favorite("Food 7", in: library)

        let groups = library.searchGroups(matching: "")
        XCTAssertEqual(groups.map(\.title), ["Recent", "Favorites"])
        XCTAssertEqual(groups[0].items.map(\.title), ["Food 7", "Food 6", "Food 5", "Food 4", "Food 3"])
        // Food 7 is already listed under Recent; Food 1 is a favorite past the Recent cap.
        XCTAssertEqual(groups[1].items.map(\.title), ["Food 1"])
    }

    func testEmptyLibraryShowsNoGroups() throws {
        let library = try makeLibrary(store: try makeStore())
        library.load()
        XCTAssertEqual(library.searchGroups(matching: ""), [])
        XCTAssertEqual(library.searchGroups(matching: "tea"), [])
    }

    // MARK: While typing

    func testTypingListsDistinctMatchesWithTitlesThatStartWithTheQueryFirst() throws {
        let store = try makeStore()
        try addEntry(store, name: "Green tea", at: now.addingTimeInterval(-300))
        try addEntry(store, name: "Oat porridge", at: now.addingTimeInterval(-200))
        try addEntry(store, name: "Tea biscuit", at: now.addingTimeInterval(-100))
        let library = try makeLibrary(store: store)
        library.load()
        try favorite("Green tea", in: library)

        let groups = library.searchGroups(matching: "  TEA ")
        XCTAssertEqual(groups.map(\.title), ["Your foods"])
        XCTAssertEqual(groups[0].items.map(\.title), ["Tea biscuit", "Green tea"])
        // The favorite and its recent are one item, shown once and with its star.
        XCTAssertEqual(groups[0].items.last?.isFavorite, true)
    }

    func testLoggedProductInRecentsAndProductsShowsOnce() throws {
        let store = try makeStore()
        let bar = ProductDefinition(
            snapshotID: "s-bar", productID: "p-bar", name: "Example bar", barcode: "0000000000017",
            labelBasis: "per_serving", catalogOrigin: "open-food-facts", catalogVersion: "1")
        try addEntry(store, name: "Example bar", at: now, product: bar)
        let library = try makeLibrary(store: store)
        library.load()
        XCTAssertEqual(library.sections.first { $0.title == "Products" }?.items.count, 1)

        XCTAssertEqual(library.searchGroups(matching: "bar").first?.items.map(\.title), ["Example bar"])
    }

    func testNoMatchKeepsAnEmptyGroupSoTheScreenCanSaySo() throws {
        let store = try makeStore()
        try addEntry(store, name: "Green tea", at: now)
        let library = try makeLibrary(store: store)
        library.load()

        XCTAssertEqual(library.searchGroups(matching: "coffee"), [LibrarySearchGroup(title: "Your foods", items: [])])
    }

    func testSearchGroupsLeaveTheLibrarysOwnSearchAndSegmentAlone() throws {
        let store = try makeStore()
        try addEntry(store, name: "Green tea", at: now)
        let library = try makeLibrary(store: store)
        library.load()
        library.segment = .products
        library.searchText = "oat"

        _ = library.searchGroups(matching: "tea")
        XCTAssertEqual(library.segment, .products)
        XCTAssertEqual(library.searchText, "oat")
    }

    // MARK: Nothing leaves the phone while typing

    func testTypingNarrowsLocalProductsAndSendsNothing() async throws {
        let store = ProductEditorStorePort(), service = ProductSearchServicePort()
        store.products = [syntheticCommunityRevision(name: "Synthetic tea", kind: .drink),
                          syntheticCommunityRevision(name: "Synthetic oats", kind: .food)]
        let names = RecordingNameSearch()
        let model = CommunityProductSearchViewModel(store: store, service: service, openFoodFacts: names, isSignedIn: { true })
        await model.search(query: "", kind: nil)
        await model.openFoodFactsSearchFinished()

        for text in ["o", "oa", "oat", "oats"] { model.filterLocal(query: text, kind: nil) }
        XCTAssertEqual(model.localResults.map(\.content.name), ["Synthetic oats"])
        model.filterLocal(query: "synthetic", kind: .drink)
        XCTAssertEqual(model.localResults.map(\.content.name), ["Synthetic tea"])

        XCTAssertEqual(names.receivedQueries, [])
        let calls = await service.calls
        XCTAssertEqual(calls, 0)
        let capabilityCalls = await service.capabilityCalls
        XCTAssertEqual(capabilityCalls, 0)
    }

    func testTypingKeepsTheLastSubmittedSharedResults() async throws {
        let store = ProductEditorStorePort(), service = ProductSearchServicePort()
        let shared = syntheticCommunityProduct(name: "Synthetic tonic", kind: .drink)
        await service.setPages([.init(products: [shared])])
        let model = CommunityProductSearchViewModel(store: store, service: service, isSignedIn: { true })
        await model.search(query: "Synthetic", kind: nil)

        model.filterLocal(query: "something else", kind: nil)
        XCTAssertEqual(model.sharedResults, [shared])
        XCTAssertEqual(model.state, .loaded)
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
    }
}
