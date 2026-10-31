import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Forwards to a real journal, except that the two reads the Goals screen makes for captured supplements
/// can be made to throw, as a failed journal read would.
final class SnapshotReadFailingStore: JournalStore, @unchecked Sendable {
    let inner: SwiftDataJournalStore
    /// Makes the active-intakes read throw.
    var failsActiveIntakes = false
    /// Makes only the listed calls to the active-intakes read throw, counted from 1 in load()'s order: the
    /// units read (1), the compound-key read (2), then the display-name read (3).
    var failActiveIntakesCalls: Set<Int> = []
    private var activeIntakesCalls = 0
    /// The same counting for the revisions read and the product read, one call per helper for one entry.
    var failRevisionCalls: Set<Int> = []
    private var revisionCalls = 0
    var failProductCalls: Set<Int> = []
    private var productCalls = 0
    /// Makes the product-snapshot read throw.
    var failsProducts = false

    init(inner: SwiftDataJournalStore) { self.inner = inner }

    private struct SnapshotUnreadable: Error {}

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
        activeIntakesCalls += 1
        if failsActiveIntakes || failActiveIntakesCalls.contains(activeIntakesCalls) { throw SnapshotUnreadable() }
        return try inner.activeIntakes()
    }
    func revisions(of intakeID: String) throws -> [IntakeRevision] {
        revisionCalls += 1
        if failRevisionCalls.contains(revisionCalls) { throw SnapshotUnreadable() }
        return try inner.revisions(of: intakeID)
    }
    func projections(of intakeID: String) throws -> [DestinationProjection] { try inner.projections(of: intakeID) }
    func pendingOutbox() throws -> [OutboxOperation] { try inner.pendingOutbox() }
    func product(snapshotID: String) throws -> ProductDefinition? {
        productCalls += 1
        if failsProducts || failProductCalls.contains(productCalls) { throw SnapshotUnreadable() }
        return try inner.product(snapshotID: snapshotID)
    }
    func activeIntakesFromBackground() async throws -> [Intake] { try await inner.activeIntakesFromBackground() }
    func close() { inner.close() }
}

/// A journal read that fails while the Goals screen reads captured supplement keys must refuse the list, as a
/// failed goals read does, rather than quietly drop the captured keys or guess their units.
@MainActor
final class GoalsSnapshotReadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeJournal() throws -> SnapshotReadFailingStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let inner = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let product = ProductDefinition(
            snapshotID: "label-creatine", productID: "label_capture", name: "Synthetic Gummies",
            labelBasis: "per serving (30 g)", catalogOrigin: "label_capture", catalogVersion: "unknown",
            nutrients: ["creatine-monohydrate": .known(Decimal(3), .g)])
        try inner.create(
            Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "gummies", name: "Gummies", amount: Decimal(30), unit: .g)],
            product: product, now: now)
        return SnapshotReadFailingStore(inner: inner)
    }

    /// A failed read of the entries makes the Goals list refuse, not omit the captured compound.
    func testFailedEntryReadRefusesTheListInsteadOfDroppingCapturedKeys() throws {
        let journal = try makeJournal()
        journal.failsActiveIntakes = true
        let model = GoalsViewModel(
            store: InMemoryGoalStore(goals: [NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)]),
            journal: journal, preferences: InMemoryDisplayPreferences())
        model.load()
        XCTAssertEqual(model.errorMessage, GoalsViewModel.readFailedMessage)
        XCTAssertTrue(model.rows.isEmpty)
    }

    /// A failed read of the product snapshot makes the Goals list refuse, not guess the captured unit.
    func testFailedProductReadRefusesTheListInsteadOfGuessingUnits() throws {
        let journal = try makeJournal()
        journal.failsProducts = true
        let model = GoalsViewModel(
            store: InMemoryGoalStore(goals: [NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)]),
            journal: journal, preferences: InMemoryDisplayPreferences())
        model.load()
        XCTAssertEqual(model.errorMessage, GoalsViewModel.readFailedMessage)
        XCTAssertTrue(model.rows.isEmpty)
    }

    /// Once the journal reads again, a later load shows the list and clears the refusal.
    func testALaterSuccessfulLoadShowsTheListAgain() throws {
        let journal = try makeJournal()
        journal.failsActiveIntakes = true
        let model = GoalsViewModel(
            store: InMemoryGoalStore(goals: [NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)]),
            journal: journal, preferences: InMemoryDisplayPreferences())
        model.load()
        XCTAssertEqual(model.errorMessage, GoalsViewModel.readFailedMessage)
        journal.failsActiveIntakes = false
        model.load()
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.rows.isEmpty)
    }

    /// Only the units read fails: its helper's refusal must hold on its own.
    func testFailedUnitsReadAloneRefusesTheList() throws {
        let journal = try makeJournal()
        journal.failActiveIntakesCalls = [1]
        let model = GoalsViewModel(
            store: InMemoryGoalStore(goals: [NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)]),
            journal: journal, preferences: InMemoryDisplayPreferences())
        model.load()
        XCTAssertEqual(model.errorMessage, GoalsViewModel.readFailedMessage)
        XCTAssertTrue(model.rows.isEmpty)
    }

    /// Only the compound-key read fails, after the units read has succeeded.
    func testFailedCompoundKeyReadAloneRefusesTheList() throws {
        let journal = try makeJournal()
        journal.failActiveIntakesCalls = [2]
        let model = GoalsViewModel(
            store: InMemoryGoalStore(goals: [NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)]),
            journal: journal, preferences: InMemoryDisplayPreferences())
        model.load()
        XCTAssertEqual(model.errorMessage, GoalsViewModel.readFailedMessage)
        XCTAssertTrue(model.rows.isEmpty)
    }

    /// Only the display-name read fails, after the units and compound-key reads have succeeded.
    func testFailedDisplayNameReadAloneRefusesTheList() throws {
        let journal = try makeJournal()
        journal.failActiveIntakesCalls = [3]
        let model = GoalsViewModel(
            store: InMemoryGoalStore(goals: [NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)]),
            journal: journal, preferences: InMemoryDisplayPreferences())
        model.load()
        XCTAssertEqual(model.errorMessage, GoalsViewModel.readFailedMessage)
        XCTAssertTrue(model.rows.isEmpty)
    }

    /// The units read is the one whose refusal is seen; the keys and names helpers each need their own revisions read to fail.
    func testFailedRevisionReadInTheCompoundKeyHelperAloneRefusesTheList() throws {
        let journal = try makeJournal()
        journal.failRevisionCalls = [2]
        let model = GoalsViewModel(
            store: InMemoryGoalStore(goals: [NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)]),
            journal: journal, preferences: InMemoryDisplayPreferences())
        model.load()
        XCTAssertEqual(model.errorMessage, GoalsViewModel.readFailedMessage)
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testFailedRevisionReadInTheDisplayNameHelperAloneRefusesTheList() throws {
        let journal = try makeJournal()
        journal.failRevisionCalls = [3]
        let model = GoalsViewModel(
            store: InMemoryGoalStore(goals: [NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)]),
            journal: journal, preferences: InMemoryDisplayPreferences())
        model.load()
        XCTAssertEqual(model.errorMessage, GoalsViewModel.readFailedMessage)
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testFailedProductReadInTheCompoundKeyHelperAloneRefusesTheList() throws {
        let journal = try makeJournal()
        journal.failProductCalls = [2]
        let model = GoalsViewModel(
            store: InMemoryGoalStore(goals: [NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)]),
            journal: journal, preferences: InMemoryDisplayPreferences())
        model.load()
        XCTAssertEqual(model.errorMessage, GoalsViewModel.readFailedMessage)
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testFailedProductReadInTheDisplayNameHelperAloneRefusesTheList() throws {
        let journal = try makeJournal()
        journal.failProductCalls = [3]
        let model = GoalsViewModel(
            store: InMemoryGoalStore(goals: [NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)]),
            journal: journal, preferences: InMemoryDisplayPreferences())
        model.load()
        XCTAssertEqual(model.errorMessage, GoalsViewModel.readFailedMessage)
        XCTAssertTrue(model.rows.isEmpty)
    }

    /// A failed load must not keep the units a good load stored: a captured compound stated in mg shows its
    /// stored unit after a good load, and the default once a later load's read fails.
    func testAFailedLoadDropsTheUnitsAnEarlierLoadStored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let inner = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let product = ProductDefinition(
            snapshotID: "label-dha", productID: "label_capture", name: "Synthetic Gummies",
            labelBasis: "per serving (30 g)", catalogOrigin: "label_capture", catalogVersion: "unknown",
            nutrients: ["dha": .known(Decimal(500), .mg)])
        try inner.create(
            Intake(id: UUID().uuidString.lowercased(), category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "gummies", name: "Gummies", amount: Decimal(30), unit: .g)],
            product: product, now: now)
        let journal = SnapshotReadFailingStore(inner: inner)
        let model = GoalsViewModel(
            store: InMemoryGoalStore(goals: [NutrientGoal(nutrient: "energy", target: 2000, unit: .kcal)]),
            journal: journal, preferences: InMemoryDisplayPreferences())
        model.load()
        XCTAssertEqual(model.unit(for: "dha"), .mg)

        journal.failsActiveIntakes = true
        model.load()
        XCTAssertEqual(model.errorMessage, GoalsViewModel.readFailedMessage)
        XCTAssertEqual(model.unit(for: "dha"), NutrientGoalChoices.unit(forKey: "dha"))
    }
}
