import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A failed revisions read for one entry is a failed read, not an entry with nothing to show: Recents, Products
/// and Frequent throw, and the Library shows its load error instead of quietly losing that entry's row (#775).
@MainActor
final class LibraryRevisionsReadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> UnitReadCountingStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return UnitReadCountingStore(inner: try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store")))
    }

    /// Logs Oats twice and returns the id of the newest entry.
    @discardableResult
    private func logOatsTwice(_ store: JournalStore) throws -> String {
        var newest = ""
        for seconds in [0, 60] {
            let date = now.addingTimeInterval(TimeInterval(seconds))
            newest = UUID().uuidString.lowercased()
            try store.create(
                Intake(id: newest, category: "food", occurredAt: date, timeZoneIdentifier: "UTC", meal: nil),
                components: [IntakeComponent(componentID: "oats", name: "Oats", amount: 40, unit: .g)],
                product: nil, now: date)
        }
        return newest
    }

    func testRecentsThrowWhenAnEntrysRevisionsCannotBeRead() throws {
        let store = try makeStore()
        store.failsRevisionsReadFor = try logOatsTwice(store)
        XCTAssertThrowsError(try RecentItemsProvider(store: store).recents())
    }

    func testProductsThrowWhenAnEntrysRevisionsCannotBeRead() throws {
        let store = try makeStore()
        store.failsRevisionsReadFor = try logOatsTwice(store)
        XCTAssertThrowsError(try RecentItemsProvider(store: store).foods())
    }

    func testFrequentThrowsWhenAnEntrysRevisionsCannotBeRead() throws {
        let store = try makeStore()
        store.failsRevisionsReadFor = try logOatsTwice(store)
        XCTAssertThrowsError(try FrequentItemsProvider(store: store).frequents())
    }

    func testTheLibraryShowsItsLoadErrorRatherThanDroppingTheRow() throws {
        let store = try makeStore()
        store.failsRevisionsReadFor = try logOatsTwice(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let favorites = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        let model = LibraryViewModel(store: store, favorites: favorites, timeZoneIdentifier: "UTC")
        model.load()
        XCTAssertEqual(model.errorMessage, "Could not read the library.")
        XCTAssertTrue(model.sections.isEmpty)
    }

    /// A reload that fails clears the rows the earlier load showed, rather than keeping them under the error.
    func testAFailedReloadClearsTheEarlierRows() throws {
        let store = try makeStore()
        let id = try logOatsTwice(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let favorites = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        let model = LibraryViewModel(store: store, favorites: favorites, timeZoneIdentifier: "UTC")
        model.load()
        XCTAssertFalse(model.sections.isEmpty)
        store.failsRevisionsReadFor = id
        model.load()
        XCTAssertEqual(model.errorMessage, "Could not read the library.")
        XCTAssertTrue(model.sections.isEmpty)
    }

    /// Add's recents show their existing read error, and drop the earlier rows, when an entry cannot be read.
    func testAddRecentsShowTheirReadErrorWhenAnEntryCannotBeRead() throws {
        let store = try makeStore()
        let id = try logOatsTwice(store)
        let home = AddHomeViewModel(store: store, now: { self.now })
        home.load()
        XCTAssertEqual(home.recents.map(\.template.displayName), ["Oats"])
        store.failsRevisionsReadFor = id
        home.load()
        XCTAssertEqual(home.errorMessage, "Could not read recent items.")
        XCTAssertTrue(home.recents.isEmpty)
    }

    /// With every read working, the same entries show as before.
    func testReadableEntriesStillShow() throws {
        let store = try makeStore()
        try logOatsTwice(store)
        XCTAssertEqual(try RecentItemsProvider(store: store).recents().map(\.template.displayName), ["Oats"])
        XCTAssertEqual(try FrequentItemsProvider(store: store).frequents().map(\.template.displayName), ["Oats"])
    }
}
