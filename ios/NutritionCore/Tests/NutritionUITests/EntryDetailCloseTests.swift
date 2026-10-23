import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Closing the entry sheet asks first only when a change would be lost. Synthetic values only.
@MainActor
final class EntryDetailCloseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func addEntry(_ store: SwiftDataJournalStore) throws -> String {
        let id = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: id, category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "example-oats", name: "Example oats", amount: 40, unit: .g)],
            product: nil, now: now)
        return id
    }

    func testClosingAnUnchangedEntryDoesNotAsk() throws {
        let store = try makeStore()
        let model = EntryDetailViewModel(store: store, intakeID: try addEntry(store), timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertFalse(model.closeAsksFirst)
    }

    func testClosingAfterChangingTheTimeAsks() throws {
        let store = try makeStore()
        let model = EntryDetailViewModel(store: store, intakeID: try addEntry(store), timeZoneIdentifier: "UTC")
        model.load(now: now)
        model.occurredAt = now.addingTimeInterval(-3_600)
        XCTAssertTrue(model.closeAsksFirst)
    }
}
