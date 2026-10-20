import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A typed supplement with no product snapshot reads as a spoon dose on the Diary and on Today, as the Library does (#416).
@MainActor
final class SnapshotlessSupplementRowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// One typed supplement of 19.72 mL (4 teaspoons), logged today, with no product snapshot.
    private func logTypedSupplement(_ store: SwiftDataJournalStore, category: String) throws {
        let intake = Intake(
            id: UUID().uuidString.lowercased(), category: category, occurredAt: now.addingTimeInterval(-300),
            timeZoneIdentifier: "UTC", meal: nil)
        try store.create(
            intake, components: [IntakeComponent(componentID: "typed-dose", name: "Fiber powder", amount: Decimal(string: "19.72")!, unit: .mL)],
            product: nil, now: now)
    }

    func testDiaryRowReadsATypedSupplementAsTheSpoon() throws {
        let store = try makeStore()
        try logTypedSupplement(store, category: "supplement")
        let journal = JournalViewModel(store: store, timeZoneIdentifier: "UTC")
        journal.load(now: now)
        let row = try XCTUnwrap(journal.sections.flatMap(\.rows).first)
        XCTAssertTrue(row.detail.contains("tsp"), "the Diary reads the typed supplement as the spoon, got \(row.detail)")
        XCTAssertEqual(row.kind, .supplement)
    }

    func testTodayRowReadsATypedSupplementAsTheSpoon() throws {
        let store = try makeStore()
        try logTypedSupplement(store, category: "supplement")
        let today = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        today.load(now: now)
        let row = try XCTUnwrap(today.rows.first)
        XCTAssertTrue(row.detail.contains("tsp"), "Today reads the typed supplement as the spoon, got \(row.detail)")
        XCTAssertEqual(row.kind, .supplement)
    }

    func testTypedFoodRowKeepsItsFluidOuncesOnTheDiary() throws {
        let store = try makeStore()
        try logTypedSupplement(store, category: "food")
        let journal = JournalViewModel(store: store, timeZoneIdentifier: "UTC")
        journal.load(now: now)
        let row = try XCTUnwrap(journal.sections.flatMap(\.rows).first)
        XCTAssertFalse(row.detail.contains("tsp"), "a typed food has no spoon reading, got \(row.detail)")
        XCTAssertEqual(row.kind, .food)
    }
}
