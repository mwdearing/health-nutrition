import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The entry screen's design: where an entry came from, what it added, how it was changed, where it was
/// sent, and when Save is offered. Synthetic names only.
@MainActor
final class EntryDetailDesignTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// One entry with one component named "Example oats", in UTC, with an optional product snapshot.
    private func addEntry(
        _ store: SwiftDataJournalStore, amount: Decimal = 40, product: ProductDefinition? = nil
    ) throws -> String {
        let id = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: id, category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "example-oats", name: "Example oats", amount: amount, unit: .g)],
            product: product, now: now)
        return id
    }

    // MARK: Source line

    func testEntryDetailSourceLineReadsEachOrigin() {
        let barcode = ProductDefinition(
            snapshotID: "design-barcode", productID: "4006381333931", name: "Example oats",
            labelBasis: "per 100 g", catalogOrigin: "example-catalog", catalogVersion: "1")
        XCTAssertEqual(EntryDetailViewModel.sourceLine(for: barcode), "Barcode lookup · values per 100 g")

        let label = ProductDefinition(
            snapshotID: "design-label", productID: "label_capture", name: "Example bar",
            labelBasis: "per serving (30 g)", catalogOrigin: ProductOrigin.label_capture, catalogVersion: "unknown")
        XCTAssertEqual(EntryDetailViewModel.sourceLine(for: label), "Label scan · per serving (30 g)")

        let recipe = ProductDefinition(
            snapshotID: "design-recipe", productID: "example-salad", name: "Example salad",
            labelBasis: "per serving", catalogOrigin: RecipeLogger.catalogOrigin, catalogVersion: "1")
        XCTAssertEqual(EntryDetailViewModel.sourceLine(for: recipe), "Recipe · Example salad")

        XCTAssertEqual(EntryDetailViewModel.sourceLine(for: nil), "Typed in · no nutrition values")
    }

    // MARK: Changes

    func testEntryDetailChangesReadAsPlainVerbs() throws {
        let store = try makeStore()
        let id = try addEntry(store)
        let model = EntryDetailViewModel(store: store, intakeID: id, timeZoneIdentifier: "UTC")
        model.load(now: now)

        model.drafts["example-oats"] = "55"
        model.changeReason = "Example reason"
        XCTAssertTrue(model.saveDrafts(now: now))
        XCTAssertEqual(model.changes.first { $0.id == 2 }?.note, "Example reason")

        model.occurredAt = now.addingTimeInterval(-3_600)
        XCTAssertTrue(model.saveDrafts(now: now))

        XCTAssertEqual(model.changes.map(\.verb), ["Time corrected", "Amount changed", "Logged"])
        XCTAssertEqual(model.changes.map(\.id), [3, 2, 1])
    }

    func testEntryDetailChangesReadAsPlainVerbsAndDefaultReasonGivesNoNote() throws {
        let store = try makeStore()
        let id = try addEntry(store)
        let model = EntryDetailViewModel(store: store, intakeID: id, timeZoneIdentifier: "UTC")
        model.load(now: now)

        model.drafts["example-oats"] = "55"
        XCTAssertEqual(model.changeReason, EntryDetailViewModel.defaultChangeReason)
        XCTAssertTrue(model.saveDrafts(now: now))
        let amountChange = try XCTUnwrap(model.changes.first { $0.id == 2 })
        XCTAssertEqual(amountChange.verb, "Amount changed")
        XCTAssertNil(amountChange.note)
        XCTAssertEqual(model.changes.last?.verb, "Logged")
    }

    // MARK: Save

    func testEntryDetailSaveAppearsOnlyAfterAChange() throws {
        let store = try makeStore()
        let id = try addEntry(store)
        let model = EntryDetailViewModel(store: store, intakeID: id, timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertFalse(model.isDirty)

        model.drafts["example-oats"] = "42.25"
        XCTAssertTrue(model.isDirty)

        XCTAssertTrue(model.saveDrafts(now: now))
        XCTAssertFalse(model.isDirty)

        model.occurredAt = now.addingTimeInterval(-3_600)
        XCTAssertTrue(model.isDirty)
    }

    // MARK: Sent to

    func testEntryDetailSentToWordsCoverEveryState() throws {
        let texts = DestinationState.allCases.map { EntryDetailViewModel.sentToText($0) }
        XCTAssertEqual(texts.count, 5)
        XCTAssertEqual(Set(texts).count, DestinationState.allCases.count)
        XCTAssertEqual(EntryDetailViewModel.sentToText(.pending), "Waiting to send")
        XCTAssertEqual(EntryDetailViewModel.sentToText(.inProgress), "Sending")
        XCTAssertEqual(EntryDetailViewModel.sentToText(.succeeded), "Sent")
        XCTAssertEqual(EntryDetailViewModel.sentToText(.needsAttention), "Needs attention")
        XCTAssertEqual(EntryDetailViewModel.sentToText(.disabled), "Not connected")
    }

    func testEntryDetailSentToLabelsNameTheDestinations() throws {
        XCTAssertEqual(EntryDetailViewModel.sentToLabel(.healthKit), "Apple Health")
        XCTAssertEqual(EntryDetailViewModel.sentToLabel(.relay), "HealthRelay")

        let store = try makeStore()
        let id = try addEntry(store)
        let model = EntryDetailViewModel(store: store, intakeID: id, timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertEqual(model.destinations.first { $0.destination == .healthKit }?.sentToLabel, "Apple Health")
        XCTAssertEqual(model.destinations.first { $0.destination == .relay }?.sentToLabel, "HealthRelay")
        XCTAssertEqual(model.destinations.first { $0.destination == .healthKit }?.sentToText, "Waiting to send")
    }

    // MARK: This entry adds

    func testEntryDetailThisEntryAddsScalesTheStoredLabelValue() throws {
        let store = try makeStore()
        let product = ProductDefinition(
            snapshotID: "design-oats-per-100g", productID: "example-oats", name: "Example oats",
            labelBasis: "per 100 g", catalogOrigin: "example", catalogVersion: "1",
            nutrients: ["protein": .known(13, .g)])
        let id = try addEntry(store, amount: 50, product: product)
        let model = EntryDetailViewModel(store: store, intakeID: id, timeZoneIdentifier: "UTC")
        model.load(now: now)

        let protein = try XCTUnwrap(model.adds.first { $0.key == "protein" })
        XCTAssertEqual(protein.amountText, "6.5 g")
        XCTAssertEqual(model.adds.first { $0.key == "energyKcal" }?.amountText, "Not on the label")
    }

    func testEntryDetailThisEntryAddsIsEmptyWithoutASnapshot() throws {
        let store = try makeStore()
        let id = try addEntry(store, product: nil)
        let model = EntryDetailViewModel(store: store, intakeID: id, timeZoneIdentifier: "UTC")
        model.load(now: now)
        XCTAssertTrue(model.adds.isEmpty)
    }
}
