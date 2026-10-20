import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A favorite with no product snapshot takes its kind from its stored category, so a typed supplement reads as a
/// supplement dose and a typed food does not (#416, #364).
@MainActor
final class LibrarySnapshotlessFavoriteTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// Logs one typed entry of 19.72 mL (4 teaspoons) in `category`, favorites it, and returns the favorite row.
    private func favoriteRow(category: String) throws -> LibraryItem {
        let directory = try makeDirectory()
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let favorites = try SwiftDataFavoritesStore(url: directory.appendingPathComponent("favorites.store"))
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: category, occurredAt: now.addingTimeInterval(-300),
            timeZoneIdentifier: "UTC", meal: nil)
        try store.create(
            intake, components: [IntakeComponent(componentID: "typed-dose", name: "Fiber powder", amount: Decimal(string: "19.72")!, unit: .mL)],
            product: nil, now: now)
        let model = LibraryViewModel(store: store, favorites: favorites, timeZoneIdentifier: "UTC")
        model.load()
        model.segment = .recent
        let recent = try XCTUnwrap(model.visibleItems.first)
        model.addFavorite(recent)
        model.load()
        model.segment = .favorites
        return try XCTUnwrap(model.visibleItems.first)
    }

    func testSnapshotlessSupplementFavoriteReadsAsTheSpoonItWasTypedIn() throws {
        let row = try favoriteRow(category: "supplement")
        XCTAssertTrue(row.detail.contains("tsp"), "a typed supplement dose reads as the spoon, got \(row.detail)")
    }

    func testSnapshotlessSupplementFavoriteIsTheSupplementKind() throws {
        let row = try favoriteRow(category: "supplement")
        XCTAssertEqual(row.kind, .supplement)
    }

    func testSnapshotlessFoodFavoriteKeepsItsMillilitresWithNoSpoonReading() throws {
        let row = try favoriteRow(category: "food")
        XCTAssertEqual(row.kind, .food)
        XCTAssertFalse(row.detail.contains("tsp"), "a typed food has no spoon reading, got \(row.detail)")
        XCTAssertTrue(row.detail.contains("mL"), "a typed food keeps its millilitres, got \(row.detail)")
    }
}
