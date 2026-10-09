import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The source rows an entry's detail screen shows under "Where this came from": the input, the catalog
/// version, the barcode and the label basis, as the product snapshot stores them. Synthetic values only.
@MainActor
final class EntryDetailProvenanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// One entry with one component named "Example oats", in UTC, with an optional product snapshot.
    private func addEntry(_ store: SwiftDataJournalStore, product: ProductDefinition?) throws -> String {
        let id = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: id, category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "example-oats", name: "Example oats", amount: 40, unit: .g)],
            product: product, now: now)
        return id
    }

    private func barcodeProduct() -> ProductDefinition {
        ProductDefinition(
            snapshotID: "provenance-barcode", productID: "4006381333931", name: "Example oats",
            barcode: "4006381333931", labelBasis: "per 100 g", catalogOrigin: "example-catalog", catalogVersion: "2")
    }

    private func labelProduct() -> ProductDefinition {
        ProductDefinition(
            snapshotID: "provenance-label", productID: "label_capture", name: "Example bar",
            labelBasis: "per serving (30 g)", catalogOrigin: ProductOrigin.label_capture, catalogVersion: "unknown")
    }

    // MARK: Rows by origin

    func testProvenanceRowsForBarcodeLookupReadInputBarcodeVersionBasis() {
        let rows = EntryDetailViewModel.sourceDetails(for: barcodeProduct())
        XCTAssertEqual(rows, [
            SourceDetailRow(label: "Input", value: "Barcode lookup"),
            SourceDetailRow(label: "Barcode", value: "4006381333931"),
            SourceDetailRow(label: "Catalog version", value: "2"),
            SourceDetailRow(label: "Basis", value: "per 100 g"),
        ])
    }

    func testProvenanceRowsForLabelCaptureLeaveOutTheUnknownVersion() {
        let rows = EntryDetailViewModel.sourceDetails(for: labelProduct())
        XCTAssertEqual(rows, [
            SourceDetailRow(label: "Input", value: "Label scan"),
            SourceDetailRow(label: "Basis", value: "per serving (30 g)"),
        ])
        XCTAssertFalse(rows.contains { $0.value.contains("unknown") || $0.label.contains("unknown") })
    }

    func testProvenanceRowsForRecipeReadInputRecipeAndVersion() {
        let recipe = ProductDefinition(
            snapshotID: "provenance-recipe", productID: "example-salad", name: "Example salad",
            labelBasis: "per serving", catalogOrigin: RecipeLogger.catalogOrigin, catalogVersion: "3")
        XCTAssertEqual(EntryDetailViewModel.sourceDetails(for: recipe), [
            SourceDetailRow(label: "Input", value: "Recipe"),
            SourceDetailRow(label: "Recipe", value: "Example salad"),
            SourceDetailRow(label: "Version", value: "3"),
        ])
    }

    func testProvenanceRowsForEntryWithNoSnapshotSayNoSourceRecorded() {
        XCTAssertEqual(EntryDetailViewModel.sourceDetails(for: nil), [
            SourceDetailRow(label: "Source", value: "No source recorded"),
        ])
    }

    func testProvenanceRowsForTypedEntrySayTypedIn() {
        let typed = ProductDefinition(
            snapshotID: "provenance-typed", productID: "example-typed", name: "Example typed",
            labelBasis: "per serving", catalogOrigin: "manual", catalogVersion: "1")
        XCTAssertEqual(EntryDetailViewModel.sourceDetails(for: typed), [
            SourceDetailRow(label: "Input", value: "Typed in"),
        ])
    }

    // MARK: Values come from the stored snapshot

    func testProvenanceRowsReadTheStoredSnapshot() throws {
        let store = try makeStore()
        let barcodeID = try addEntry(store, product: barcodeProduct())
        let labelID = try addEntry(store, product: labelProduct())

        let barcodeModel = EntryDetailViewModel(store: store, intakeID: barcodeID, timeZoneIdentifier: "UTC")
        barcodeModel.load(now: now)
        XCTAssertTrue(barcodeModel.sourceDetailRows.contains(SourceDetailRow(label: "Barcode", value: "4006381333931")))
        XCTAssertTrue(barcodeModel.sourceDetailRows.contains(SourceDetailRow(label: "Catalog version", value: "2")))
        XCTAssertTrue(barcodeModel.sourceDetailRows.contains(SourceDetailRow(label: "Basis", value: "per 100 g")))

        let labelModel = EntryDetailViewModel(store: store, intakeID: labelID, timeZoneIdentifier: "UTC")
        labelModel.load(now: now)
        XCTAssertEqual(labelModel.sourceDetailRows, [
            SourceDetailRow(label: "Input", value: "Label scan"),
            SourceDetailRow(label: "Basis", value: "per serving (30 g)"),
        ])
        XCTAssertFalse(labelModel.sourceDetailRows.contains { $0.value.contains("unknown") })
    }
}
