import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The Library's own logged-units read (LibraryViewModel.load, its logged-units read) must report a failure and show no sections,
/// not repeat favorites in the stored unit. The load reads the logged units 4 times in total: calls 1–3 come from
/// RecentItemsProvider (recents, foods, frequents), and call 4 is the read this test fails (#415).
@MainActor
final class LibraryUnitReadTests: XCTestCase {
    /// Guards the read order: a full Library load makes exactly 4 logged-unit reads and shows no error (#415).
    func testFullLibraryLoadReadsLoggedUnitsExactlyFourTimes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let inner = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let store = UnitReadCountingStore(inner: inner)
        let favorites = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        let model = LibraryViewModel(store: store, favorites: favorites, timeZoneIdentifier: "UTC")
        model.load()
        XCTAssertEqual(store.unitReadCalls, 4)
        XCTAssertNil(model.errorMessage)
    }

    func testLibraryShowsNothingWhenItsOwnUnitReadFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let inner = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let store = UnitReadCountingStore(inner: inner)
        store.failsOnUnitReadCall = 4
        let favorites = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        let model = LibraryViewModel(store: store, favorites: favorites, timeZoneIdentifier: "UTC")
        model.load()
        XCTAssertEqual(store.unitReadCalls, 4)
        XCTAssertEqual(model.errorMessage, "Could not read the library.")
        XCTAssertTrue(model.sections.isEmpty)
    }
}
