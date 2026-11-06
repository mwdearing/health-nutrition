import Foundation
import XCTest
@testable import NutritionJournal
@testable import NutritionUI

/// Wraps a real store and makes one product read throw, so the journal can be shown with an unreadable snapshot.
/// Test-only: it lives in the test target and forwards everything else unchanged (#775).
final class ProductReadFailingStore: JournalStore, @unchecked Sendable {
    let base: JournalStore
    let failingSnapshotID: String

    init(base: JournalStore, failingSnapshotID: String) {
        self.base = base
        self.failingSnapshotID = failingSnapshotID
    }

    var failNextSaveForTesting: Bool {
        get { base.failNextSaveForTesting }
        set { base.failNextSaveForTesting = newValue }
    }
    var deleteSequence: UInt64 { base.deleteSequence }

    func create(_ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date) throws -> IntakeRevision {
        try base.create(intake, components: components, product: product, now: now)
    }
    func edit(intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
              now: Date, occurredAt: Date?, timeZoneIdentifier: String?) throws -> IntakeRevision {
        try base.edit(intakeID: intakeID, components: components, product: product, changeReason: changeReason,
                      now: now, occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier)
    }
    func editRemovingUnits(intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
                           now: Date, occurredAt: Date?, timeZoneIdentifier: String?, unitRemovals: [String]) throws -> IntakeRevision {
        try base.editRemovingUnits(intakeID: intakeID, components: components, product: product, changeReason: changeReason,
                                   now: now, occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier, unitRemovals: unitRemovals)
    }
    func edit(intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
              now: Date, occurredAt: Date?, timeZoneIdentifier: String?, expectedRevision: Int) throws -> IntakeRevision {
        try base.edit(intakeID: intakeID, components: components, product: product, changeReason: changeReason,
                      now: now, occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier, expectedRevision: expectedRevision)
    }
    func editRemovingUnits(intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
                           now: Date, occurredAt: Date?, timeZoneIdentifier: String?, unitRemovals: [String], expectedRevision: Int) throws -> IntakeRevision {
        try base.editRemovingUnits(intakeID: intakeID, components: components, product: product, changeReason: changeReason,
                                   now: now, occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier,
                                   unitRemovals: unitRemovals, expectedRevision: expectedRevision)
    }
    func delete(intakeID: String, now: Date) throws { try base.delete(intakeID: intakeID, now: now) }
    func deleteSequenced(intakeID: String, now: Date) throws -> UInt64 { try base.deleteSequenced(intakeID: intakeID, now: now) }
    func createSequenced(_ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date) throws -> (IntakeRevision, UInt64) {
        try base.createSequenced(intake, components: components, product: product, now: now)
    }
    func undoDelete(intakeID: String) throws { try base.undoDelete(intakeID: intakeID) }
    func activeIntakes() throws -> [Intake] { try base.activeIntakes() }
    func revisions(of intakeID: String) throws -> [IntakeRevision] { try base.revisions(of: intakeID) }
    func projections(of intakeID: String) throws -> [DestinationProjection] { try base.projections(of: intakeID) }
    func pendingOutbox() throws -> [OutboxOperation] { try base.pendingOutbox() }
    func product(snapshotID: String) throws -> ProductDefinition? {
        if snapshotID == failingSnapshotID { throw CocoaError(.fileReadUnknown) }
        return try base.product(snapshotID: snapshotID)
    }
    func activeIntakesFromBackground() async throws -> [Intake] { try await base.activeIntakesFromBackground() }
    func close() { base.close() }
}

@MainActor
final class JournalProductReadFailureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeJournal() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// An entry whose product snapshot is named, and which cannot be read back (#775).
    func testAnEntryWhoseProductCannotBeReadIsSkippedNotShownAsFood() throws {
        let journal = try makeJournal()
        let product = ProductDefinition(
            snapshotID: "snap-unreadable", productID: "synthetic-product", name: "Synthetic supplement",
            labelBasis: "per serving (1 tablet)", catalogOrigin: "test", catalogVersion: "unknown",
            kind: .supplement, nutrients: [:])
        let intakeID = UUID().uuidString.lowercased()
        try journal.create(
            Intake(id: intakeID, category: "water", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "water", name: "Example water", amount: 250, unit: .mL)],
            product: product, now: now)
        let model = JournalViewModel(
            store: ProductReadFailingStore(base: journal, failingSnapshotID: "snap-unreadable"),
            timeZoneIdentifier: "UTC", locale: Locale(identifier: "en_US"))
        model.load(now: now)

        XCTAssertEqual(model.skippedCount, 1)
        XCTAssertEqual(model.skippedText, "1 entry can't be shown because its saved time or record can't be read.")
        XCTAssertTrue(model.sections.flatMap(\.rows).isEmpty, "the entry is not listed as a food")
    }
}
