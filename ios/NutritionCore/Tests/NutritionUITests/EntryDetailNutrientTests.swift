import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The compounds an entry's product snapshot states under names the fifteen journal nutrients do not
/// are shown on the entry screen, so a scanned supplement's own rows are not lost once saved.
@MainActor
final class EntryDetailNutrientTests: XCTestCase {
    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    func testAnEntrysSnapshotCompoundIsShownInTheEntryDetail() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let product = ProductDefinition(
            snapshotID: "label-synthetic", productID: "label_capture", name: "Synthetic Gummies",
            labelBasis: "per serving (30 g)", catalogOrigin: "label_capture", catalogVersion: "unknown",
            nutrients: ["creatine-monohydrate": .known(Decimal(3), .g)])
        try store.create(
            Intake(id: "entry-1", category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "gummies", name: "Gummies", amount: Decimal(30), unit: .g)],
            product: product, now: now)

        let model = EntryDetailViewModel(store: store, intakeID: "entry-1", timeZoneIdentifier: "UTC")
        model.load(now: now)

        let row = try XCTUnwrap(model.additionalNutrients.first)
        XCTAssertEqual(row.key, "creatine-monohydrate")
        XCTAssertEqual(row.name, "Creatine Monohydrate")
        XCTAssertEqual(row.amountText, "3 g")
    }

    /// An entry whose snapshot states only the named nutrients has nothing extra to show.
    func testAnEntryWithoutSnapshotsCompoundsShowsNone() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try store.create(
            Intake(id: "entry-2", category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "oats", name: "Oats", amount: Decimal(40), unit: .g)],
            product: nil, now: now)

        let model = EntryDetailViewModel(store: store, intakeID: "entry-2", timeZoneIdentifier: "UTC")
        model.load(now: now)

        XCTAssertTrue(model.additionalNutrients.isEmpty)
    }
}
