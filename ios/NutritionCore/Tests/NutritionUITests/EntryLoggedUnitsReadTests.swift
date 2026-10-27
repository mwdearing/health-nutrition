import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// #597: a failed read of the logged units stops the entry editor, rather than showing the entry without units.
@MainActor
final class EntryLoggedUnitsReadTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    func testAFailedLoggedUnitsReadRefusesTheEntryEditor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let inner = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let entryID = UUID().uuidString.lowercased()
        try inner.create(
            Intake(id: entryID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "oats", name: "Oats", amount: Decimal(40), unit: .g)],
            product: nil, now: when)
        let store = UnitReadFailingStore(inner: inner)
        store.failsUnitReads = true

        let model = EntryDetailViewModel(store: store, intakeID: entryID, timeZoneIdentifier: "UTC")
        model.load(now: when)

        XCTAssertEqual(model.errorMessage, "Could not read this entry.")
    }
}
