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
    ///
    /// It can also fail, because a totals source that cannot read the revision has to be able to say
    /// so: a provider that answers "nothing" instead of failing is the bug the store-backed provider
    /// had, and the tests below need to reproduce it.
    private final class RecordingTotals: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: NutrientValue]
        private var failure: Error?
        private var calls: [(intakeID: String, revision: Int)] = []

        init(_ values: [String: NutrientValue]) {
            self.values = values
        }

        var requested: [(intakeID: String, revision: Int)] {
            lock.withLock { calls }
        }

        func set(_ values: [String: NutrientValue]) {
            lock.withLock {
                self.values = values
                self.failure = nil
            }
        }

        /// Every later read throws until `set(_:)` or `stopFailing()` clears it.
        func fail(with error: Error) {
            lock.withLock { failure = error }
        }

        func stopFailing() {
            lock.withLock { failure = nil }
        }

        func totals(intakeID: String, revision: Int) async throws -> [String: NutrientValue] {
            try lock.withLock {
                calls.append((intakeID, revision))
                if let failure { throw failure }
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
            totals: { intakeID, revision in try await recording.totals(intakeID: intakeID, revision: revision) }
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

    /// A retraction is per type: the 16 types still authorized are removed, and only the denied one
    /// keeps the operation queued. Aborting the whole retraction is what used to strand them.
    func testADeniedDeleteStillRemovesTheAuthorizedTypesAndIsLeftForAPerson() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        try store.delete(intakeID: intakeID, now: when)
        writer.deny("HKQuantityTypeIdentifierDietaryWater")
        let outcomes = await worker.runOnce(now: when)

        XCTAssertFalse(writer.deleted.contains(waterIdentifier(intakeID)), "the denied type is left alone")
        XCTAssertEqual(
            writer.deleted.count, HealthKitWritePlanner.mappings.count - 1,
            "every other mapped type is still removed")
        XCTAssertTrue(
            outcomes.contains { if case .partlyRetracted = $0 { return true } else { return false } })
        let delete = try XCTUnwrap(try healthKitOperation(store, kind: .delete))
        XCTAssertNil(delete.nextAttemptAt, "a partial retraction is not retried on a timer")
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
        let waits = (1...6).map { HealthKitDeliveryWorker.backoffSeconds(afterAttempt: $0) }

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

    /// A water-category drink reports its volume. The snapshot's own nutrients are deliberately absent:
    /// they are stated per 100 g, not for the amount recorded, so writing them unscaled would state
    /// 13 g of protein for a 40 g portion of a product whose label says 13 g per 100 g.
    func testTheSnapshotTotalsCarryAWaterDrinkAndNoUnscaledLabelValues() async throws {
        let store = try makeStore(try makeDirectory())
        let oats = ProductDefinition(
            snapshotID: "snap-1", productID: "product-1", name: "Sample oats", brand: nil, barcode: nil,
            labelBasis: "per100g", catalogOrigin: "sample", catalogVersion: "1",
            nutrients: ["protein": .known(dec("13"), .g), "sodium": .unknown])
        let drink = Intake(
            id: intakeID, category: "water", occurredAt: when, timeZoneIdentifier: "UTC", meal: "snack")
        try store.create(
            drink,
            components: [component("oats", amount: 40, unit: .g), component("water", amount: 1, unit: .L)],
            product: oats, now: when)
        let totals = JournalSnapshotTotals(store: store)

        let recorded = try await totals.totals(intakeID: intakeID, revision: 1)

        XCTAssertEqual(recorded, ["water": .known(dec("1000"), .mL)])
        XCTAssertNil(recorded["protein"], "an unscaled label value is not an intake total")
        XCTAssertNil(recorded["sodium"])
    }

    /// A revision that cannot be read throws, so the delivery is retried. Answering "nothing" instead
    /// would let the worker delete every written nutrient as stale and acknowledge an empty revision.
    func testTheSnapshotTotalsThrowForARevisionThatCannotBeRead() async throws {
        let store = try makeStore(try makeDirectory())
        try store.create(
            sampleIntake(), components: [component("water", amount: 250, unit: .mL)], product: nil, now: when)
        let totals = JournalSnapshotTotals(store: store)

        do {
            _ = try await totals.totals(intakeID: intakeID, revision: 9)
            XCTFail("an unknown revision must throw rather than state nothing")
        } catch {
            // Any error is acceptable; what matters is that one is raised.
        }
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

    // MARK: - Revision 1: an unresolved earlier operation blocks the later ones

    /// A newer revision must not be written while an older one is still unresolved. Writing revision 2
    /// first and revision 1 later would let HealthKit accept the obsolete sample: no higher-version
    /// sample protects a nutrient revision 2 dropped, so the stale value comes back.
    func testANewerRevisionIsNotDeliveredWhileAnEarlierOneIsNotDue() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        writer.failSaves(with: .transient("unavailable"))
        _ = await worker.runOnce(now: when)
        writer.failSaves(with: nil)
        // Revision 2 drops the nutrient, which is what makes the ordering observable.
        try store.edit(
            intakeID: intakeID, components: [component("water", amount: 250, unit: .mL)], product: nil,
            changeReason: "water only", now: when)
        writer.reset()

        let outcomes = await worker.runOnce(now: when.addingTimeInterval(30))

        XCTAssertEqual(writer.saveCalls, 0, "revision 1 is not due yet, so revision 2 must wait behind it")
        XCTAssertEqual(writer.deleted, [], "no stale deletion either: nothing new may be written")
        XCTAssertEqual(outcomes.count, 2, "both operations report, and the later one reports being blocked")
        guard case .blocked(_, let blockedBy) = try XCTUnwrap(outcomes.last) else {
            return XCTFail("the later revision must say it is blocked, got \(outcomes)")
        }
        let first = try XCTUnwrap(try store.pendingOutbox().first { $0.revision == 1 })
        XCTAssertEqual(blockedBy, first.operationID)
    }

    /// The same rule when the earlier operation failed outright and is waiting on its backoff.
    func testANewerRevisionIsNotDeliveredWhileAnEarlierOneFailedAndIsRetrying() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        writer.failSaves(with: .transient("unavailable"))
        _ = await worker.runOnce(now: when)
        try store.edit(
            intakeID: intakeID, components: [component("water", amount: 250, unit: .mL)], product: nil,
            changeReason: "water only", now: when)
        writer.reset()

        _ = await worker.runOnce(now: when.addingTimeInterval(120))

        XCTAssertEqual(writer.saveCalls, 0, "revision 1 failed and is on its backoff, so revision 2 waits")
        XCTAssertEqual(try store.pendingOutbox().count, 4, "both HealthKit operations stay queued")
    }

    /// Once the earlier revision is delivered, the later one follows in the same run.
    func testTheBlockedRevisionIsDeliveredOnceTheEarlierOneSucceeds() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        try store.edit(
            intakeID: intakeID, components: [component("water", amount: 250, unit: .mL)], product: nil,
            changeReason: "water only", now: when)
        writer.reset()

        _ = await worker.runOnce(now: when)

        XCTAssertEqual(writer.saved.map(\.syncVersion), [1, 2], "revisions are delivered in order")
        XCTAssertTrue(try store.pendingOutbox().allSatisfy { $0.destination == .relay })
    }

    // MARK: - Revision 2: a totals read failure must not write an empty revision

    /// A totals source that cannot read the revision has to fail the delivery. Turning that failure
    /// into empty totals would delete every previously written nutrient as stale, save nothing and
    /// acknowledge the operation — a failed read permanently recorded as a successful empty revision.
    func testAFailedTotalsReadLeavesTheOperationPendingAndWritesNothing() async throws {
        let (store, writer, totals, worker) = try makeWorker(
            totals: ["water": .known(dec("250"), .mL), "protein": .known(dec("13"), .g)])

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        _ = await worker.runOnce(now: when)
        writer.reset()
        try store.edit(
            intakeID: intakeID, components: [component()], product: nil, changeReason: "e", now: when)
        totals.fail(with: JournalError.corruptRecord("revision 2"))

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(writer.deleted, [], "nothing is deleted when the totals could not be read")
        XCTAssertEqual(writer.saveCalls, 0)
        let edit = try XCTUnwrap(try store.pendingOutbox().first { $0.revision == 2 })
        XCTAssertNil(edit.acknowledgedAt, "the operation stays queued: it was not delivered")
        XCTAssertEqual(edit.attempts, 1)
        XCTAssertNotNil(edit.nextAttemptAt, "it is retried, not abandoned")
        XCTAssertTrue(outcomes.contains { if case .retryScheduled = $0 { return true } else { return false } })
    }

    func testAFailedTotalsReadOnTheFirstRevisionIsAlsoRetriedRatherThanAcknowledged() async throws {
        let (store, writer, totals, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        totals.fail(with: JournalError.corruptRecord("revision 1"))

        _ = await worker.runOnce(now: when)

        XCTAssertEqual(writer.saveCalls, 0)
        XCTAssertNotNil(try healthKitOperation(store, kind: .upsert), "the operation is still queued")
    }

    // MARK: - Revision 3: unscaled snapshot nutrients are omitted

    /// `ProductDefinition.nutrients` is stated on `labelBasis` (typically per 100 g), not for the
    /// amount the component records, so copying it straight into totals writes the label's number as
    /// the intake's. Nothing is written until the basis can be scaled exactly.
    func testUnscaledSnapshotNutrientsAreOmittedRatherThanWrittenAsTotals() async throws {
        let store = try makeStore(try makeDirectory())
        let oats = ProductDefinition(
            snapshotID: "snap-1", productID: "product-1", name: "Sample oats", brand: nil, barcode: nil,
            labelBasis: "per100g", catalogOrigin: "sample", catalogVersion: "1",
            nutrients: ["protein": .known(dec("13"), .g)])
        try store.create(sampleIntake(), components: [component("oats", amount: 40, unit: .g)], product: oats, now: when)
        let totals = JournalSnapshotTotals(store: store)

        let recorded = try await totals.totals(intakeID: intakeID, revision: 1)

        XCTAssertNil(
            recorded["protein"],
            "40 g of a per-100 g product is 5.2 g of protein, not the 13 g the label states")
        XCTAssertEqual(recorded, [:], "nothing is stated until the label basis can be applied exactly")
    }

    // MARK: - Revision 4: a needs-attention operation is not retried automatically

    /// A denial is recorded with no retry date, which left it looking immediately due. Every later run
    /// then retried it and grew its attempt count, which is the retry storm `needsAttention` exists to
    /// prevent.
    func testANeedsAttentionOperationIsExcludedFromLaterAutomaticRuns() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        writer.deny("HKQuantityTypeIdentifierDietaryWater")
        _ = await worker.runOnce(now: when)
        let attemptsAfterDenial = try XCTUnwrap(try healthKitOperation(store, kind: .upsert)).attempts
        XCTAssertEqual(attemptsAfterDenial, 1)

        let outcomes = await worker.runOnce(now: when.addingTimeInterval(3600))

        XCTAssertEqual(try healthKitOperation(store, kind: .upsert)?.attempts, 1, "a denial is not retried")
        XCTAssertEqual(writer.saveCalls, 0)
        guard case .needsAttention(_, _) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("the operation must report that it is waiting for a person, got \(outcomes)")
        }
    }

    /// Being re-armed is a deliberate act: clearing the suspension makes the operation due again.
    func testReArmingANeedsAttentionOperationMakesItDueAgain() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        writer.deny("HKQuantityTypeIdentifierDietaryWater")
        _ = await worker.runOnce(now: when)
        writer.allow("HKQuantityTypeIdentifierDietaryWater")
        try store.rearmDelivery(operationID: try XCTUnwrap(healthKitOperation(store, kind: .upsert)).operationID)
        writer.reset()

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(writer.saved.map(\.syncIdentifier), [waterIdentifier(intakeID)])
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNil(try healthKitOperation(store, kind: .upsert))
        XCTAssertEqual(try projectionState(store, intakeID: intakeID), .succeeded)
    }

    // MARK: - Revision 5: the backoff counts the failure being handled

    func testRepeatedFailuresFollowTheOneFiveThirtyMinuteBackoff() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        writer.failSaves(with: .transient("unavailable"))
        var now = when
        var waits: [TimeInterval] = []
        for _ in 1...3 {
            _ = await worker.runOnce(now: now)
            let operation = try XCTUnwrap(try healthKitOperation(store, kind: .upsert))
            let next = try XCTUnwrap(operation.nextAttemptAt)
            waits.append(next.timeIntervalSince(now))
            now = next
        }

        XCTAssertEqual(waits, [60, 300, 1800], "the 5 minute step starts at the second failure")
    }

    // MARK: - Revision 6: a retraction deletes what it may and reports the rest

    /// Denying one type must not strand the samples this app is authorized to delete: the authorized
    /// water sample would otherwise stay in Health after the journal entry was deleted.
    func testRetractionDeletesAuthorizedTypesEvenWhenAnotherMappedTypeIsDenied() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        try store.delete(intakeID: intakeID, now: when)
        writer.deny("HKQuantityTypeIdentifierDietaryProtein")
        let deleteID = try XCTUnwrap(healthKitOperation(store, kind: .delete)?.operationID)

        let outcomes = await worker.runOnce(now: when)

        XCTAssertTrue(
            writer.deleted.contains(waterIdentifier(intakeID)),
            "the water sample this app may delete has to go")
        XCTAssertFalse(writer.deleted.contains(proteinIdentifier(intakeID)), "the denied type is left alone")
        guard case .partlyRetracted(let operationID, _, let denied) = try XCTUnwrap(
            outcomes.first { if case .partlyRetracted = $0 { return true } else { return false } }
        ) else {
            return XCTFail("a partial retraction must be reported, got \(outcomes)")
        }
        XCTAssertEqual(operationID, deleteID)
        XCTAssertEqual(denied, ["HKQuantityTypeIdentifierDietaryProtein"], "the denied type is named")
        XCTAssertNotNil(
            try healthKitOperation(store, kind: .delete),
            "the delete stays queued until the denied samples can be removed too")
        XCTAssertEqual(try projectionState(store, intakeID: intakeID), .needsAttention)
    }

    // MARK: - Revision 7: only water-category intakes contribute water

    /// Volume is water only when the entry is a drink. 250 mL of milk, juice or oil is not dietary
    /// water, and writing it as such would put a wrong number into Health.
    func testVolumeFromANonWaterIntakeIsNotCountedAsWater() async throws {
        let store = try makeStore(try makeDirectory())
        let juice = Intake(
            id: intakeID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "lunch")
        try store.create(
            juice, components: [component("milk", amount: 250, unit: .mL)], product: nil, now: when)
        let totals = JournalSnapshotTotals(store: store)

        let recorded = try await totals.totals(intakeID: intakeID, revision: 1)

        XCTAssertNil(recorded["water"], "a food measured in millilitres is not dietary water")
        XCTAssertEqual(recorded, [:])
    }

    func testVolumeFromAWaterIntakeIsCountedAsWater() async throws {
        let store = try makeStore(try makeDirectory())
        let drink = Intake(
            id: intakeID, category: "water", occurredAt: when, timeZoneIdentifier: "UTC", meal: "snack")
        try store.create(
            drink, components: [component("water", amount: 1, unit: .L)], product: nil, now: when)
        let totals = JournalSnapshotTotals(store: store)

        let recorded = try await totals.totals(intakeID: intakeID, revision: 1)

        XCTAssertEqual(recorded, ["water": .known(dec("1000"), .mL)])
    }

    // MARK: - Revision 8: a projection update matches the operation's action

    /// Deleting an intake does not bump its revision, so the queued upsert and delete share an intake,
    /// a revision and a destination and differ only by action. Matching without the action marks the
    /// delete `succeeded` while its samples are still in Health.
    /// What the store actually guarantees here is narrow, and this asserts exactly that.
    ///
    /// Deleting an intake supersedes the earlier projections, so by the time the stale upsert is
    /// acknowledged its projection is no longer current — and `setProjectionState` deliberately updates
    /// only current projections, so it is left as it was. The guarantee that matters is the negative
    /// one: the pending **delete** projection must not be marked `succeeded`, which is what the
    /// action-less match used to do.
    func testAcknowledgingAStaleUpsertLeavesTheDeleteProjectionPending() throws {
        let store = try makeStore(try makeDirectory())

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        try store.delete(intakeID: intakeID, now: when)
        let upsertID = try XCTUnwrap(healthKitOperation(store, kind: .upsert)?.operationID)

        try store.acknowledge(operationID: upsertID, at: when)

        let projections = try store.projections(of: intakeID)
        let upsertProjection = try XCTUnwrap(projections.first {
            $0.destination == .healthKit && $0.desiredAction == .upsert
        })
        let deleteProjection = try XCTUnwrap(projections.first {
            $0.destination == .healthKit && $0.desiredAction == .delete
        })
        XCTAssertFalse(upsertProjection.isCurrent, "deleting supersedes the upsert projection")
        XCTAssertEqual(
            upsertProjection.state, .pending,
            "a superseded projection is left as it is; only current ones are updated")
        XCTAssertEqual(
            deleteProjection.state, .pending,
            "the retraction is not delivered, so its projection must not claim it was")
        XCTAssertTrue(deleteProjection.isCurrent)
    }

    /// The same separation the other way round: acknowledging the delete must not mark the upsert.
    func testAcknowledgingTheDeleteLeavesTheUpsertProjectionPending() throws {
        let store = try makeStore(try makeDirectory())

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        try store.delete(intakeID: intakeID, now: when)
        let deleteID = try XCTUnwrap(healthKitOperation(store, kind: .delete)?.operationID)

        try store.acknowledge(operationID: deleteID, at: when)

        let projections = try store.projections(of: intakeID)
        XCTAssertEqual(
            try XCTUnwrap(projections.first { $0.destination == .healthKit && $0.desiredAction == .delete }).state,
            .succeeded)
        XCTAssertEqual(
            try XCTUnwrap(projections.first { $0.destination == .healthKit && $0.desiredAction == .upsert }).state,
            .pending)
    }

    // MARK: - A failed acknowledgement is unresolved

    /// The samples reached HealthKit but the journal could not record it, so the operation is still
    /// queued. Reporting that as delivered would let this run go on to a newer revision for the same
    /// intake; the next run would then redeliver the older one, and if the newer revision dropped a
    /// nutrient, the stale-sample deletion has left no higher-version sample to protect it.
    func testAFailedAcknowledgementLeavesTheOperationPendingAndBlocksLaterRevisions() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        try store.edit(
            intakeID: intakeID, components: [component("water", amount: 250, unit: .mL)], product: nil,
            changeReason: "water only", now: when)
        // The next commit fails inside the store: the write to HealthKit has already happened by then.
        store.failNextSaveForTesting = true

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(writer.saveCalls, 1, "revision 1 reached HealthKit")
        XCTAssertEqual(
            writer.saved.map(\.syncVersion), [1],
            "revision 2 must not be delivered behind an unacknowledged revision 1")
        let queued = try XCTUnwrap(try healthKitOperation(store, kind: .upsert))
        XCTAssertEqual(queued.revision, 1, "revision 1 is still queued: its delivery was never recorded")
        XCTAssertNil(queued.acknowledgedAt)
        XCTAssertEqual(outcomes.count, 2, "both operations report, and the second reports being blocked")
        guard case .blocked(_, let blockedBy) = try XCTUnwrap(outcomes.last) else {
            return XCTFail("the newer revision must report being blocked, got \(outcomes)")
        }
        XCTAssertEqual(blockedBy, try XCTUnwrap(healthKitOperation(store, kind: .upsert)?.operationID))
    }

    /// The queue is left consistent rather than lost: the undelivered revision is still there and is
    /// picked up once the store can write again.
    func testTheUnacknowledgedRevisionIsDeliveredAgainOnALaterRun() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        // Read before the second run: a delivered operation leaves the queue, so its id has to be
        // captured while it is still there.
        let operationID = try XCTUnwrap(healthKitOperation(store, kind: .upsert)?.operationID)
        store.failNextSaveForTesting = true
        _ = await worker.runOnce(now: when)
        writer.reset()

        let outcomes = await worker.runOnce(now: when.addingTimeInterval(60))

        XCTAssertEqual(writer.saved.map(\.syncVersion), [1], "the undelivered revision is written again")
        XCTAssertEqual(outcomes, [.delivered(operationID: operationID, samples: 1)])
        XCTAssertNil(try healthKitOperation(store, kind: .upsert), "and it leaves the queue this time")
    }

    // MARK: - Suspension survives a later edit

    /// An edit supersedes the denied revision's projection but leaves its operation pending. The
    /// suspension belongs to the operation, so filtering on the current projection would lose it, retry
    /// the denied write on every run and block the newer revision forever.
    func testADeniedRevisionStaysSuspendedAfterALaterEditSupersedesItsProjection() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        writer.deny("HKQuantityTypeIdentifierDietaryWater")
        _ = await worker.runOnce(now: when)
        let deniedID = try XCTUnwrap(healthKitOperation(store, kind: .upsert)?.operationID)

        try store.edit(
            intakeID: intakeID, components: [component()], product: nil, changeReason: "second try", now: when)
        writer.reset()

        let outcomes = await worker.runOnce(now: when.addingTimeInterval(3600))

        XCTAssertEqual(
            try store.pendingOutbox().first { $0.operationID == deniedID }?.attempts, 1,
            "the denied revision is not retried after its projection is superseded")
        XCTAssertEqual(writer.saveCalls, 0)
        guard case .needsAttention(let operationID, _) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("the suspended revision must still report needsAttention, got \(outcomes)")
        }
        XCTAssertEqual(operationID, deniedID)
        guard case .blocked(_, let blockedBy) = try XCTUnwrap(outcomes.last) else {
            return XCTFail("the newer revision stays blocked behind the suspended one, got \(outcomes)")
        }
        XCTAssertEqual(blockedBy, deniedID)
    }

    /// The newer revision is still delivered once the older suspended one is re-armed and delivered,
    /// which is what makes the suspension recoverable rather than a dead end.
    func testTheRevisionBehindASuspensionIsDeliveredAfterReArming() async throws {
        let (store, writer, _, worker) = try makeWorker()

        try store.create(sampleIntake(), components: [component()], product: nil, now: when)
        writer.deny("HKQuantityTypeIdentifierDietaryWater")
        _ = await worker.runOnce(now: when)
        try store.edit(
            intakeID: intakeID, components: [component()], product: nil, changeReason: "second try", now: when)
        writer.allow("HKQuantityTypeIdentifierDietaryWater")
        try store.rearmDelivery(operationID: try XCTUnwrap(healthKitOperation(store, kind: .upsert)?.operationID))
        writer.reset()

        _ = await worker.runOnce(now: when.addingTimeInterval(3600))

        XCTAssertEqual(
            writer.saved.map(\.syncVersion), [1, 2],
            "re-arming releases the older revision, and the newer one follows it")
        XCTAssertTrue(try store.pendingOutbox().allSatisfy { $0.destination == .relay })
    }
}
