import Foundation
import NutritionDomain
import NutritionJournal
@testable import NutritionUI

/// Forwards every call to a real journal, except that reading the logged units throws, as a failed read would.
/// Each read that feeds a total or a write must report the failure and never take an empty index in its place.
/// Shared by the tests of those reads (#415).
final class UnitReadFailingStore: JournalStore, JournalLoggedUnits, @unchecked Sendable {
    let inner: SwiftDataJournalStore

    init(inner: SwiftDataJournalStore) { self.inner = inner }

    var failNextSaveForTesting: Bool {
        get { inner.failNextSaveForTesting }
        set { inner.failNextSaveForTesting = newValue }
    }

    func create(_ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date) throws
        -> IntakeRevision
    {
        try inner.create(intake, components: components, product: product, now: now)
    }
    func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date?, timeZoneIdentifier: String?
    ) throws -> IntakeRevision {
        try inner.edit(
            intakeID: intakeID, components: components, product: product, changeReason: changeReason, now: now,
            occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier)
    }

    func editRemovingUnits(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date?, timeZoneIdentifier: String?, unitRemovals: [String]) throws -> IntakeRevision {
        try inner.editRemovingUnits(
            intakeID: intakeID, components: components, product: product, changeReason: changeReason, now: now,
            occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier, unitRemovals: unitRemovals)
    }
    func delete(intakeID: String, now: Date) throws { try inner.delete(intakeID: intakeID, now: now) }
    func activeIntakes() throws -> [Intake] {
        return try inner.activeIntakes()
    }
    func revisions(of intakeID: String) throws -> [IntakeRevision] {
        return try inner.revisions(of: intakeID)
    }
    func projections(of intakeID: String) throws -> [DestinationProjection] { try inner.projections(of: intakeID) }
    func pendingOutbox() throws -> [OutboxOperation] { try inner.pendingOutbox() }
    func product(snapshotID: String) throws -> ProductDefinition? { try inner.product(snapshotID: snapshotID) }
    func activeIntakesFromBackground() async throws -> [Intake] { try await inner.activeIntakesFromBackground() }
    func close() { inner.close() }
}

extension UnitReadFailingStore {
    struct UnitsUnreadable: Error {}

    func recordLoggedUnit(_ loggedUnit: JournalLoggedUnit) throws {
        guard let units = inner as? JournalLoggedUnits else { return }
        try units.recordLoggedUnit(loggedUnit)
    }

    func loggedUnits() throws -> [JournalLoggedUnit] { throw UnitsUnreadable() }

    func removeLoggedUnit(intakeID: String, componentID: String) throws {
        guard let units = inner as? JournalLoggedUnits else { return }
        try units.removeLoggedUnit(intakeID: intakeID, componentID: componentID)
    }
}
