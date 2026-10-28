import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A product snapshot that cannot be read is a failed read, not an entry without a product: each screen shows
/// its existing read error rather than nutrients read as none, a supplement counted as food, or a missing row
/// (#775). A snapshot that is simply absent still reads as no product.
@MainActor
final class SnapshotReadFailureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> UnitReadCountingStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return UnitReadCountingStore(inner: try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store")))
    }

    private let product = ProductDefinition(
        snapshotID: "s-synthetic", productID: "p-synthetic", name: "Synthetic Oats", labelBasis: "per 100 g",
        catalogOrigin: "test", catalogVersion: "1", kind: .food, nutrients: ["iron": .known(4, .mg)])

    @discardableResult
    private func logWithProduct(_ store: JournalStore, at date: Date) throws -> String {
        let id = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: id, category: "food", occurredAt: date, timeZoneIdentifier: "UTC", meal: nil),
            components: [IntakeComponent(componentID: "oats", name: "Oats", amount: 100, unit: .g)],
            product: product, now: date)
        return id
    }

    func testEntryDetailShowsItsReadErrorWhenTheSnapshotCannotBeRead() throws {
        let store = try makeStore()
        let id = try logWithProduct(store, at: now)
        store.failsProductReads = true
        let model = EntryDetailViewModel(store: store, intakeID: id, timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertEqual(model.errorMessage, "Could not read this entry.")
    }

    func testVitaminsAndMineralsShowTheirReadErrorWhenASnapshotCannotBeRead() throws {
        let store = try makeStore()
        try logWithProduct(store, at: now.addingTimeInterval(-60))
        store.failsProductReads = true
        XCTAssertThrowsError(try NutrientGapsViewModel.tallies(store: store, lookup: SnapshotNutrientFacts(), now: now, days: 1))
    }

    func testLibraryShowsItsLoadErrorWhenAProductSnapshotCannotBeRead() throws {
        let store = try makeStore()
        try logWithProduct(store, at: now)
        store.failsProductReads = true
        XCTAssertThrowsError(try RecentItemsProvider(store: store).foods())
    }

    /// With the reads working, the same entries read as before.
    func testReadableSnapshotsStillRead() throws {
        let store = try makeStore()
        let id = try logWithProduct(store, at: now)
        let model = EntryDetailViewModel(store: store, intakeID: id, timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try RecentItemsProvider(store: store).foods().count, 1)
    }
}
