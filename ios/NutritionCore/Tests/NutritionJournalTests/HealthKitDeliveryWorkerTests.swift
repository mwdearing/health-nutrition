import Foundation
import NutritionDomain
import SwiftData
import XCTest
@testable import NutritionJournal

/// The delivery half of the HealthKit writer (NC-07B): what `HealthKitDeliveryWorker` does with the
/// queue the journal writes, on a real store on disk and against a fake writer.
///
/// Every value here is synthetic. The worker itself names no HealthKit type, which is what lets this
/// run on macOS; see ADR 0002 for the behaviour the app target's writer implements against HealthKit.
final class HealthKitDeliveryWorkerTests: XCTestCase {
    private let intakeID = "0b6f7d3e-5a1c-4c52-9a2e-3f1d8c7b6a10"
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    /// A writer that records what it was asked for and fails the way a test tells it to. It models
    /// only what the worker can observe: what was saved, which identifiers were deleted, and whether
    /// access is allowed.
    private final class FakeHealthSampleWriter: HealthSampleWriter, @unchecked Sendable {
        private let lock = NSLock()
        private var allowed: Set<String> = []
        private var saveError: HealthSampleWriterError?
        private var deleteError: HealthSampleWriterError?
        private var savedSpecs: [HealthKitSampleSpec] = []
        private var deletedIdentifiers: [String] = []
        private var saveCallCount = 0
        private var order: [String] = []

        /// The samples written so far, in the order they were passed in.
        var saved: [HealthKitSampleSpec] {
            lock.withLock { savedSpecs }
        }
        /// Every sync identifier passed to a delete, in call order.
        var deleted: [String] {
            lock.withLock { deletedIdentifiers }
        }
        var saveCalls: Int {
            lock.withLock { saveCallCount }
        }
        /// The write calls in the order they arrived, as "delete" and "save".
        var callOrder: [String] {
            lock.withLock { order }
        }

        func deny(_ identifier: String) {
            lock.withLock { _ = allowed.remove(identifier) }
        }

        func allow(_ identifier: String) {
            lock.withLock { _ = allowed.insert(identifier) }
        }

        /// nil clears the failure, so a test can let a retry through.
        func failSaves(with error: HealthSampleWriterError?) {
            lock.withLock { saveError = error }
        }

        func failDeletes(with error: HealthSampleWriterError?) {
            lock.withLock { deleteError = error }
        }

        func reset() {
            lock.withLock {
                savedSpecs = []
                deletedIdentifiers = []
                saveCallCount = 0
                order = []
            }
        }

        func canWrite(identifiers: [String]) async -> [String: Bool] {
            let allowed = lock.withLock { self.allowed }
            return Dictionary(uniqueKeysWithValues: identifiers.map { ($0, allowed.contains($0)) })
        }

        func save(_ specs: [HealthKitSampleSpec]) async throws {
            let error = lock.withLock { () -> HealthSampleWriterError? in
                saveCallCount += 1
                order.append("save")
                guard saveError == nil else { return saveError }
                savedSpecs.append(contentsOf: specs)
                return nil
            }
            if let error { throw error }
        }

        func deleteSamples(syncIdentifiers: [String]) async throws -> Int {
            let outcome = lock.withLock { () -> (HealthSampleWriterError?, Int) in
                order.append("delete")
                guard deleteError == nil else { return (deleteError, 0) }
                deletedIdentifiers.append(contentsOf: syncIdentifiers)
                return (nil, syncIdentifiers.count)
            }
            if let error = outcome.0 { throw error }
            return outcome.1
        }
    }

    /// A totals provider that answers from a dictionary and records the arguments it was called with.
    private final class RecordingTotals: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: NutrientValue]
        private var calls: [(intakeID: String, revision: Int)] = []

        init(_ values: [String: NutrientValue]) {
            self.values = values
        }

        var requested: [(intakeID: String, revision: Int)] {
            lock.withLock { calls }
        }

        func set(_ values: [String: NutrientValue]) {
            lock.withLock { self.values = values }
        }

        func totals(intakeID: String, revision: Int) async -> [String: NutrientValue] {
            lock.withLock {
                calls.append((intakeID, revision))
                return values
            }
        }
    }

    // MARK: - Fixtures

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeStore(
        _ directory: URL, enabled: Set<JournalDestination> = [.healthKit, .relay]
    ) throws -> SwiftDataJournalStore {
        try SwiftDataJournalStore(
            url: directory.appendingPathComponent("journal.store"), enabledDestinations: enabled)
    }

    private func sampleIntake(id: String? = nil) -> Intake {
        Intake(
            id: id ?? intakeID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC",
            meal: "breakfast")
    }

    private func component(
        _ id: String = "oats", amount: Decimal = 40, unit: MeasureUnit = .g
    ) -> IntakeComponent {
        IntakeComponent(componentID: id, name: "Rolled oats", amount: amount, unit: unit)
    }

    private func waterIdentifier(_ intakeID: String) -> String { "intake:\(intakeID):water" }
    private func proteinIdentifier(_ intakeID: String) -> String { "intake:\(intakeID):protein" }

    private func allMappedIdentifiers(_ intakeID: String) -> [String] {
        HealthKitWritePlanner.deletion(
            intakeID: intakeID, keys: HealthKitWritePlanner.mappings.map(\.nutrientKey))
    }

    /// A worker over a real store, a writer that allows every type it is asked about, and a totals
    /// provider the test drives.
    private func makeWorker(
        totals: [String: NutrientValue] = ["water": .known(dec("250"), .mL)],
        enabled: Set<JournalDestination> = [.healthKit, .relay],
        writer: FakeHealthSampleWriter = FakeHealthSampleWriter()
    ) throws -> (
        store: SwiftDataJournalStore, writer: FakeHealthSampleWriter, totals: RecordingTotals,
        worker: HealthKitDeliveryWorker
    ) {
        let store = try makeStore(try makeDirectory(), enabled: enabled)
        for mapping in HealthKitWritePlanner.mappings {
            writer.allow(mapping.quantityTypeIdentifier)
        }
        let recording = RecordingTotals(totals)
        let worker = HealthKitDeliveryWorker(
            store: store, writer: writer,
            totals: { intakeID, revision in await recording.totals(intakeID: intakeID, revision: revision) }
        )
        return (store, writer, recording, worker)
    }

    /// The healthKit operation for one kind, from the store's own queue.
    private func healthKitOperation(
        _ store: SwiftDataJournalStore, kind: OutboxKind? = nil
    ) throws -> OutboxOperation? {
        try store.pendingOutbox().first { $0.destination == .healthKit && (kind == nil || $0.kind == kind) }
    }

    private func projectionState(
        _ store: SwiftDataJournalStore, intakeID: String, destination: JournalDestination = .healthKit
    ) throws -> DestinationState? {
        try store.projections(of: intakeID).first { $0.destination == destination && $0.isCurrent }?.state
    }

    // MARK: - An upsert

    func testUpsertWritesThePlanAndAcknowledgesTheOperation() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        let operationID = try XCTUnwrap(healthKitOperation(store, kind: .upsert)?.operationID)
        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(writer.saved.map(\.syncIdentifier), [waterIdentifier(intakeID)])
        XCTAssertEqual(writer.saved.map(\.amount), [dec("250")])
        XCTAssertEqual(writer.saved.map(\.syncVersion), [1])
        XCTAssertEqual(writer.saved.map(\.start), [when], "the sample is stamped with the intake's own time")
        XCTAssertEqual(outcomes, [.delivered(operationID: operationID, samples: 1)])
        XCTAssertNil(try healthKitOperation(store, kind: .upsert), "an acknowledged operation leaves the queue")
        XCTAssertEqual(try projectionState(store, intakeID: intakeID), .succeeded)
    }

    func testTotalsAreAskedForWithTheIntakeAndRevisionBeingDelivered() async throws {
        let (store, _, totals, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        try store.edit(intakeID: intakeID, components: [component(amount: 55)], product: nil, changeReason: "bigger bowl", now: when)
        _ = await worker.runOnce(now: when)

        XCTAssertEqual(totals.requested.map(\.intakeID), [intakeID, intakeID])
        XCTAssertEqual(totals.requested.map(\.revision), [1, 2])
    }

    /// The stale sample has to go: revision 2 plans no protein, so nothing would replace what revision 1
    /// wrote and Health would keep showing it.
    func testAnEditDeletesTheNutrientTheNewRevisionNoLongerStates() async throws {
        let (store, writer, totals, worker) = try makeWorker(
            totals: ["water": .known(dec("250"), .mL), "protein": .known(dec("13"), .g)])

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        _ = await worker.runOnce(now: when)
        XCTAssertEqual(
            writer.saved.map(\.syncIdentifier), [proteinIdentifier(intakeID), waterIdentifier(intakeID)],
            "revision 1 writes both nutrients it states")
        XCTAssertEqual(writer.deleted, [], "there is nothing stale before there is a second revision")

        totals.set(["water": .known(dec("300"), .mL)])
        try store.edit(
            intakeID: intakeID, components: [component(amount: 55)], product: nil,
            changeReason: "no protein after all", now: when)
        writer.reset()

        _ = await worker.runOnce(now: when)

        XCTAssertTrue(
            writer.deleted.contains(proteinIdentifier(intakeID)),
            "the protein sample revision 1 wrote has to be retracted: revision 2 writes no sample to replace it")
        XCTAssertFalse(
            writer.deleted.contains(waterIdentifier(intakeID)),
            "the water sample is replaced by the save, so deleting it first would only risk a gap")
        XCTAssertEqual(writer.saved.map(\.syncIdentifier), [waterIdentifier(intakeID)])
        XCTAssertEqual(writer.saved.map(\.amount), [dec("300")])
        XCTAssertEqual(writer.saved.map(\.syncVersion), [2])
    }

    /// The stale deletion comes before the new save, so Health never holds two samples for one
    /// identifier at once.
    func testTheStaleSamplesAreDeletedBeforeTheNewRevisionIsSaved() async throws {
        let (store, writer, totals, worker) = try makeWorker(
            totals: ["water": .known(dec("250"), .mL), "protein": .known(dec("13"), .g)])

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        _ = await worker.runOnce(now: when)
        totals.set(["water": .known(dec("300"), .mL)])
        try store.edit(
            intakeID: intakeID, components: [component(amount: 55)], product: nil, changeReason: "e", now: when)
        writer.reset()

        _ = await worker.runOnce(now: when)

        XCTAssertEqual(writer.callOrder, ["delete", "save"])
    }

    // MARK: - A delete

    func testDeleteRemovesEveryMappedIdentifierForTheIntakeAndAcknowledges() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        try store.delete(intakeID: intakeID, now: when)
        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(writer.deleted, allMappedIdentifiers(intakeID))
        XCTAssertTrue(writer.saved.isEmpty, "a retracted intake writes nothing")
        XCTAssertEqual(outcomes.count, 2, "the queued upsert and the delete")
        XCTAssertTrue(try store.pendingOutbox().allSatisfy { $0.destination == .relay })
        XCTAssertEqual(try projectionState(store, intakeID: intakeID), .succeeded)
    }

    /// The queued upsert is stale the moment the delete is delivered: its samples were retracted, so
    /// writing it would put back exactly what was just removed.
    func testADeliveredDeleteLeavesTheQueuedUpsertSupersededRatherThanWritingIt() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        try store.delete(intakeID: intakeID, now: when)
        let upsertID = try XCTUnwrap(healthKitOperation(store, kind: .upsert)?.operationID)
        let deleteID = try XCTUnwrap(healthKitOperation(store, kind: .delete)?.operationID)

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(
            outcomes, [
                .superseded(operationID: upsertID),
                .retracted(operationID: deleteID, samples: HealthKitWritePlanner.mappings.count),
            ],
            "the store's own order puts the upsert before the delete, and the delete retracts what it would have written")
        XCTAssertEqual(writer.saveCalls, 0, "a sample written after the delete would undo it")
    }

    // MARK: - Authorization

    func testADeniedTypeLeavesTheOperationNeedingAttentionAndIsNotRetried() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        writer.deny("HKQuantityTypeIdentifierDietaryWater")
        let outcomes = await worker.runOnce(now: when)

        guard case .needsAttention(let operationID, _) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("a denied type must ask for a person, got \(outcomes)")
        }
        let operation = try XCTUnwrap(try store.pendingOutbox().first { $0.operationID == operationID })
        XCTAssertEqual(operation.attempts, 1)
        XCTAssertNil(operation.nextAttemptAt, "a denial is not retried on a timer: retrying cannot grant access")
        XCTAssertEqual(try projectionState(store, intakeID: intakeID), .needsAttention)
        XCTAssertEqual(writer.saveCalls, 0)
    }

    func testADeniedDeleteIsAlsoLeftForAPersonRatherThanRetried() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        try store.delete(intakeID: intakeID, now: when)
        writer.deny("HKQuantityTypeIdentifierDietaryWater")
        let outcomes = await worker.runOnce(now: when)

        XCTAssertTrue(outcomes.contains { if case .needsAttention = $0 { return true } else { return false } })
        XCTAssertEqual(writer.deleted, [])
        let delete = try XCTUnwrap(try healthKitOperation(store, kind: .delete))
        XCTAssertNil(delete.nextAttemptAt)
        XCTAssertEqual(try projectionState(store, intakeID: intakeID), .needsAttention)
    }

    // MARK: - Transient failures

    func testATransientFailureIsRetriedLaterOnTheBackoff() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        writer.failSaves(with: .transient("HealthKit store unavailable"))
        let outcomes = await worker.runOnce(now: when)

        guard case .retryScheduled(let operationID, let nextAttemptAt, _) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("a transient failure must schedule a retry, got \(outcomes)")
        }
        XCTAssertEqual(nextAttemptAt, when.addingTimeInterval(60), "the first retry waits one minute")
        let operation = try XCTUnwrap(try store.pendingOutbox().first { $0.operationID == operationID })
        XCTAssertEqual(operation.attempts, 1)
        XCTAssertEqual(operation.nextAttemptAt, nextAttemptAt)
        XCTAssertNil(operation.acknowledgedAt, "a failed delivery stays queued")
        XCTAssertEqual(try projectionState(store, intakeID: intakeID), .pending)
    }

    func testTheBackoffGrowsAcrossAttemptsAndThenStaysAtTwoHours() {
        let waits = (1...6).map { HealthKitDeliveryWorker.backoffSeconds(afterAttempts: $0) }

        XCTAssertEqual(waits, [60, 300, 1800, 7200, 7200, 7200])
    }

    func testAFailedDeleteIsRetriedRatherThanLeavingSamplesBehind() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        try store.delete(intakeID: intakeID, now: when)
        writer.failDeletes(with: .transient("query failed"))
        let outcomes = await worker.runOnce(now: when)

        XCTAssertTrue(outcomes.contains { if case .retryScheduled = $0 { return true } else { return false } })
        XCTAssertNotNil(try healthKitOperation(store, kind: .delete), "a delete that failed is still queued")
        XCTAssertNil(try healthKitOperation(store, kind: .delete)?.acknowledgedAt)
    }

    func testAnOperationThatIsNotDueYetIsSkipped() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        writer.failSaves(with: .transient("unavailable"))
        _ = await worker.runOnce(now: when)
        writer.failSaves(with: nil)
        writer.reset()

        let outcomes = await worker.runOnce(now: when.addingTimeInterval(30))

        XCTAssertEqual(writer.saveCalls, 0, "an operation before its next attempt is left alone")
        guard case .notDue = try XCTUnwrap(outcomes.first) else {
            return XCTFail("the run must say the operation is not due, got \(outcomes)")
        }
    }

    // MARK: - The queue around the worker

    func testOperationsForAnotherDestinationAreLeftUntouched() async throws {
        let (store, writer, _, worker) = try makeWorker(enabled: [.healthKit, .relay])

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        writer.failSaves(with: .transient("unavailable"))
        _ = await worker.runOnce(now: when)

        let relay = try XCTUnwrap(try store.pendingOutbox().first { $0.destination == .relay })
        XCTAssertNil(relay.acknowledgedAt, "another destination's delivery is not this worker's to record")
        XCTAssertEqual(relay.attempts, 0)
        XCTAssertEqual(relay.nextAttemptAt, nil)
        XCTAssertEqual(try projectionState(store, intakeID: intakeID, destination: .relay), .pending)
    }

    func testAnAcknowledgedOperationIsNotDeliveredAgain() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        _ = await worker.runOnce(now: when)
        writer.reset()

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(writer.saveCalls, 0)
        XCTAssertEqual(writer.deleted, [])
        XCTAssertTrue(outcomes.isEmpty, "an empty queue produces no outcomes")
    }

    /// The retry after a transient failure rebuilds the plan from the stored revision, so the second
    /// attempt writes exactly the specs the first one would have: an equal-version replacement, which
    /// HealthKit accepts and which changes nothing.
    func testARetryAfterATransientFailureRewritesTheSameSpecsAndThenStops() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        writer.failSaves(with: .transient("unavailable"))
        _ = await worker.runOnce(now: when)
        writer.failSaves(with: nil)
        writer.reset()

        let outcomes = await worker.runOnce(now: when.addingTimeInterval(60))
        let expected = HealthKitWritePlanner.plan(
            intakeID: intakeID, revision: 1, occurredAt: when, totals: ["water": .known(dec("250"), .mL)])

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(writer.saved, expected, "a retry rebuilds the same specs from the stored revision")
        XCTAssertEqual(writer.saved.map(\.syncVersion), [1], "an equal-version write replaces the same sample")
        XCTAssertNil(try healthKitOperation(store, kind: .upsert))

        writer.reset()
        let again = await worker.runOnce(now: when.addingTimeInterval(120))
        XCTAssertEqual(writer.saveCalls, 0, "a delivered revision is not written again")
        XCTAssertTrue(again.isEmpty)
    }

    // MARK: - The totals the app wires in

    /// The default totals source reads the revision's own snapshot rather than deciding what an entry
    /// adds up to, and treats a hand-typed entry as stating nothing.
    func testTheSnapshotTotalsReportWhatTheRevisionStatesAndWaterAsRecorded() async throws {
        let store = try makeStore(try makeDirectory())
        let oats = ProductDefinition(
            snapshotID: "snap-1", productID: "product-1", name: "Sample oats", brand: nil, barcode: nil,
            labelBasis: "per100g", catalogOrigin: "sample", catalogVersion: "1",
            nutrients: ["protein": .known(dec("13"), .g), "sodium": .unknown])
        try store.create(
            sampleIntake(),
            components: [component("oats", amount: 40, unit: .g), component("water", amount: 1, unit: .L)],
            product: oats, now: when)
        let totals = JournalSnapshotTotals(store: store)

        let recorded = await totals.totals(intakeID: intakeID, revision: 1)

        XCTAssertEqual(recorded["protein"], .known(dec("13"), .g))
        XCTAssertEqual(recorded["sodium"], .unknown, "a nutrient the product does not state is unknown, never zero")
        XCTAssertEqual(recorded["water"], .known(dec("1000"), .mL), "water is the recorded volume, converted to mL")
        XCTAssertNil(recorded["fibre"], "a key nothing states is absent rather than zero")
    }

    func testTheSnapshotTotalsOfAHandTypedRevisionStateNothingButItsVolume() async throws {
        let store = try makeStore(try makeDirectory())
        try store.create(
            sampleIntake(), components: [component("water", amount: 250, unit: .mL)], product: nil, now: when)
        let totals = JournalSnapshotTotals(store: store)

        let recorded = await totals.totals(intakeID: intakeID, revision: 1)

        XCTAssertEqual(recorded, ["water": .known(dec("250"), .mL)])
        XCTAssertEqual(await totals.totals(intakeID: intakeID, revision: 9), [:], "an unknown revision states nothing")
    }

    func testAcknowledgingAnUnknownOperationIsRefused() throws {
        let store = try makeStore(try makeDirectory())

        XCTAssertThrowsError(try store.acknowledge(operationID: "no-such-operation", at: when)) {
            XCTAssertEqual($0 as? JournalError, .unknownOperation("no-such-operation"))
        }
        XCTAssertThrowsError(try store.recordFailure(operationID: "no-such-operation", retryAt: nil, needsAttention: false)) {
            XCTAssertEqual($0 as? JournalError, .unknownOperation("no-such-operation"))
        }
    }
}
