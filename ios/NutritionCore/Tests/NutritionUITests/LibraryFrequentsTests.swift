import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// "Often logged": items logged at least twice among the newest entries, and their group on Search foods.
///
/// Synthetic names and ids only. Lowercase UUID intake ids.
@MainActor
final class LibraryFrequentsTests: XCTestCase {
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

    /// Writes one entry `seconds` after `now`, so a larger number is a newer entry.
    private func addEntry(
        _ store: JournalStore, _ name: String, at seconds: Int, category: String = "food", meal: String? = nil,
        product: ProductDefinition? = nil
    ) throws {
        let date = now.addingTimeInterval(TimeInterval(seconds))
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: category, occurredAt: date, timeZoneIdentifier: "UTC", meal: meal)
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        try store.create(
            intake, components: [IntakeComponent(componentID: slug, name: name, amount: 40, unit: .g)],
            product: product, now: date)
    }

    private func frequentTitles(_ store: JournalStore, window: Int = FrequentItemsProvider.window) throws -> [String] {
        try FrequentItemsProvider(store: store).frequents(window: window).map(\.template.displayName)
    }

    // MARK: What counts as often logged

    func testItemsLoggedTwiceOrMoreAreFrequentMostLoggedFirst() throws {
        let store = try makeStore()
        for seconds in [1, 2, 3] { try addEntry(store, "Oat porridge", at: seconds) }
        for seconds in [4, 5] { try addEntry(store, "Green tea", at: seconds) }
        try addEntry(store, "Tea biscuit", at: 6)

        XCTAssertEqual(try frequentTitles(store), ["Oat porridge", "Green tea"])
        XCTAssertEqual(try FrequentItemsProvider(store: store).frequents().map(\.count), [3, 2])
    }

    /// A recipe version logged again with the same values keeps one snapshot, so it is one Recents row,
    /// a favorite made from the first entry stars it, and it counts toward Often logged.
    func testARecipeVersionLoggedAgainIsOneRecentOneFavoriteAndOftenLogged() throws {
        let store = try makeStore()
        let recipe = uiSampleVersion()
        try RecipeLogger.logPortion(
            store: store, version: recipe, portion: 1, now: now, id: UUID().uuidString.lowercased(),
            timeZoneIdentifier: "UTC")
        let library = try makeLibrary(store: store)
        library.load()
        let first = try XCTUnwrap(library.sections.first { $0.title == "Recents" }?.items.first)
        library.addFavorite(first)

        try RecipeLogger.logPortion(
            store: store, version: recipe, portion: 1, now: now.addingTimeInterval(60),
            id: UUID().uuidString.lowercased(), timeZoneIdentifier: "UTC")
        library.load()

        let recents = library.sections.first { $0.title == "Recents" }?.items ?? []
        XCTAssertEqual(recents.filter { $0.title == recipe.title }.count, 1)
        XCTAssertEqual(recents.first { $0.title == recipe.title }?.isFavorite, true)
        XCTAssertEqual(library.frequentItems.map(\.title), [recipe.title])
    }

    func testTieGoesToTheItemUsedLast() throws {
        let store = try makeStore()
        for seconds in [1, 2] { try addEntry(store, "Oat porridge", at: seconds) }
        for seconds in [3, 4] { try addEntry(store, "Green tea", at: seconds) }

        XCTAssertEqual(try frequentTitles(store), ["Green tea", "Oat porridge"])
    }

    func testWaterIsNeverOftenLogged() throws {
        let store = try makeStore()
        for seconds in [1, 2, 3] { try addEntry(store, "Water", at: seconds, category: DailyTotalsBuilder.waterCategory) }

        XCTAssertEqual(try frequentTitles(store), [])
    }

    func testTheSameFoodAtTwoMealsIsCountedApart() throws {
        let store = try makeStore()
        try addEntry(store, "Oat porridge", at: 1, meal: "breakfast")
        try addEntry(store, "Oat porridge", at: 2, meal: "dinner")

        XCTAssertEqual(try frequentTitles(store), [])
    }

    func testOnlyTheNewestEntriesInTheWindowAreCounted() throws {
        let store = try makeStore()
        for seconds in [1, 2] { try addEntry(store, "Oat porridge", at: seconds) }
        for seconds in [3, 4, 5] { try addEntry(store, "Food \(seconds)", at: seconds) }

        XCTAssertEqual(try frequentTitles(store, window: 3), [])
        XCTAssertEqual(try frequentTitles(store, window: 5), ["Oat porridge"])
    }

    // MARK: On Search foods

    func testOftenLoggedFollowsRecentWithoutRepeatingIt() throws {
        let store = try makeStore()
        for seconds in [1, 2, 3] { try addEntry(store, "Oat porridge", at: seconds) }
        for seconds in 10...15 { try addEntry(store, "Food \(seconds)", at: seconds) }
        // Logged often and also among the five newest, so it shows under Recent only.
        for seconds in [20, 21] { try addEntry(store, "Green tea", at: seconds) }
        let library = try makeLibrary(store: store)
        library.load()

        let groups = library.searchGroups(matching: "")
        XCTAssertEqual(groups.map(\.title), ["Recent", "Often logged"])
        XCTAssertEqual(groups[0].items.map(\.title), ["Green tea", "Food 15", "Food 14", "Food 13", "Food 12"])
        XCTAssertEqual(groups[1].items.map(\.title), ["Oat porridge"])
    }

    func testWhileTypingOftenLoggedItemsComeBeforePlainRecents() throws {
        let store = try makeStore()
        for seconds in [1, 2] { try addEntry(store, "Tea biscuit", at: seconds) }
        try addEntry(store, "Tea cake", at: 3)
        let library = try makeLibrary(store: store)
        library.load()

        XCTAssertEqual(library.searchGroups(matching: "tea").first?.items.map(\.title), ["Tea biscuit", "Tea cake"])
    }

    func testAnyOftenLoggedItemIsFoundByNameNotOnlyTheFirstTen() throws {
        let store = try makeStore()
        // Twelve items logged twice each; Item 1 is the oldest, so it ranks last.
        for index in 1...12 {
            try addEntry(store, "Item \(index)", at: index * 2)
            try addEntry(store, "Item \(index)", at: index * 2 + 1)
        }
        // Twenty newer entries push every item out of Recents.
        for index in 1...RecentItemsProvider.defaultLimit { try addEntry(store, "Newer \(index)", at: 100 + index) }
        let library = try makeLibrary(store: store)
        library.load()

        XCTAssertEqual(library.frequentItems.count, 12)
        let titles = library.searchGroups(matching: "Item 1").first?.items.map(\.title) ?? []
        XCTAssertTrue(titles.contains("Item 1"), "\(titles)")
    }

    func testKindNarrowsOftenLogged() throws {
        let store = try makeStore()
        let capsule = ProductDefinition(
            snapshotID: "s-capsule", productID: "p-capsule", name: "Example capsule", labelBasis: "per_serving",
            catalogOrigin: "custom", catalogVersion: "1", kind: .supplement)
        for seconds in [1, 2] { try addEntry(store, "Example capsule", at: seconds, product: capsule) }
        for seconds in [3, 4] { try addEntry(store, "Oat porridge", at: seconds) }
        for index in 1...RecentItemsProvider.defaultLimit { try addEntry(store, "Newer \(index)", at: 100 + index) }
        let library = try makeLibrary(store: store)
        library.load()

        XCTAssertEqual(
            library.searchGroups(matching: "", kind: .supplement),
            [LibrarySearchGroup(title: "Often logged", items: library.frequentItems.filter { $0.title == "Example capsule" })])
    }

    func testAFavoriteLoggedOftenShowsUnderOftenLoggedWithItsStar() throws {
        let store = try makeStore()
        for seconds in [1, 2] { try addEntry(store, "Oat porridge", at: seconds) }
        for seconds in 10...15 { try addEntry(store, "Food \(seconds)", at: seconds) }
        let library = try makeLibrary(store: store)
        library.load()
        let porridge = try XCTUnwrap(
            library.sections.first { $0.title == "Recents" }?.items.first { $0.title == "Oat porridge" })
        library.addFavorite(porridge)

        let groups = library.searchGroups(matching: "")
        XCTAssertEqual(groups.map(\.title), ["Recent", "Often logged"])
        XCTAssertEqual(groups[1].items.map(\.title), ["Oat porridge"])
        XCTAssertEqual(groups[1].items.first?.isFavorite, true)
    }

    func testLibraryScreenSectionsAreUnchanged() throws {
        let store = try makeStore()
        for seconds in [1, 2] { try addEntry(store, "Oat porridge", at: seconds) }
        let library = try makeLibrary(store: store)
        library.load()

        XCTAssertEqual(library.sections.map(\.title), ["Favorites", "Products", "Recents"])
        XCTAssertEqual(library.frequentItems.map(\.title), ["Oat porridge"])
    }
}
