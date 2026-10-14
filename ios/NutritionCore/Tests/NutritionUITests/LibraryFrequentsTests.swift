import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// "Often logged": items logged at least twice among the newest entries, and their group on Find products.
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
        _ store: JournalStore, _ name: String, at seconds: Int, category: String = "food", meal: String? = nil
    ) throws {
        let date = now.addingTimeInterval(TimeInterval(seconds))
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: category, occurredAt: date, timeZoneIdentifier: "UTC", meal: meal)
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        try store.create(
            intake, components: [IntakeComponent(componentID: slug, name: name, amount: 40, unit: .g)],
            product: nil, now: date)
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

    // MARK: On Find products

    func testOftenLoggedSitsBetweenRecentAndFavoritesWithoutRepeatingRecent() throws {
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

    func testLibraryScreenSectionsAreUnchanged() throws {
        let store = try makeStore()
        for seconds in [1, 2] { try addEntry(store, "Oat porridge", at: seconds) }
        let library = try makeLibrary(store: store)
        library.load()

        XCTAssertEqual(library.sections.map(\.title), ["Favorites", "Products", "Recents"])
        XCTAssertEqual(library.frequentItems.map(\.title), ["Oat porridge"])
    }
}
