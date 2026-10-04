import Foundation
import NutritionDomain
import SwiftData
import XCTest
@testable import NutritionJournal

/// The relay delivery worker (NC-09C): what it does with the queue the journal writes, on a real store on
/// disk and against a fake transport.
///
/// Every value here is synthetic, and **nothing in this file talks to a receiver.** The transport is a
/// fake that records the batches it was handed and answers whatever the test tells it to, so the delivery
/// rules are checked without a network and without an intake token that means anything.
final class RelayDeliveryWorkerTests: XCTestCase {
    private let intakeID = "0b6f7d3e-5a1c-4c52-9a2e-3f1d8c7b6a10"
    private let otherIntakeID = "3c9a1f52-7d84-4b6e-9a10-2b5e6f8c9d31"
    private let thirdIntakeID = "8e4b2d17-9c05-4a3f-b6d2-1f7a4c8e0b52"
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private static let scope = IntakeContextProducerScope(
        producerID: "nutrition-app",
        writerBundleID: "com.example.healthrelay.nutrition",
        installationID: "507b8fbb-78d3-450c-a88f-487e90df92e6")

    // MARK: - The fake transport

    /// A transport that answers from a script and records what it was asked to send.
    ///
    /// It reads the `operation_id` of every operation in each batch it receives rather than being told
    /// what to expect, so a test asserts against what was actually encoded: a batch that packed the wrong
    /// operations, or sent them in the wrong order, cannot pass by naming the right ids up front.
    final class FakeIntakeContextTransport: IntakeContextTransport, @unchecked Sendable {
        /// One scripted answer.
        ///
        /// `results` gives one result per operation in the order the batch sent them, and the last entry
        /// repeats if a batch carries more; `resultsByOperation` answers by delivery identity instead, which
        /// is what a test needs when one operation of a batch should fail and the rest succeed.
        struct ScriptedResponse {
            var statusCode: Int = 200
            var retryAfterSeconds: Int?
            var error: String?
            var results: [RelayOperationResult]?
            var detail: String?
            var resultsByOperation: [String: RelayOperationResult]?
        }

        private let lock = NSLock()
        private var scripted: [ScriptedResponse] = []
        private var recordedBatches: [Data] = []
        private var recordedTokens: [String] = []
        private var capabilitiesReads = 0
        private var capabilitiesAnswer: IntakeContextCapabilities
        private var capabilitiesFailure: Error?
        private var sendFailure: Error?
        /// The answer used once the script runs out, so a test only scripts the calls it cares about.
        private var defaultResponse = ScriptedResponse(results: [.accepted])

        init(capabilities: IntakeContextCapabilities) {
            self.capabilitiesAnswer = capabilities
        }

        // MARK: What the test drives

        func answer(_ response: ScriptedResponse) {
            lock.withLock { scripted.append(response) }
        }

        /// Every later batch is answered `accepted`.
        func answerEverythingAccepted() {
            answer(ScriptedResponse(results: [.accepted]))
        }

        func failCapabilities(with error: Error) {
            lock.withLock { capabilitiesFailure = error }
        }

        func failSends(with error: Error) {
            lock.withLock { sendFailure = error }
        }

        

        /// Clears what has been recorded, so a second run in the same test is measured on its own. The
        /// script and any armed failure are left alone: a test that wants the next send to succeed says so.
        func reset() {
            lock.withLock {
                recordedBatches = []
                recordedTokens = []
                capabilitiesReads = 0
            }
        }

        // MARK: What the test reads

        /// Every batch handed to `send`, in call order.
        var sentBatches: [Data] { lock.withLock { recordedBatches } }

        /// The `operation_id`s of every batch, flattened in the order they were sent, so a test can assert
        /// on what went out without caring how it was packed.
        var sentOperationIDs: [String] {
            sentBatches.flatMap { Self.operationIDs(in: $0) }
        }

        var sentTokens: [String] { lock.withLock { recordedTokens } }
        var capabilitiesCallCount: Int { lock.withLock { capabilitiesReads } }
        var sendCallCount: Int { lock.withLock { recordedBatches.count } }

        // MARK: The transport itself

        func capabilities() async throws -> IntakeContextCapabilities {
            try lock.withLock {
                capabilitiesReads += 1
                if let capabilitiesFailure { throw capabilitiesFailure }
                return capabilitiesAnswer
            }
        }

        func send(batch: Data, token: String) async throws -> IntakeContextTransportResponse {
            let (response, ids) = try lock.withLock { () throws -> (ScriptedResponse, [String]) in
                recordedBatches.append(batch)
                recordedTokens.append(token)
                if let sendFailure { throw sendFailure }
                let next = scripted.isEmpty ? defaultResponse : scripted.removeFirst()
                return (next, Self.operationIDs(in: batch))
            }
            guard response.statusCode == 200, response.results != nil || response.resultsByOperation != nil
            else {
                return IntakeContextTransportResponse(
                    statusCode: response.statusCode, retryAfterSeconds: response.retryAfterSeconds,
                    body: Self.errorBody(response.error))
            }
            return IntakeContextTransportResponse(
                statusCode: response.statusCode, retryAfterSeconds: response.retryAfterSeconds,
                body: Self.resultsBody(
                    operationIDs: ids, results: response.results, resultsByOperation: response.resultsByOperation,
                    detail: response.detail))
        }

        /// The operations a batch carried, in the order it sent them.
        static func operationIDs(in batch: Data) -> [String] {
            guard let payload = try? IntakeContextJSONReader.read(batch),
                  let operations = payload.array("operations")
            else { return [] }
            return operations.compactMap { $0.string("operation_id") }
        }

        /// A reply the shape the receiver documents: one `results` entry per operation, in the order the
        /// batch sent them, with the members that result actually carries.
        static func resultsBody(
            operationIDs: [String],
            results: [RelayOperationResult]?,
            resultsByOperation: [String: RelayOperationResult]?,
            detail: String?
        ) -> Data {
            var entries: [String] = []
            for (position, operationID) in operationIDs.enumerated() {
                let answer = resultsByOperation?[operationID]
                    ?? results?[min(position, max((results?.count ?? 1) - 1, 0))]
                    ?? .accepted
                var members = [
                    "\"operation_id\": \"\(operationID)\"",
                    "\"result\": \"\(answer.rawValue)\"",
                ]
                // Only the members this result actually carries, as the receiver states them: an accepted
                // revision and a cursor for an accepted operation, and the revision it superseded for a
                // stale one. A test that asserted on a member the result never carries would be asserting
                // on the fake, not on the mapping.
                switch answer {
                case .accepted, .duplicate:
                    members.append("\"accepted_revision\": \(position + 1)")
                    members.append("\"server_cursor\": \(41 + position)")
                case .staleRevision:
                    members.append("\"current_revision\": 4")
                case .domainConflict, .projectionConflict, .retryableFailure, .permanentFailure:
                    break
                }
                if let detail { members.append("\"detail\": \"\(detail)\"") }
                entries.append("{" + members.joined(separator: ", ") + "}")
            }
            let document = "{\"results\": [" + entries.joined(separator: ", ") + "]}"
            return Data(document.utf8)
        }

        static func errorBody(_ error: String?) -> Data {
            guard let error else { return Data() }
            return Data("{\"error\": \"\(error)\"}".utf8)
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

    private var encoder: IntakeContextEncoder { IntakeContextEncoder(scope: Self.scope) }

    private func sampleIntake(id: String? = nil) -> Intake {
        Intake(
            id: id ?? intakeID, category: "beverage", occurredAt: when, timeZoneIdentifier: "UTC",
            meal: "lunch")
    }

    private func components() -> [IntakeComponent] {
        [IntakeComponent(componentID: "water", name: "Water", amount: dec("500"), unit: .mL)]
    }

    /// A worker over a store and a transport. Nothing queues link projections, so a run built here sends
    /// upserts and deletes only.
    private func makeWorker(
        store: SwiftDataJournalStore,
        transport: FakeIntakeContextTransport,
        projections: (any RelayLinkProjectionQueue)? = nil
    ) -> RelayDeliveryWorker {
        RelayDeliveryWorker(
            store: store, transport: transport, encoder: encoder, token: "synthetic-test-token",
            projections: projections ?? RelayLinkProjectionQueueNone())
    }

    /// A store, a fake transport and a worker over them.
    private func makeWorker(
        enabled: Set<JournalDestination> = [.healthKit, .relay],
        capabilities: IntakeContextCapabilities? = nil
    ) throws -> (store: SwiftDataJournalStore, transport: FakeIntakeContextTransport, worker: RelayDeliveryWorker) {
        let store = try makeStore(try makeDirectory(), enabled: enabled)
        let transport = FakeIntakeContextTransport(capabilities: capabilities ?? Self.capabilities())
        return (store, transport, makeWorker(store: store, transport: transport))
    }

    /// The receiver's limits, generous by default so a test only overrides the one it is about.
    static func capabilities(
        maxOperations: Int = 32, maxBodyBytes: Int = 262_144
    ) -> IntakeContextCapabilities {
        IntakeContextCapabilities(
            schema: IntakeContextEncoder.schema,
            supportedVersions: [IntakeContextEncoder.schemaVersion],
            maxBodyBytes: maxBodyBytes,
            maxOperations: maxOperations,
            authentication: IntakeContextAuthentication(scheme: "bearer", header: "Authorization", tokenType: "intake"))
    }

    private func relayOperation(
        _ store: SwiftDataJournalStore, intakeID: String? = nil, kind: OutboxKind? = nil
    ) throws -> OutboxOperation? {
        try store.pendingOutbox().first {
            $0.destination == .relay && (intakeID == nil || $0.intakeID == intakeID) && (kind == nil || $0.kind == kind)
        }
    }

    private func projectionState(
        _ store: SwiftDataJournalStore, intakeID: String
    ) throws -> DestinationState? {
        try store.projections(of: intakeID).first { $0.destination == .relay && $0.isCurrent }?.state
    }

    private func pendingRelay(_ store: SwiftDataJournalStore, intakeID: String? = nil) throws -> [OutboxOperation] {
        try store.pendingOutbox().filter { $0.destination == .relay && (intakeID == nil || $0.intakeID == intakeID) }
    }

    // MARK: - The outcome table

    /// `accepted` is the receiver taking the operation: the row leaves the queue and the projection
    /// succeeds, and the accepted revision and cursor it reported are handed back rather than dropped.
    func testAcceptedIsDeliveredAcknowledgedAndReportedWithTheRevisionsTheReceiverNamed() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        let operationID = try XCTUnwrap(relayOperation(store)?.operationID)
        transport.answerEverythingAccepted()

        let outcomes = await worker.runOnce(now: when)

        guard case .delivered(let id, let revision, let cursor) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("accepted is delivered, got \(outcomes)")
        }
        XCTAssertEqual(id, operationID)
        XCTAssertEqual(revision, 1, "the receiver named the revision it now holds")
        XCTAssertEqual(try pendingRelay(store), [], "an acknowledged operation leaves the queue")
        XCTAssertEqual(cursor, 41, "the receiver's cursor is handed back, not dropped")
        XCTAssertEqual(transport.sentTokens, ["synthetic-test-token"], "the token is passed per call")
    }

    /// A retry after a lost response is a `duplicate`, and it is a success: the receiver holds the
    /// operation exactly once however many times it is delivered.
    func testADuplicateIsAlsoDeliveredSoTheOperationLeavesTheQueue() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        transport.answer(.init(results: [.duplicate], detail: "already held"))
        // Read the queued operation before the run: once delivered it leaves the queue.
        let queuedID = try XCTUnwrap(relayOperation(store)?.operationID)

        let outcomes = await worker.runOnce(now: when)

        guard case .delivered(let id, _, _) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("a duplicate is a success, got \(outcomes)")
        }
        XCTAssertEqual(id, queuedID)
        XCTAssertEqual(try pendingRelay(store), [])
        XCTAssertEqual(try projectionState(store, intakeID: intakeID), .succeeded)
    }

    /// `stale_revision` means the receiver already holds a newer revision, so the queued operation is
    /// finished with: acknowledged, not retried.
    func testAStaleRevisionIsAcknowledgedAsSupersededRatherThanRetried() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        transport.answer(.init(
            results: [.staleRevision], detail: "revision 4 is already accepted"))

        let outcomes = await worker.runOnce(now: when)

        guard case .superseded = try XCTUnwrap(outcomes.first) else {
            return XCTFail("a stale revision is finished with, got \(outcomes)")
        }
        XCTAssertEqual(try pendingRelay(store), [], "there is nothing to retry")
        XCTAssertEqual(try projectionState(store, intakeID: intakeID), .succeeded)
    }

    /// A domain conflict needs a person: both sides are durable records of the same facts, so no number of
    /// retries settles it, and the operation must not sit on the backoff forever.
    func testADomainConflictNeedsAttentionAndSchedulesNoRetry() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        transport.answer(.init(
            results: [.domainConflict], detail: "the receiver holds different facts"))

        let outcomes = await worker.runOnce(now: when)

        guard case .needsAttention(let id, let reason) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("a conflict must ask for a person, got \(outcomes)")
        }
        XCTAssertTrue(reason.contains("domain conflict"), "the reason names the receiver's answer: \(reason)")
        let operation = try XCTUnwrap(try pendingRelay(store).first { $0.operationID == id })
        XCTAssertEqual(operation.attempts, 1)
        XCTAssertNil(operation.nextAttemptAt, "retrying cannot settle a conflict")
        XCTAssertEqual(try projectionState(store, intakeID: intakeID), .needsAttention)
        XCTAssertEqual(try store.suspensionReason(operationID: id), reason, "the reason is stored, not rebuilt")
    }

    /// A projection conflict is parked for the same reason and with the same stored reason.
    func testAProjectionConflictNeedsAttentionAndNamesTheReceiver() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        transport.answer(.init(
            results: [.projectionConflict], detail: "links disagree"))

        let outcomes = await worker.runOnce(now: when)

        guard case .needsAttention(_, let reason) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("a projection conflict must ask for a person, got \(outcomes)")
        }
        XCTAssertTrue(reason.contains("projection conflict"), reason)
        XCTAssertEqual(try projectionState(store, intakeID: intakeID), .needsAttention)
    }

    /// `permanent_failure` is the receiver refusing the payload itself, so it is parked like a conflict:
    /// the same bytes are refused again on every attempt.
    func testAPermanentFailureResultIsParkedRatherThanRetried() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        transport.answer(.init(
            results: [.permanentFailure], detail: "the label is not accepted"))

        let outcomes = await worker.runOnce(now: when)

        guard case .needsAttention(let id, let reason) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("a permanent failure must not be retried, got \(outcomes)")
        }
        XCTAssertTrue(reason.contains("permanent failure"), reason)
        XCTAssertNil(try XCTUnwrap(try pendingRelay(store).first { $0.operationID == id }).nextAttemptAt)
    }

    /// `retryable_failure` is the receiver's own word for "send the same bytes again", so the operation goes
    /// back on the backoff rather than being parked.
    func testARetryableFailureResultSchedulesABackoff() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        transport.answer(.init(
            results: [.retryableFailure], detail: "try later"))

        let outcomes = await worker.runOnce(now: when)

        guard case .retryScheduled(let id, let next, _) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("a retryable failure is worth another attempt, got \(outcomes)")
        }
        XCTAssertEqual(next, when.addingTimeInterval(60), "the first failure waits a minute")
        XCTAssertEqual(try XCTUnwrap(try pendingRelay(store).first { $0.operationID == id }).nextAttemptAt, next)
        XCTAssertEqual(try projectionState(store, intakeID: intakeID), .pending)
    }

    /// A 200 that omits a result leaves the journal unable to say whether the receiver holds the operation,
    /// so the outcome is unresolved and the revisions behind it are held back rather than released.
    func testA200ThatNamesNoResultForAnOperationIsNotAcknowledged() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        // A 200 whose body carries no `results` array at all.
        transport.answer(.init(
            statusCode: 200))

        let outcomes = await worker.runOnce(now: when)

        guard case .notAcknowledged = try XCTUnwrap(outcomes.first) else {
            return XCTFail("an unrecorded delivery is unresolved, got \(outcomes)")
        }
        XCTAssertEqual(try pendingRelay(store).count, 1, "the operation is still queued")
    }

    // MARK: - HTTP statuses

    /// A 429 with a `Retry-After` is the receiver stating how long to stop, so that is the wait — not the
    /// backoff, which is this module's guess about a receiver it knows nothing about.
    func testARateLimitedBatchWaitsForTheReceiversRetryAfter() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        transport.answer(.init(
            statusCode: 429, retryAfterSeconds: 90))

        let outcomes = await worker.runOnce(now: when)

        guard case .retryScheduled(let id, let next, let reason) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("a rate limit is a retry, got \(outcomes)")
        }
        XCTAssertEqual(next, when.addingTimeInterval(90), "the receiver's Retry-After is the wait")
        XCTAssertTrue(reason.contains("90"), reason)
        XCTAssertEqual(try XCTUnwrap(try pendingRelay(store).first { $0.operationID == id }).nextAttemptAt, next)
    }

    /// A 429 with no `Retry-After` falls back to the backoff, so the operation still gets a longer wait than
    /// the last failure did.
    func testARateLimitWithoutARetryAfterFallsBackToTheBackoff() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        transport.answer(.init(
            statusCode: 429))

        let outcomes = await worker.runOnce(now: when)

        guard case .retryScheduled(_, let next, _) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("a rate limit is a retry, got \(outcomes)")
        }
        XCTAssertEqual(next, when.addingTimeInterval(60))
    }

    /// A 401 stops the run: every later batch would be refused the same way, so one cause is reported
    /// rather than one refusal per batch, and the operations are parked until someone re-arms them.
    func testA401StopsTheRunParksTheOperationsAndReportsTheRestAsUnattempted() async throws {
        // One operation per batch, so there is a later batch for the stop to prevent.
        let (store, transport, worker) = try makeWorker(capabilities: Self.capabilities(maxOperations: 1))
        try store.create(sampleIntake(id: intakeID), components: components(), product: nil, now: when)
        try store.create(sampleIntake(id: otherIntakeID), components: components(), product: nil, now: when)
        try store.create(sampleIntake(id: thirdIntakeID), components: components(), product: nil, now: when)
        transport.answer(.init(statusCode: 401))

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 1, "the run stops after the first refused batch")
        let rejected = outcomes.compactMap { outcome -> RelayDeliveryOutcome? in
            guard case .needsAttention(_, let reason) = outcome, reason.contains("token") else { return nil }
            return outcome
        }
        XCTAssertEqual(rejected.count, 1, "one refusal, one cause: \(outcomes)")
        XCTAssertEqual(
            outcomes.filter { if case .notAttempted = $0 { return true } else { return false } }.count, 2)
        let attempted = try XCTUnwrap(
            outcomes.compactMap { outcome -> String? in
                guard case .needsAttention(let id, _) = outcome else { return nil }
                return id
            }.first)
        let operation = try XCTUnwrap(try pendingRelay(store).first { $0.operationID == attempted })
        XCTAssertEqual(operation.attempts, 1)
        XCTAssertNil(operation.nextAttemptAt, "a refused token is not retried until it is re-armed")
    }

    /// A rejected token is parked, so the next run sends nothing and says why.
    func testAParkedTokenIsNotSentAgainOnTheNextRun() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        transport.answer(.init(
            statusCode: 401))
        _ = await worker.runOnce(now: when)
        transport.reset()

        let outcomes = await worker.runOnce(now: when.addingTimeInterval(86_400))

        XCTAssertEqual(transport.sendCallCount, 0, "a refused token is not worth another attempt")
        guard case .needsAttention(_, let reason) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("the parked reason is reported again, got \(outcomes)")
        }
        XCTAssertTrue(reason.contains("token"), reason)
    }

    /// A 403 and a 400 are permanent for the operations of that batch: the payload or the producer binding
    /// is refused, so the same bytes are refused on every attempt.
    func testA403IsPermanentForThoseOperations() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        transport.answer(.init(
            statusCode: 403, error: "producer_mismatch"))

        let outcomes = await worker.runOnce(now: when)

        guard case .needsAttention(_, let reason) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("a refused producer binding is permanent, got \(outcomes)")
        }
        XCTAssertEqual(reason, "producer_mismatch", "the receiver's own error code is the reason")
        XCTAssertEqual(try projectionState(store, intakeID: intakeID), .needsAttention)
    }

    func testA400IsPermanentForThoseOperations() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        transport.answer(.init(
            statusCode: 400, error: "invalid_batch"))

        let outcomes = await worker.runOnce(now: when)

        guard case .needsAttention(_, let reason) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("an invalid batch is permanent, got \(outcomes)")
        }
        XCTAssertEqual(reason, "invalid_batch")
    }

    /// A 5xx is transient: the same bytes are worth sending again on the backoff.
    func testAServerErrorSchedulesTheBackoff() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        transport.answer(.init(
            statusCode: 500))

        let outcomes = await worker.runOnce(now: when)

        guard case .retryScheduled(_, let next, let reason) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("a 500 is worth another attempt, got \(outcomes)")
        }
        XCTAssertEqual(next, when.addingTimeInterval(60))
        XCTAssertTrue(reason.contains("500"), reason)
    }

    /// A transport error is a failure with no status, which is transient by definition.
    func testATransportErrorSchedulesTheBackoff() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        transport.failSends(with: URLError(.notConnectedToInternet))

        let outcomes = await worker.runOnce(now: when)

        guard case .retryScheduled(_, let next, _) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("a transport error is transient, got \(outcomes)")
        }
        XCTAssertEqual(next, when.addingTimeInterval(60))
        XCTAssertEqual(try pendingRelay(store).count, 1)
    }

    // MARK: - Batches

    /// The receiver's `max_operations` is the number of operations one batch may carry, so a run with more
    /// work than that sends more than one batch rather than relying on the receiver to refuse it.
    func testABatchCarriesNoMoreOperationsThanTheReceiverAllows() async throws {
        let (store, transport, worker) = try makeWorker(capabilities: Self.capabilities(maxOperations: 2))
        for id in [intakeID, otherIntakeID, thirdIntakeID] {
            try store.create(sampleIntake(id: id), components: components(), product: nil, now: when)
        }
        transport.answerEverythingAccepted()

        _ = await worker.runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 2, "three operations at two per batch is two batches")
        XCTAssertEqual(
            transport.sentBatches.map { FakeIntakeContextTransport.operationIDs(in: $0).count }, [2, 1])
    }

    /// `max_body_bytes` is measured on the bytes that would actually be sent, not estimated, so a run packs
    /// against the receiver's own limit.
    func testABatchIsPackedWithinTheReceiversBodyLimit() async throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(id: intakeID), components: components(), product: nil, now: when)
        try store.create(sampleIntake(id: otherIntakeID), components: components(), product: nil, now: when)
        let firstOperation = try XCTUnwrap(relayOperation(store, intakeID: intakeID))
        // The exact size of a batch carrying one of these operations, so the ceiling is the receiver's own
        // limit rather than a guess about how big an operation is.
        let oneOperationBody = try encoder.batch(
            batchID: UUID().uuidString,
            operations: [try encoder.upsert(
                intake: try XCTUnwrap(store.activeIntakes().first { $0.id == intakeID }),
                revision: try XCTUnwrap(store.revisions(of: intakeID).first),
                product: nil,
                operation: firstOperation)]
        ).canonicalBytes.count
        // A ceiling that fits one encoded operation and no more.
        let transport = FakeIntakeContextTransport(capabilities: Self.capabilities(maxBodyBytes: oneOperationBody))
        transport.answerEverythingAccepted()

        _ = await makeWorker(store: store, transport: transport).runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 2, "each batch is measured, so one operation fits per batch")
        XCTAssertEqual(
            transport.sentBatches.map { $0.count <= oneOperationBody }, [true, true],
            "no batch exceeds the receiver's body limit")
        XCTAssertEqual(
            transport.sentBatches.first.flatMap { FakeIntakeContextTransport.operationIDs(in: $0).first },
            firstOperation.operationID)
    }

    /// A 413 means the batch was too large, so it is split once and each half is retried. The split keeps
    /// the order the operations were read in, so the revisions of one intake stay in sequence.
    func testA413SplitsTheBatchOnceAndRetriesEachHalf() async throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(id: intakeID), components: components(), product: nil, now: when)
        try store.create(sampleIntake(id: otherIntakeID), components: components(), product: nil, now: when)
        try store.create(sampleIntake(id: thirdIntakeID), components: components(), product: nil, now: when)
        let ordered = try pendingRelay(store).map(\.operationID)
        let transport = FakeIntakeContextTransport(capabilities: Self.capabilities())
        // The first attempt is refused as too large; every later one is accepted.
        transport.answer(.init(
            statusCode: 413, error: "too_many_operations"))
        transport.answerEverythingAccepted()

        let outcomes = await makeWorker(store: store, transport: transport).runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 3, "one refused batch, then two halves")
        XCTAssertEqual(
            transport.sentBatches.dropFirst().flatMap { FakeIntakeContextTransport.operationIDs(in: $0) },
            ordered, "the halves keep the queue's order")
        XCTAssertEqual(outcomes.count, 3)
        XCTAssertTrue(outcomes.allSatisfy { $0.isResolved }, "every operation was delivered: \(outcomes)")
    }

    /// A single operation cannot be split, so a 413 for it is permanent: the payload itself is what the
    /// receiver refuses.
    func testA413ForOneOperationIsPermanentRatherThanRetried() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        transport.answer(.init(
            statusCode: 413, error: "body too large"))

        let outcomes = await worker.runOnce(now: when)

        guard case .needsAttention(_, let reason) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("a payload the receiver refuses is permanent, got \(outcomes)")
        }
        XCTAssertTrue(reason.contains("too large"), reason)
        XCTAssertEqual(transport.sendCallCount, 1, "there is nothing to split")
    }

    // MARK: - Ordering

    /// The revisions of one intake go out in the order the queue offers them, oldest first, and they travel
    /// together: the receiver applies a batch in array order, so a newer revision sent ahead of its
    /// predecessor would be refused as stale.
    func testTheRevisionsOfOneIntakeAreSentInOrder() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "more water",
            now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "even more",
            now: when)
        // Read the queue's own order before the run: it is oldest revision first, which is what has to be
        // preserved on the wire.
        let queuedInOrder = try pendingRelay(store, intakeID: intakeID).map(\.operationID)
        transport.answerEverythingAccepted()

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(outcomes.count, 3)
        XCTAssertTrue(outcomes.allSatisfy { $0.isResolved }, "all three revisions were delivered: \(outcomes)")
        XCTAssertEqual(transport.sentOperationIDs, queuedInOrder, "the queue's order is the wire's order")
        XCTAssertEqual(try pendingRelay(store), [])
    }

    /// A batch is one request, so the three revisions of one intake travel together in one array — which is
    /// how the receiver applies them in the order the journal recorded them.
    func testTheRevisionsOfOneIntakeTravelInOneBatchInRevisionOrder() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "more", now: when)
        transport.answerEverythingAccepted()

        _ = await worker.runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 1)
        let batch = try IntakeContextJSONReader.read(try XCTUnwrap(transport.sentBatches.first))
        let revisions = try XCTUnwrap(batch.array("operations")).compactMap { $0.integer("revision") }
        XCTAssertEqual(revisions, [1, 2], "the receiver applies the array in order, so revision 1 comes first")
    }

    /// One operation of a batch being refused does not undo the ones the receiver did accept, and the refused
    /// one holds the revisions behind it back on the next run rather than being retried past.
    func testARefusedOperationIsParkedWhileTheRestOfItsBatchIsDelivered() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "more", now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "even more",
            now: when)
        let queuedInOrder = try pendingRelay(store, intakeID: intakeID).map(\.operationID)
        transport.answer(.init(resultsByOperation: [queuedInOrder[0]: .permanentFailure]))

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 1, "the three revisions travel together")
        XCTAssertEqual(outcomes.count, 3)
        XCTAssertEqual(
            outcomes.compactMap { outcome -> String? in
                guard case .needsAttention(let id, _) = outcome else { return nil }
                return id
            },
            [queuedInOrder[0]])
        XCTAssertEqual(
            try pendingRelay(store, intakeID: intakeID).map(\.operationID), [queuedInOrder[0]],
            "only the refused operation is still queued")
        XCTAssertEqual(transport.sendCallCount, 1, "the refused operation is not retried past its successors")
    }

    /// A suspended operation holds back the revisions behind it for the same reason: it was never delivered,
    /// so nothing later for that intake may go past it.
    func testASuspendedOperationHoldsBackTheLaterRevisionsOfTheSameIntake() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "more", now: when)
        let first = try XCTUnwrap(relayOperation(store, intakeID: intakeID)?.operationID)
        try store.recordFailure(
            operationID: first, retryAt: nil, needsAttention: true, reason: "a domain conflict")
        transport.answerEverythingAccepted()

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 0, "a parked operation is not retried, and nothing goes past it")
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(
            outcomes.compactMap { outcome -> String? in
                guard case .needsAttention(let id, _) = outcome else { return nil }
                return id
            },
            [first])
    }

    /// An operation that is not due yet is not sent, and it still holds back the revisions behind it.
    func testAnOperationThatIsNotDueYetIsReportedAndBlocksWhatIsBehindIt() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "more", now: when)
        let first = try XCTUnwrap(relayOperation(store, intakeID: intakeID)?.operationID)
        try store.recordFailure(
            operationID: first, retryAt: when.addingTimeInterval(600), needsAttention: false, reason: nil)
        transport.answerEverythingAccepted()

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 0)
        guard case .notDue(let id, let due) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("an operation that is not due says when it is, got \(outcomes)")
        }
        XCTAssertEqual(id, first)
        XCTAssertEqual(due, when.addingTimeInterval(600))
        XCTAssertEqual(outcomes.count, 2)
    }

    /// HealthKit operations are another destination's business. This worker leaves them exactly as they are.
    func testOperationsForOtherDestinationsAreLeftAlone() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        transport.answerEverythingAccepted()

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(outcomes.count, 1, "the one relay operation, not the HealthKit one too")
        XCTAssertEqual(try pendingRelay(store), [])
        XCTAssertEqual(
            try store.pendingOutbox().filter { $0.destination == .healthKit }.count, 1,
            "the HealthKit operation is still queued: it is not this worker's delivery")
    }

    // MARK: - Delivery is off

    /// Nothing in the app enables the relay destination, so nothing is queued for this worker and every run
    /// finds an empty queue. A worker that reaches a receiver at all with delivery off would be a bug.
    func testNothingIsSentWhenTheRelayDestinationIsDisabled() async throws {
        let (store, transport, worker) = try makeWorker(enabled: [.healthKit])
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "more", now: when)

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(outcomes, [], "delivery is off, so there is nothing to report")
        XCTAssertEqual(transport.sendCallCount, 0)
        XCTAssertEqual(transport.capabilitiesCallCount, 0, "an empty run does not even ask the receiver")
        XCTAssertEqual(try store.pendingOutbox().filter { $0.destination == .healthKit }.count, 2)
        XCTAssertEqual(try projectionState(store, intakeID: intakeID), .disabled)
    }

    /// A delete is sent as a tombstone above the revision it retracts, and it is delivered like any other
    /// operation.
    func testADeleteIsDeliveredAsATombstone() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        try store.delete(intakeID: intakeID, now: when)
        transport.answerEverythingAccepted()

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(outcomes.count, 2, "the queued upsert and the delete")
        XCTAssertTrue(outcomes.allSatisfy { $0.isResolved }, "\(outcomes)")
        let batch = try IntakeContextJSONReader.read(try XCTUnwrap(transport.sentBatches.first))
        let operations = try XCTUnwrap(batch.array("operations"))
        XCTAssertEqual(operations.count, 1, "only the tombstone is sent")
        let tombstone = try XCTUnwrap(operations.first)
        XCTAssertEqual(tombstone.string("operation"), "delete")
        XCTAssertEqual(tombstone.integer("revision"), 2, "a tombstone stands above the revision it retracts")
        XCTAssertNotNil(tombstone.string("deleted_at"))
        XCTAssertNil(tombstone.string("facts"), "a tombstone carries no food details")
        XCTAssertEqual(try pendingRelay(store), [])
    }

    /// An upsert whose intake was deleted after it was queued is acknowledged as superseded rather than
    /// sent: the delete in the same run is what decides what the receiver holds, so sending it would put
    /// back exactly what that delete retracts.
    func testAnUpsertWhoseIntakeIsGoneIsSupersededRatherThanSent() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        try store.delete(intakeID: intakeID, now: when)
        let upsertID = try XCTUnwrap(relayOperation(store, kind: .upsert)?.operationID)
        transport.answerEverythingAccepted()

        let outcomes = await worker.runOnce(now: when)

        guard case .superseded(let id, _) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("an upsert for a deleted intake is finished with, got \(outcomes)")
        }
        XCTAssertEqual(id, upsertID)
        XCTAssertEqual(
            transport.sentOperationIDs.count, 1, "only the tombstone was sent")
        XCTAssertEqual(try pendingRelay(store), [])
    }

    /// A capabilities read that fails sends nothing: the batch limits are the receiver's own numbers, and a
    /// guess would produce the 413 this run exists to avoid.
    func testAFailedCapabilitiesReadSendsNothingAndReschedules() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        transport.failCapabilities(with: URLError(.timedOut))

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 0)
        guard case .retryScheduled(_, let next, _) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("a capabilities read that failed is worth another attempt, got \(outcomes)")
        }
        XCTAssertEqual(next, when.addingTimeInterval(60))
        XCTAssertEqual(try pendingRelay(store).count, 1)
    }

    /// A receiver that does not speak this schema version would refuse the batch while parsing it, so the
    /// run parks the operations instead of sending something the receiver cannot read.
    func testAReceiverWithoutThisSchemaVersionIsNotSentAnything() async throws {
        let capabilities = IntakeContextCapabilities(
            schema: IntakeContextEncoder.schema,
            supportedVersions: ["0.9"],
            maxBodyBytes: 262_144,
            maxOperations: 32,
            authentication: IntakeContextAuthentication(
                scheme: "bearer", header: "Authorization", tokenType: "intake"))
        let (store, transport, worker) = try makeWorker(capabilities: capabilities)
        try store.create(sampleIntake(), components: components(), product: nil, now: when)

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 0)
        guard case .needsAttention(_, let reason) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("an unreadable version is not a delivery attempt, got \(outcomes)")
        }
        XCTAssertTrue(reason.contains("1.0"), reason)
    }
}