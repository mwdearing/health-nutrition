import Foundation
import NutritionDomain
import NutritionJournal
@testable import NutritionUI

/// Forwards every call to a real journal, except that reading the logged units throws, as a failed read would.
/// Fails exactly one logged-units read, chosen by call number, so a test can isolate the read it targets (#415).
/// Used from one test at a time, not shared across tasks: the two test files that use it call load() synchronously.
final class UnitReadCountingStore: JournalStore, JournalLoggedUnits, @unchecked Sendable {
    let inner: SwiftDataJournalStore

    init(inner: SwiftDataJournalStore) { self.inner = inner }

    /// Throws only on this call to loggedUnits(), counted from 1 for this store. Nil means no call fails.
    var failsOnUnitReadCall: Int?
    /// The entry whose revisions read throws, as a failed journal read would. Nil means none fails.
    var failsRevisionsReadFor: String?
    /// How many times loggedUnits() has been called on this store.
    private(set) var unitReadCalls = 0

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
        if failsRevisionsReadFor == intakeID { throw UnitsUnreadable() }
        return try inner.revisions(of: intakeID)
    }
    func projections(of intakeID: String) throws -> [DestinationProjection] { try inner.projections(of: intakeID) }
    func pendingOutbox() throws -> [OutboxOperation] { try inner.pendingOutbox() }
    func product(snapshotID: String) throws -> ProductDefinition? { try inner.product(snapshotID: snapshotID) }
    func activeIntakesFromBackground() async throws -> [Intake] { try await inner.activeIntakesFromBackground() }
    func close() { inner.close() }
}

extension UnitReadCountingStore {
    struct UnitsUnreadable: Error {}

    /// The inner store as its logged-units seam, checked once here rather than in each method (#601).
    private var loggedUnitsStore: JournalLoggedUnits {
        guard let units = inner as? JournalLoggedUnits else { preconditionFailure("inner store must conform to JournalLoggedUnits") }
        return units
    }

    func recordLoggedUnit(_ loggedUnit: JournalLoggedUnit) throws {
        try loggedUnitsStore.recordLoggedUnit(loggedUnit)
    }

    func loggedUnits() throws -> [JournalLoggedUnit] {
        unitReadCalls += 1
        if unitReadCalls == failsOnUnitReadCall { throw UnitsUnreadable() }
        return try loggedUnitsStore.loggedUnits()
    }

    func removeLoggedUnit(intakeID: String, componentID: String) throws {
        try loggedUnitsStore.removeLoggedUnit(intakeID: intakeID, componentID: componentID)
    }
}
