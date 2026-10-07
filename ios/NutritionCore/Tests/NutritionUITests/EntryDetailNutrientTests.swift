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
        let entryID = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: entryID, category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "gummies", name: "Gummies", amount: Decimal(30), unit: .g)],
            product: product, now: now)

        let model = EntryDetailViewModel(store: store, intakeID: entryID, timeZoneIdentifier: "UTC")
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
        let entryID = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: entryID, category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "oats", name: "Oats", amount: Decimal(40), unit: .g)],
            product: nil, now: now)

        let model = EntryDetailViewModel(store: store, intakeID: entryID, timeZoneIdentifier: "UTC")
        model.load(now: now)

        XCTAssertTrue(model.additionalNutrients.isEmpty)
    }

    /// The name the label printed is kept beside the slug and shown, so `dha` reads `DHA` rather than
    /// the `Dha` a slug spells back out. The slug is still the key the value is stored under.
    func testAnEntrysPrintedCompoundNameIsShownRatherThanTheSlugSpelling() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let product = ProductDefinition(
            snapshotID: "label-dha", productID: "label_capture", name: "Synthetic Gummies",
            labelBasis: "per serving (30 g)", catalogOrigin: "label_capture", catalogVersion: "unknown",
            nutrients: ["dha": .known(Decimal(500), .mg)],
            nutrientDisplayNames: ["dha": "DHA"])
        let entryID = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: entryID, category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "gummies", name: "Gummies", amount: Decimal(30), unit: .g)],
            product: product, now: now)

        let model = EntryDetailViewModel(store: store, intakeID: entryID, timeZoneIdentifier: "UTC")
        model.load(now: now)

        let row = try XCTUnwrap(model.additionalNutrients.first)
        XCTAssertEqual(row.key, "dha")
        XCTAssertEqual(row.name, "DHA")
        XCTAssertEqual(row.amountText, "500 mg")
    }

    /// A barcode snapshot completes its own standard keys as unknown, and a key it says nothing about
    /// is not a row a label stated: only a key captured with a known amount is listed under
    /// "Also on the label", so a barcode's unknown `salt` never appears.
    func testABarcodeSnapshotsUnknownStandardKeyIsNotListedAsAnAdditionalNutrient() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let product = ProductDefinition(
            snapshotID: "lookup-bar", productID: "1234567890128", name: "Breakfast bar",
            labelBasis: "per 100 g", catalogOrigin: "test", catalogVersion: "1",
            nutrients: [
                "energyKcal": .known(Decimal(400), .kcal),
                "salt": .unknown,
                "sodium": .known(Decimal(120), .mg),
            ])
        let entryID = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: entryID, category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "bar", name: "Breakfast bar", amount: Decimal(40), unit: .g)],
            product: product, now: now)

        let model = EntryDetailViewModel(store: store, intakeID: entryID, timeZoneIdentifier: "UTC")
        model.load(now: now)

        XCTAssertTrue(model.additionalNutrients.isEmpty)
    }
}
