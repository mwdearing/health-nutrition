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
    private let fourthIntakeID = "5d91c7a4-2e68-4b03-9f27-6a8e1b4d0c93"
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
        /// Asked, while the batch is in hand and before any answer is produced, what the journal holds for
        /// each operation it carries.
        private var observer: ((_ operationIDs: [String]) -> Void)?
        /// What the observer saw, one entry per batch received, keyed by nothing: a flat log of
        /// `operationID -> links recorded at the moment the batch was received`.
        private var observed: [[String: Bool]] = []

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

        /// Reads the journal's recorded link snapshot for each operation of every batch received.
        ///
        /// Asked from inside `send(batch:token:)`, so what it sees is the state at the moment the batch was
        /// handed over: a snapshot written after the answer would not be there yet, which is exactly what a
        /// test asserting "recorded before the request" needs to be able to tell apart.
        func observeRecords(of store: SwiftDataJournalStore) {
            lock.withLock {
                observer = { [weak self] operationIDs in
                    var seen: [String: Bool] = [:]
                    for id in operationIDs {
                        // `recordedLinks` both throws and returns an optional, so `try?` gives a double
                        // optional; flattening it leaves nil both when the read fails and when nothing is
                        // recorded, and either way there is no snapshot on record.
                        let recorded = (try? store.recordedLinks(operationID: id)) ?? nil
                        seen[id] = recorded != nil
                    }
                    self?.lock.withLock { self?.observed.append(seen) }
                }
            }
        }

        /// For each batch received, whether each operation's snapshot was already on record.
        var recordsAtSendTime: [[String: Bool]] { lock.withLock { observed } }

        

        /// Clears what has been recorded, so a second run in the same test is measured on its own. The
        /// script and any armed failure are left alone: a test that wants the next send to succeed says so.
        func reset() {
            lock.withLock {
                recordedBatches = []
                recordedTokens = []
                capabilitiesReads = 0
                observed = []
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
            let ids = Self.operationIDs(in: batch)
            // Everything read from the shared state is read under the lock, and the observer is taken out with
            // it so it can be called afterwards without holding the lock: it reads the store, and holding the
            // lock across that would serialise the run behind it for no reason.
            let (observer, failure, next) = lock.withLock {
                () -> (((_ operationIDs: [String]) -> Void)?, Error?, ScriptedResponse) in
                recordedBatches.append(batch)
                recordedTokens.append(token)
                // A failed send throws without consuming a scripted answer, so a test that arms both a
                // failure and a script sees the script on the next call rather than losing it to the failure.
                if let sendFailure { return (self.observer, sendFailure, defaultResponse) }
                return (self.observer, nil, scripted.isEmpty ? defaultResponse : scripted.removeFirst())
            }
            if let failure { throw failure }
            // Asked before the answer is built, so the journal is read exactly as it stands for this request.
            observer?(ids)
            let response = next
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
        projections: (any RelayLinkProjectionQueue)? = nil,
        token: @escaping RelayTokenProvider = { "synthetic-test-token" },
        links: @escaping RelayLinkProvider = { _, _ in [] }
    ) -> RelayDeliveryWorker {
        RelayDeliveryWorker(
            store: store, transport: transport, encoder: encoder, token: token,
            projections: projections ?? RelayLinkProjectionQueueNone(), links: links)
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
    /// receiver refuses, and no smaller request exists.
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
        XCTAssertEqual(transport.sendCallCount, 1, "there is nothing left to split")
    }

    /// The split keeps going until there is nothing left to split, because how large one operation is on its
    /// own is not knowable here. A batch of four refused for size is halved into two pairs; the first pair is
    /// refused again and halved once more into singles, which are accepted. Every one of the four is
    /// delivered, because each fitted on its own and none of them was the payload that was too large.
    func testA413KeepsSplittingUntilOnlyASingleOperationIsRefused() async throws {
        let store = try makeStore(try makeDirectory())
        let ids = [intakeID, otherIntakeID, thirdIntakeID, fourthIntakeID]
        for id in ids {
            try store.create(sampleIntake(id: id), components: components(), product: nil, now: when)
        }
        let ordered = try pendingRelay(store).map(\.operationID)
        let transport = FakeIntakeContextTransport(capabilities: Self.capabilities())
        // The batch of four, then its first half of two, are both refused for size. Each single is accepted.
        transport.answer(.init(statusCode: 413, error: "body too large"))
        transport.answer(.init(statusCode: 413, error: "body too large"))
        transport.answerEverythingAccepted()

        let outcomes = await makeWorker(store: store, transport: transport).runOnce(now: when)

        XCTAssertEqual(
            transport.sendCallCount, 5,
            "the batch, its first half, that half's two singles, and the second half: five requests")
        XCTAssertEqual(
            // The first two requests were refused for size; the three accepted ones carry each operation once.
            transport.sentBatches.dropFirst(2).flatMap { FakeIntakeContextTransport.operationIDs(in: $0) },
            ordered, "the splits keep the queue's order")
        XCTAssertEqual(
            outcomes.count, 4, "one outcome per operation")
        XCTAssertTrue(
            outcomes.allSatisfy(\.isResolved),
            "none of the four was the payload that was too large: \(outcomes)")
    }

    /// Only a **single** operation still coming back 413 is permanent. Two operations refused together are
    /// halved rather than parked, because each of them might have fitted alone — which is exactly the case
    /// where parking would refuse operations that were perfectly sendable.
    func testA413IsPermanentOnlyForTheSingleOperationThatIsStillRefused() async throws {
        let store = try makeStore(try makeDirectory())
        for id in [intakeID, otherIntakeID] {
            try store.create(sampleIntake(id: id), components: components(), product: nil, now: when)
        }
        let ordered = try pendingRelay(store).map(\.operationID)
        let transport = FakeIntakeContextTransport(capabilities: Self.capabilities())
        // The pair is refused, so each operation is asked on its own: the first is refused again, the second
        // is accepted.
        transport.answer(.init(statusCode: 413, error: "body too large"))
        transport.answer(.init(statusCode: 413, error: "body too large"))
        transport.answerEverythingAccepted()

        let outcomes = await makeWorker(store: store, transport: transport).runOnce(now: when)

        let parked = outcomes.compactMap { outcome -> String? in
            guard case .needsAttention(let id, let reason) = outcome else { return nil }
            XCTAssertTrue(reason.contains("too large"), reason)
            return id
        }
        XCTAssertEqual(parked, [ordered[0]], "only the operation refused on its own is permanent")
        XCTAssertTrue(
            outcomes.contains { $0.isResolved },
            "its neighbour fitted alone and was delivered: \(outcomes)")
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

    // MARK: - A projection queue that keeps what it was told

    /// A queue that holds projections in memory and records every resolution, so a test can see what the
    /// worker told it and when it would next offer each projection.
    final class RecordingProjectionQueue: RelayLinkProjectionQueue, @unchecked Sendable {
        private let lock = NSLock()
        private var offered: [RelayLinkProjection] = []
        private var resolutions: [(projection: RelayLinkProjection, resolution: RelayLinkProjectionResolution)] = []
        private var attempts: [String: Date] = [:]

        /// The projections a run is offered, in order.
        var pending: [RelayLinkProjection] {
            lock.withLock { offered.filter { attempts[$0.operationID] == nil } }
        }

        /// Every resolution recorded, oldest first.
        var recorded: [RelayLinkProjectionResolution] {
            lock.withLock { resolutions.map(\.resolution) }
        }

        /// When each projection was last told to wait, by delivery identity.
        var retryDates: [String: Date] {
            lock.withLock { attempts }
        }

        func offer(_ projections: [RelayLinkProjection]) {
            lock.withLock { offered = projections }
        }

        func pendingLinkProjections() async throws -> [RelayLinkProjection] {
            pending
        }

        func resolve(_ projection: RelayLinkProjection, with resolution: RelayLinkProjectionResolution) async {
            lock.withLock {
                resolutions.append((projection, resolution))
                if case .retryAfter(let date, _) = resolution {
                    attempts[projection.operationID] = date
                }
            }
        }
    }

    /// Answers links per call in queue order, alternating between a sound snapshot and one the encoder refuses.
///
/// That alternation is what puts the failures at revisions 1 and 3 with revision 2 sound between them: the
/// provider is asked once per operation, in the order the queue offers them. It is also what makes the test
/// about *two* failures rather than one, which is the case a single blocker per intake has to get right.
final class AlternatingLinkProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let sound: [IntakeContextLink]
    private var calls = 0

    init(sound: [IntakeContextLink]) {
        self.sound = sound
    }

    func links(for revision: Int) -> [IntakeContextLink] {
        lock.withLock {
            calls += 1
            guard calls % 2 == 1 else { return sound }
            // A link naming no component of the revision, which the encoder refuses whatever else is right.
            // The version rises each time so the two failures are not one repeated snapshot.
            return [IntakeContextLink(
                componentID: "not-a-fact",
                sampleUUID: "2c932bd1-c46d-4e38-b481-e0d842fdd429",
                healthKitTypeIdentifier: "HKQuantityTypeIdentifierDietaryWater",
                syncIdentifier: "intake:unusable",
                syncVersion: calls,
                disposition: .active)]
        }
    }
}

/// Hands out a distinct token per call, so a test can see that each batch asked for a fresh one rather
    /// than reusing one captured when the worker was built.
    final class TokenRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var issued = 0
        /// Every token handed out, in order.
        private(set) var recorded: [String] = []

        func next() async -> String {
            lock.withLock {
                issued += 1
                let token = "token-\(issued)"
                recorded.append(token)
                return token
            }
        }
    }

    /// A link provider whose snapshot the test changes between runs, so a retry can be shown rebuilding
    /// against different links than the first attempt used.
    final class LinkProvider: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: [IntakeContextLink]

        init(snapshot: [IntakeContextLink]) {
            self.snapshot = snapshot
        }

        var current: [IntakeContextLink] { lock.withLock { snapshot } }

        func set(_ links: [IntakeContextLink]) {
            lock.withLock { snapshot = links }
        }
    }

    /// A link projection that names a component of no revision, so the encoder refuses it whatever the
    /// journal holds. Used to exercise what an unencodable projection does to the ones behind it.
    private func unencodableProjection(sequence: Int) -> RelayLinkProjection {
        RelayLinkProjection(
            intakeID: intakeID, revision: 1, sequence: sequence,
            links: [IntakeContextLink(
                componentID: "not-a-fact",
                sampleUUID: "2c932bd1-c46d-4e38-b481-e0d842fdd429",
                healthKitTypeIdentifier: "HKQuantityTypeIdentifierDietaryWater",
                syncIdentifier: "intake:\(intakeID):water", syncVersion: sequence,
                disposition: .active)])
    }

    private func projection(sequence: Int, syncVersion: Int? = nil) -> RelayLinkProjection {
        RelayLinkProjection(
            intakeID: intakeID, revision: 1, sequence: sequence,
            links: [IntakeContextLink(
                componentID: "water",
                sampleUUID: "2c932bd1-c46d-4e38-b481-e0d842fdd429",
                healthKitTypeIdentifier: "HKQuantityTypeIdentifierDietaryWater",
                syncIdentifier: HealthKitWritePlanner.syncIdentifier(intakeID: intakeID, nutrientKey: "water"),
                syncVersion: syncVersion ?? sequence,
                disposition: .active)])
    }

    /// Two of an intake's revisions failing to encode must not let the one between them through. The
    /// earliest failure is the blocker: keeping the later one would clear revision 2, which sits after
    /// revision 1's failure and before revision 3's, and it would go out past a revision that failed ahead
    /// of it.
    func testTheEarliestEncodingFailureBlocksEverythingAfterIt() async throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "two", now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "three", now: when)
        let queuedInOrder = try pendingRelay(store, intakeID: intakeID).map(\.operationID)
        let first = queuedInOrder[0]
        let middle = queuedInOrder[1]
        let last = queuedInOrder[2]
        // Links alternate sound / unusable / sound, so revisions 1 and 3 fail to encode and revision 2 does
        // not: the sound revision is exactly the one a later blocker would wrongly admit.
        let provider = AlternatingLinkProvider(sound: [IntakeContextLink(
            componentID: "water",
            sampleUUID: "2c932bd1-c46d-4e38-b481-e0d842fdd429",
            healthKitTypeIdentifier: "HKQuantityTypeIdentifierDietaryWater",
            syncIdentifier: HealthKitWritePlanner.syncIdentifier(intakeID: intakeID, nutrientKey: "water"),
            syncVersion: 2,
            disposition: .active)])
        let transport = FakeIntakeContextTransport(capabilities: Self.capabilities())
        transport.answerEverythingAccepted()

        let outcomes = await makeWorker(
            store: store, transport: transport, links: { _, revision in provider.links(for: revision.number) }
        ).runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 0, "nothing after the first failure is sent")
        XCTAssertEqual(
            outcomes.compactMap { outcome -> String? in
                guard case .blocked(let id, let by) = outcome else { return nil }
                XCTAssertEqual(by, first, "both held-back revisions name the earliest failure")
                return id
            }.sorted(),
            [middle, last].sorted(),
            "the sound revision in between is held back by the earlier failure too")
    }

    /// A first link snapshot the encoder refuses is never recorded. The store keeps the first snapshot it is
    /// given for the life of the operation, so freezing an invalid one would make a snapshot that was merely
    /// wrong once permanently undeliverable — every retry would read the same bad links back.
    func testAnInvalidFirstLinkSnapshotIsNotRecordedSoALaterValidOneCanStillGo() async throws {
        let (store, transport, _) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        let operation = try XCTUnwrap(relayOperation(store, kind: .upsert))
        let provider = LinkProvider(snapshot: [
            IntakeContextLink(
                componentID: "not-a-fact",
                sampleUUID: "2c932bd1-c46d-4e38-b481-e0d842fdd429",
                healthKitTypeIdentifier: "HKQuantityTypeIdentifierDietaryWater",
                syncIdentifier: "intake:\(intakeID):water",
                syncVersion: 2,
                disposition: .active)
        ])
        transport.answerEverythingAccepted()
        let firstAttempt = makeWorker(
            store: store, transport: transport, links: { _, _ in provider.current })

        _ = await firstAttempt.runOnce(now: when)

        XCTAssertNil(
            try store.recordedLinks(operationID: operation.operationID),
            "a snapshot the encoder refused must not be frozen as the durable one")
        XCTAssertEqual(transport.sendCallCount, 0, "and nothing was sent")

        // The writer corrects the snapshot, so the next run has a valid one to record and deliver.
        provider.set(projection(sequence: 2).links)
        transport.reset()
        _ = await makeWorker(
            store: store, transport: transport, links: { _, _ in provider.current }
        ).runOnce(now: when.addingTimeInterval(3600))

        XCTAssertEqual(
            try store.recordedLinks(operationID: operation.operationID), provider.current,
            "the corrected snapshot is recorded and delivered")
        XCTAssertEqual(transport.sendCallCount, 1)
    }

    /// The capabilities document has to name this contract's `schema` as well as support its version. A
    /// receiver of some other contract may well list a version this build also uses, and reading that as
    /// agreement would send intake data somewhere it was never meant to go.
    func testAReceiverOfAnotherSchemaIsReportedAsAnEndpointMismatchNotPerOperation() async throws {
        let capabilities = IntakeContextCapabilities(
            schema: "com.example.some-other-contract",
            supportedVersions: [IntakeContextEncoder.schemaVersion],
            maxBodyBytes: 262_144,
            maxOperations: 32,
            authentication: IntakeContextAuthentication(
                scheme: "bearer", header: "Authorization", tokenType: "intake"))
        let (store, transport, worker) = try makeWorker(capabilities: capabilities)
        try store.create(sampleIntake(), components: components(), product: nil, now: when)

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 0, "nothing is sent to an endpoint of another contract")
        guard case .needsAttention(_, let reason) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("an endpoint mismatch needs a person, not a retry, got \(outcomes)")
        }
        XCTAssertTrue(reason.contains("not an \(IntakeContextEncoder.schema) endpoint"), reason)
        XCTAssertTrue(reason.contains("com.example.some-other-contract"), "it names what answered: \(reason)")
    }

    /// After a 413 split, an intake the head left unresolved has its later operations held back out of the
    /// tail — the same rule the batches between runs obey, so splitting cannot weaken ordering. The
    /// receiver applies in array order and never accepted the head's revision, so a newer one now would be
    /// refused as stale.
    func testASplitTailIsHeldBackForAnIntakeTheHeadLeftUnresolved() async throws {
        let store = try makeStore(try makeDirectory())
        // The queue is ordered by intake, so the head of a three-operation split is this intake's first
        // revision and its second revision sits in the tail with the other intake's.
        try store.create(sampleIntake(id: intakeID), components: components(), product: nil, now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "more", now: when)
        try store.create(sampleIntake(id: otherIntakeID), components: components(), product: nil, now: when)
        let queuedInOrder = try pendingRelay(store).map(\.operationID)
        let headOperation = queuedInOrder[0]
        let laterRevision = queuedInOrder[1]
        let otherIntake = queuedInOrder[2]
        let transport = FakeIntakeContextTransport(capabilities: Self.capabilities())
        transport.answer(.init(statusCode: 413, error: "too_many_operations"))
        // The head is refused for its first operation and accepted for the other, so exactly one intake ends
        // the head unresolved.
        transport.answer(.init(resultsByOperation: [headOperation: .permanentFailure]))
        transport.answerEverythingAccepted()

        let outcomes = await makeWorker(store: store, transport: transport).runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 3, "the oversized batch, the head, then the tail")
        XCTAssertEqual(
            outcomes.compactMap { outcome -> String? in
                guard case .blocked(let id, let by) = outcome else { return nil }
                XCTAssertEqual(by, headOperation, "the held-back operation names what holds it")
                return id
            },
            [laterRevision],
            "the later revision of the unresolved intake is kept out of the tail")
        // The refused first request carried it (one intake's revisions travel together); no request after it may.
        XCTAssertFalse(
            transport.sentBatches.dropFirst().flatMap { FakeIntakeContextTransport.operationIDs(in: $0) }
                .contains(laterRevision),
            "and it is genuinely not sent again, not merely reported as blocked")
        XCTAssertTrue(transport.sentOperationIDs.contains(otherIntake), "other intakes still go out")
    }

    // MARK: - Review round 1

    /// A parked **later** revision must not strand an earlier due one. The receiver only refuses going
    /// forwards, so revision 1 is deliverable whatever happened to revision 3, and withholding it would
    /// leave the queue permanently stuck behind a problem it cannot fix on its own.
    func testAParkedLaterRevisionDoesNotStrandTheEarlierDueRevision() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "two", now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "three", now: when)
        let queuedInOrder = try pendingRelay(store, intakeID: intakeID).map(\.operationID)
        let third = queuedInOrder[2]
        try store.recordFailure(
            operationID: third, retryAt: nil, needsAttention: true, reason: "a domain conflict")
        transport.answerEverythingAccepted()

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(
            transport.sentOperationIDs, Array(queuedInOrder.prefix(2)),
            "the two earlier revisions go out; only the parked one holds back what is behind it")
        XCTAssertEqual(
            outcomes.compactMap { outcome -> String? in
                guard case .needsAttention(let id, _) = outcome else { return nil }
                return id
            },
            [third])
        XCTAssertEqual(
            try pendingRelay(store, intakeID: intakeID).map(\.operationID), [third],
            "only the parked revision is left queued")
    }

    /// A rejected token on the head of a split stops there. Every batch carries the same credential, so
    /// sending the tail is one more request the receiver refuses for the same reason, and it would park
    /// those operations against a token already known to be bad.
    func testA401OnTheHeadOfASplitBatchStopsBeforeTheTailIsSent() async throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(id: intakeID), components: components(), product: nil, now: when)
        try store.create(sampleIntake(id: otherIntakeID), components: components(), product: nil, now: when)
        try store.create(sampleIntake(id: thirdIntakeID), components: components(), product: nil, now: when)
        let ordered = try pendingRelay(store).map(\.operationID)
        let transport = FakeIntakeContextTransport(capabilities: Self.capabilities())
        // One oversized batch, refused for size; then the head of the split is refused for the token.
        transport.answer(.init(statusCode: 413, error: "too_many_operations"))
        transport.answer(.init(statusCode: 401))
        transport.answerEverythingAccepted()

        let outcomes = await makeWorker(store: store, transport: transport).runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 2, "the tail of the split is never sent")
        XCTAssertEqual(
            outcomes.filter { if case .notAttempted = $0 { return true } else { return false } }.count, 2,
            "the tail is reported as unattempted: \(outcomes)")
        let parked = try pendingRelay(store).filter { $0.operationID != ordered[0] }
        XCTAssertEqual(
            parked.filter { $0.attempts == 0 }.count, 2,
            "an operation that was never sent is not recorded as a failed attempt")
    }

    /// A 429 with no `Retry-After` steps along the same ladder as any other transient failure. Holding a
    /// repeatedly throttled producer at one minute is the opposite of what a receiver asking for less
    /// traffic wants.
    func testA429WithoutARetryAfterUsesTheAttemptBackoffNotAFixedMinute() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        transport.answer(.init(statusCode: 429))
        _ = await worker.runOnce(now: when)
        transport.reset()
        transport.answer(.init(statusCode: 429))

        // The second failure must wait longer than the first: five minutes, not another minute.
        let outcomes = await worker.runOnce(now: when.addingTimeInterval(3600))

        guard case .retryScheduled(_, let next, _) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("a rate limit is a retry, got \(outcomes)")
        }
        XCTAssertEqual(next, when.addingTimeInterval(3600).addingTimeInterval(300))
    }

    /// A rate limit stops the run, whatever the rest of the batch sizes would be. The receiver asked this
    /// producer to send less, and the remaining batches are more of exactly that; splitting would not help,
    /// since the limit is on traffic rather than on size.
    func testARateLimitStopsTheRunRatherThanSendingTheRemainingBatches() async throws {
        let store = try makeStore(try makeDirectory())
        for id in [intakeID, otherIntakeID, thirdIntakeID] {
            try store.create(sampleIntake(id: id), components: components(), product: nil, now: when)
        }
        let transport = FakeIntakeContextTransport(capabilities: Self.capabilities(maxOperations: 1))
        transport.answer(.init(statusCode: 429, retryAfterSeconds: 90))
        transport.answerEverythingAccepted()

        let outcomes = await makeWorker(store: store, transport: transport).runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 1, "the run stops at the first rate limit")
        XCTAssertEqual(
            outcomes.filter { if case .notAttempted = $0 { return true } else { return false } }.count, 2,
            "the operations after it are reported as unattempted: \(outcomes)")
        XCTAssertEqual(
            try pendingRelay(store).map(\.attempts), [1, 0, 0],
            "only the batch that was refused counts as failed")
    }

    /// The tombstone carries when the person deleted the entry, not when the last revision was written.
    /// `delete(intakeID:now:)` knows, the journal records it, and it is hashed — so an approximation could
    /// never be corrected afterwards without turning the retry into a conflict.
    func testADeleteCarriesThePersistedDeletionInstantRatherThanTheRevisionsCreationTime() async throws {
        let (store, transport, worker) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        let deletedAt = when.addingTimeInterval(3600)
        try store.delete(intakeID: intakeID, now: deletedAt)
        let deleteRow = try XCTUnwrap(relayOperation(store, kind: .delete))
        transport.answerEverythingAccepted()

        _ = await worker.runOnce(now: deletedAt)
        XCTAssertEqual(
            try store.deletionInstant(operationID: deleteRow.operationID), deletedAt,
            "the journal recorded the instant it was given")
        let batch = try IntakeContextJSONReader.read(try XCTUnwrap(transport.sentBatches.first))
        let tombstone = try XCTUnwrap(batch.array("operations")).last
        XCTAssertEqual(tombstone?.string("operation"), "delete")
        XCTAssertEqual(
            tombstone?.string("deleted_at"), IntakeContextTimestamp.utc(deletedAt),
            "the tombstone states the real deletion instant")
        XCTAssertNotEqual(
            tombstone?.string("deleted_at"), IntakeContextTimestamp.utc(when),
            "and not the instant the last revision happened to be written")
    }

    /// The token is asked for once per batch, so a credential that rotates partway through a run is not
    /// stale for the batches after the rotation — each of which would come back 401 and park its work.
    func testTheTokenIsAskedForOnceForEachBatch() async throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(id: intakeID), components: components(), product: nil, now: when)
        try store.create(sampleIntake(id: otherIntakeID), components: components(), product: nil, now: when)
        try store.create(sampleIntake(id: thirdIntakeID), components: components(), product: nil, now: when)
        let transport = FakeIntakeContextTransport(capabilities: Self.capabilities(maxOperations: 1))
        transport.answerEverythingAccepted()
        let tokens = TokenRecorder()

        _ = await makeWorker(store: store, transport: transport, token: { await tokens.next() }).runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 3, "three batches")
        XCTAssertEqual(tokens.recorded.count, 3, "the token is asked for once per batch, not once per run")
        XCTAssertEqual(
            transport.sentTokens, ["token-1", "token-2", "token-3"],
            "each batch carries the token that was current for it")
    }

    /// A token that cannot be read is not a rejected token: nothing was sent, so nothing is parked. The
    /// operations are rescheduled instead, since a connection that cannot mint a credential yet may manage
    /// it on the next run.
    func testATokenThatCannotBeReadReschedulesRatherThanParks() async throws {
        let (store, transport, _) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        let worker = makeWorker(
            store: store, transport: transport,
            token: { throw URLError(.userAuthenticationRequired) })

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 0)
        guard case .retryScheduled(_, let next, let reason) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("an unreadable token is not a refusal, got \(outcomes)")
        }
        XCTAssertTrue(reason.contains("token"), reason)
        XCTAssertEqual(next, when.addingTimeInterval(60))
        XCTAssertEqual(try pendingRelay(store).count, 1, "the operation is still queued, not parked")
    }

    /// A projection that was told to wait is not offered again until its date. Without this the queue hands
    /// it back on the next run whatever the receiver said, and a run triggered for unrelated work retries it
    /// immediately against a receiver that had asked this producer to stop.
    func testAProjectionRetryIsRecordedWithItsQueueSoRunsRespectTheWait() async throws {
        let (store, transport, _) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        let queue = RecordingProjectionQueue()
        let queued = projection(sequence: 2)
        queue.offer([queued])
        transport.answer(.init(statusCode: 500))
        let worker = makeWorker(store: store, transport: transport, projections: queue)

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(queue.recorded.count, 1)
        guard case .retryAfter(let date, _) = try XCTUnwrap(queue.recorded.first) else {
            return XCTFail("a transient failure tells the queue when to come back, got \(queue.recorded)")
        }
        XCTAssertEqual(date, when.addingTimeInterval(60))
        XCTAssertEqual(
            queue.retryDates[queued.operationID], date, "the queue can honour it on the next run")
        guard case .retryScheduled(_, let reported, _) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("the run reports the same date, got \(outcomes)")
        }
        XCTAssertEqual(reported, date)
        XCTAssertEqual(queue.pending, [], "a projection told to wait is not offered again yet")
    }

    /// A 429's stated `Retry-After` reaches the projection queue too, so the wait the receiver asked for is
    /// the wait it gets rather than the backoff standing in for it.
    func testAProjectionsRetryAfterHeaderReachesItsQueue() async throws {
        let (store, transport, _) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        let queue = RecordingProjectionQueue()
        queue.offer([projection(sequence: 2)])
        transport.answer(.init(statusCode: 429, retryAfterSeconds: 120))
        let worker = makeWorker(store: store, transport: transport, projections: queue)

        _ = await worker.runOnce(now: when)

        XCTAssertEqual(
            queue.retryDates.values.first, when.addingTimeInterval(120),
            "the receiver's own interval is what the queue waits")
    }

    /// An upsert's links are recorded with its first attempt and reused on the retry. The delivery identity
    /// is the outbox row's, so links that arrived in between would move the digests and turn a lost
    /// response's retry into a conflict at the receiver.
    func testAnUpsertRetryReusesTheLinkSnapshotOfItsFirstAttempt() async throws {
        let (store, transport, _) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        let operation = try XCTUnwrap(relayOperation(store, kind: .upsert))
        let first = projection(sequence: 2)
        let provider = LinkProvider(snapshot: first.links)
        // The response is lost, so the operation stays pending and is attempted again.
        transport.failSends(with: URLError(.timedOut))
        _ = await makeWorker(
            store: store, transport: transport, links: { _, _ in provider.current }
        ).runOnce(now: when)
        provider.set(
            [IntakeContextLink(
                componentID: "water",
                sampleUUID: "6f1c9d20-84ab-4e77-9a3b-5c0e2d84f611",
                healthKitTypeIdentifier: "HKQuantityTypeIdentifierDietaryWater",
                syncIdentifier: HealthKitWritePlanner.syncIdentifier(intakeID: intakeID, nutrientKey: "water"),
                syncVersion: 7,
                disposition: .active)])
        transport.reset()
        let retrying = makeWorker(
            store: store, transport: transport, links: { _, _ in provider.current })
        transport.answerEverythingAccepted()

        _ = await retrying.runOnce(now: when.addingTimeInterval(3600))

        XCTAssertEqual(
            try store.recordedLinks(operationID: operation.operationID), first.links,
            "the snapshot sent first is the one a retry reuses")
        let sent = try IntakeContextJSONReader.read(try XCTUnwrap(transport.sentBatches.first))
        let links = try XCTUnwrap(sent.array("operations")).first?.array("healthkit_links")
        XCTAssertEqual(
            links?.first?.string("healthkit_sample_uuid"), first.links.first?.sampleUUID,
            "the retry carries the first attempt's sample, not the one that arrived since")
    }

    /// An unencodable projection holds back the projections behind it, and only those: they are later
    /// sequences of the same revision, and the receiver refuses a projection whose predecessor it has not
    /// accepted, so letting them through would ask it to reconcile a state the earlier one could not be
    /// sent in at all.
    func testAnUnencodableProjectionHoldsBackTheLaterProjectionsOfItsIntake() async throws {
        let (store, transport, _) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        let queue = RecordingProjectionQueue()
        let bad = unencodableProjection(sequence: 2)
        let later = projection(sequence: 3)
        queue.offer([bad, later])
        transport.answerEverythingAccepted()
        let worker = makeWorker(store: store, transport: transport, projections: queue)

        let upsert = try XCTUnwrap(relayOperation(store, kind: .upsert)?.operationID)
        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(
            transport.sentOperationIDs, [upsert],
            "only the revision's upsert goes out: neither projection is sent past the one that failed")
        XCTAssertFalse(
            transport.sentOperationIDs.contains(later.operationID),
            "the later sequence is genuinely not sent, not merely reported as blocked")
        XCTAssertEqual(
            outcomes.filter { if case .blocked(_, let by) = $0 { return by == bad.operationID } else { return false } }
                .map(\.operationID),
            [later.operationID])
        XCTAssertEqual(
            queue.recorded.filter { $0 != .delivered(acceptedRevision: nil, serverCursor: nil) }.count, 1,
            "only the unencodable projection is reported, and as needing a person")
    }

    /// The sequence-1 snapshot is written when the operation is about to be sent, not while it is being
    /// encoded. Encoding does not promise a send — the blocker check runs after it — so an operation held
    /// back behind an earlier revision must leave nothing on record.
    func testALinkSnapshotIsRecordedOnlyForAnOperationThatIsActuallySent() async throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "more", now: when)
        let queuedInOrder = try pendingRelay(store, intakeID: intakeID).map(\.operationID)
        let heldBack = queuedInOrder[1]
        // The first revision is parked, so the second is held back and never sent.
        try store.recordFailure(
            operationID: queuedInOrder[0], retryAt: nil, needsAttention: true, reason: "a domain conflict")
        let provider = LinkProvider(snapshot: projection(sequence: 2).links)
        let transport = FakeIntakeContextTransport(capabilities: Self.capabilities())
        transport.answerEverythingAccepted()

        _ = await makeWorker(
            store: store, transport: transport, links: { _, _ in provider.current }
        ).runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 0, "nothing went out")
        XCTAssertNil(
            try store.recordedLinks(operationID: heldBack),
            "an operation that never went on the wire must not freeze a snapshot on record")
    }

    /// A capabilities read that fails counts as an attempt only for the operations that were eligible to
    /// send. An operation held back behind a blocker had no part in the failure, so advancing its backoff
    /// would punish it for something it never tried.
    func testAFailedCapabilitiesReadDoesNotCountAnAttemptForAnOperationHeldBack() async throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "more", now: when)
        try store.create(sampleIntake(id: otherIntakeID), components: components(), product: nil, now: when)
        let firstIntake = try pendingRelay(store, intakeID: intakeID).map(\.operationID)
        let heldBack = firstIntake[1]
        let eligible = try XCTUnwrap(relayOperation(store, intakeID: otherIntakeID)?.operationID)
        // The first revision of one intake is parked, so its second revision is held back; the other
        // intake's operation was eligible and does count.
        try store.recordFailure(
            operationID: firstIntake[0], retryAt: nil, needsAttention: true, reason: "a domain conflict")
        let transport = FakeIntakeContextTransport(capabilities: Self.capabilities())
        transport.failCapabilities(with: URLError(.timedOut))
        let worker = makeWorker(store: store, transport: transport)

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 0)
        let attempts = try pendingRelay(store).map { ($0.operationID, $0.attempts) }
        XCTAssertEqual(
            attempts.first { $0.0 == heldBack }?.1, 0,
            "the held-back operation was never going out, so it failed no attempt")
        XCTAssertEqual(
            attempts.first { $0.0 == eligible }?.1, 1,
            "the operation that was eligible to send does count")
        XCTAssertTrue(
            outcomes.contains { if case .blocked(let id, _) = $0 { return id == heldBack } else { return false } },
            "and it is reported as blocked rather than retried")
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
        // The receiver is the right endpoint and simply does not speak this version, so the reason says so.
        XCTAssertTrue(reason.contains("does not accept"), reason)
        XCTAssertTrue(reason.contains("1.0"), "it names the version it writes: \(reason)")
        XCTAssertTrue(reason.contains("0.9"), "and the one it speaks instead: \(reason)")
        XCTAssertFalse(
            reason.contains("not an"), "a wrong-endpoint reason would send the wrong reader looking: \(reason)")
    }

    // MARK: - Split tails, superseded projections, and deletions

    /// A prepared batch is not one request: a 413 splits it, and a head that is then rate limited, refused
    /// for its token, or that leaves its own intake unresolved keeps the tail off the wire entirely. A
    /// snapshot frozen for that tail at batch-packing time would be a record of links no request ever
    /// carried, and would go on missing the links that arrived while the tail waited. So nothing is recorded
    /// for it, and the run after the links arrive sends it with them.
    func testAnUnattemptedSplitTailKeepsNoFrozenSnapshotSoLaterLinksGoOutWithIt() async throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(id: intakeID), components: components(), product: nil, now: when)
        try store.create(sampleIntake(id: otherIntakeID), components: components(), product: nil, now: when)
        let ordered = try pendingRelay(store).map(\.operationID)
        let tail = ordered[1]
        let beforeSplit = projection(sequence: 2).links
        let provider = LinkProvider(snapshot: beforeSplit)
        let transport = FakeIntakeContextTransport(capabilities: Self.capabilities())
        // The batch of two is refused for size; its single-operation head is then rate limited, which stops
        // the split there, so the tail's own request is never made.
        transport.answer(.init(statusCode: 413, error: "body too large"))
        transport.answer(.init(statusCode: 429))

        let outcomes = await makeWorker(
            store: store, transport: transport, links: { _, _ in provider.current }
        ).runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 2, "the oversized batch and its head, and no tail")
        XCTAssertEqual(
            outcomes.filter { if case .notAttempted = $0 { return true } else { return false } }
                .map(\.operationID), [tail],
            "the tail is reported as never attempted: \(outcomes)")
        XCTAssertNil(
            try store.recordedLinks(operationID: tail),
            "a tail that was never sent must keep no frozen snapshot")

        // A HealthKit save reveals the sample while the tail is still waiting.
        let arrived = [IntakeContextLink(
            componentID: "water",
            sampleUUID: "6f1c9d20-84ab-4e77-9a3b-5c0e2d84f611",
            healthKitTypeIdentifier: "HKQuantityTypeIdentifierDietaryWater",
            syncIdentifier: HealthKitWritePlanner.syncIdentifier(intakeID: intakeID, nutrientKey: "water"),
            syncVersion: 9,
            disposition: .active)]
        provider.set(arrived)
        transport.reset()
        transport.answerEverythingAccepted()

        _ = await makeWorker(
            store: store, transport: transport, links: { _, _ in provider.current }
        ).runOnce(now: when.addingTimeInterval(3600))

        let sent = try IntakeContextJSONReader.read(try XCTUnwrap(transport.sentBatches.first))
        let byID = try XCTUnwrap(sent.array("operations")).reduce(into: [String: IntakeContextJSONValue]()) {
            $0[$1.string("operation_id") ?? ""] = $1
        }
        let delivered = try XCTUnwrap(byID[tail])
        XCTAssertEqual(
            delivered.array("healthkit_links")?.first?.string("healthkit_sample_uuid"), arrived.first?.sampleUUID,
            "the tail is finally sent carrying the link that arrived while it waited, not the one frozen for "
                + "the split batch it was never part of")
    }

    /// A projection naming an intake or a revision the journal no longer holds is resolved as superseded, and
    /// the run says so. Resolving it in the queue without reporting it would leave the run's outcomes not
    /// reconciling with the queue: the caller would not learn the projection had been settled.
    func testASupersededProjectionIsReportedInTheRunOutcomes() async throws {
        let (store, transport, _) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        let queue = RecordingProjectionQueue()
        // The journal holds revision 1 of this intake; the projection names revision 7, which it does not.
        let gone = RelayLinkProjection(
            intakeID: intakeID, revision: 7, sequence: 2,
            links: [IntakeContextLink(
                componentID: "water",
                sampleUUID: "2c932bd1-c46d-4e38-b481-e0d842fdd429",
                healthKitTypeIdentifier: "HKQuantityTypeIdentifierDietaryWater",
                syncIdentifier: HealthKitWritePlanner.syncIdentifier(intakeID: intakeID, nutrientKey: "water"),
                syncVersion: 2,
                disposition: .active)])
        queue.offer([gone])
        transport.answerEverythingAccepted()
        let worker = makeWorker(store: store, transport: transport, projections: queue)

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(queue.recorded, [.superseded], "the queue is told the projection is finished with")
        XCTAssertFalse(
            transport.sentOperationIDs.contains(gone.operationID), "and nothing was sent for it")
        let reported = try XCTUnwrap(outcomes.first { $0.operationID == gone.operationID })
        guard case .superseded = reported else {
            return XCTFail("the run reports the superseded projection too, got \(outcomes)")
        }
    }

    /// An upsert carries a complete link snapshot for its own revision and never a delta, so a projection of
    /// an older revision of the same intake has nothing left to say once a newer revision's upsert is queued
    /// in the same run. Sending it before or after would only earn `stale_revision`: the receiver holds a
    /// newer revision either way, so it is resolved as superseded and reported, like any other superseded
    /// projection.
    func testAnOlderRevisionProjectionIsSupersededRatherThanSentBehindANewerUpsert() async throws {
        let (store, transport, _) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "more", now: when)
        let queue = RecordingProjectionQueue()
        // Revision 1's projection, queued while revision 2's upsert is queued in the same run.
        let older = RelayLinkProjection(
            intakeID: intakeID, revision: 1, sequence: 2,
            links: [IntakeContextLink(
                componentID: "water",
                sampleUUID: "2c932bd1-c46d-4e38-b481-e0d842fdd429",
                healthKitTypeIdentifier: "HKQuantityTypeIdentifierDietaryWater",
                syncIdentifier: HealthKitWritePlanner.syncIdentifier(intakeID: intakeID, nutrientKey: "water"),
                syncVersion: 2,
                disposition: .active)])
        queue.offer([older])
        transport.answerEverythingAccepted()
        let worker = makeWorker(store: store, transport: transport, projections: queue)
        let queuedUpserts = try pendingRelay(store).map(\.operationID)

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(
            transport.sentOperationIDs, queuedUpserts,
            "only the upserts go out: the older revision's projection has nothing left to say")
        XCTAssertEqual(queue.recorded, [.superseded])
        guard case .superseded(_, let detail) = try XCTUnwrap(
            outcomes.first { $0.operationID == older.operationID })
        else {
            return XCTFail("the superseded projection is reported, got \(outcomes)")
        }
        let reason = try XCTUnwrap(detail)
        XCTAssertTrue(reason.contains("revision 2"), "it names the revision that replaced it: \(reason)")
    }

    /// A delete queued behind a suspended upsert supersedes it. The tombstone retracts exactly what the
    /// upsert would have put into the receiver, so holding it behind a suspension nothing releases would keep
    /// the receiver holding an entry the person deleted. One run delivers the tombstone and reports the
    /// upsert finished with, and acknowledging it clears the suspension with it.
    func testADeleteQueuedAfterASuspendedUpsertSupersedesItAndStillGoesOut() async throws {
        let (store, transport, _) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        let upsert = try XCTUnwrap(relayOperation(store, kind: .upsert)?.operationID)
        try store.recordFailure(
            operationID: upsert, retryAt: nil, needsAttention: true, reason: "a domain conflict")
        let deletedAt = when.addingTimeInterval(3600)
        try store.delete(intakeID: intakeID, now: deletedAt)
        let deleteRow = try XCTUnwrap(relayOperation(store, kind: .delete)?.operationID)
        transport.answerEverythingAccepted()

        let outcomes = await makeWorker(store: store, transport: transport).runOnce(now: deletedAt)

        XCTAssertEqual(transport.sentOperationIDs, [deleteRow], "the tombstone goes out on its own")
        let batch = try IntakeContextJSONReader.read(try XCTUnwrap(transport.sentBatches.first))
        let tombstone = try XCTUnwrap(batch.array("operations")).first
        XCTAssertEqual(tombstone?.string("operation"), "delete")
        guard case .superseded(let id, _) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("the suspended upsert is superseded, not parked, got \(outcomes)")
        }
        XCTAssertEqual(id, upsert, "it is the upsert that is finished with, and the delete that is delivered")
        XCTAssertEqual(try pendingRelay(store), [], "neither row is left queued")
        XCTAssertNil(
            try store.suspensionReason(operationID: upsert),
            "acknowledging it clears the suspension, so nothing is left parked")
    }

    /// An acknowledgement that fails leaves the suspended upsert queued and still suspended, so the delete
    /// behind it must wait. Sending the tombstone anyway would retract what the receiver holds while the
    /// journal still claims an upsert is outstanding for the same intake, and the receiver applies in array
    /// order — the ordering rule this worker keeps depends on that claim being true.
    func testAFailedSupersedeAcknowledgementHoldsTheQueuedDeleteBack() async throws {
        let (store, transport, _) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        let upsert = try XCTUnwrap(relayOperation(store, kind: .upsert)?.operationID)
        try store.recordFailure(
            operationID: upsert, retryAt: nil, needsAttention: true, reason: "a domain conflict")
        let deletedAt = when.addingTimeInterval(3600)
        try store.delete(intakeID: intakeID, now: deletedAt)
        let deleteRow = try XCTUnwrap(relayOperation(store, kind: .delete)?.operationID)
        // The next write fails, which is the acknowledgement of the superseded upsert.
        store.failNextSaveForTesting = true
        transport.answerEverythingAccepted()

        let outcomes = await makeWorker(store: store, transport: transport).runOnce(now: deletedAt)

        XCTAssertEqual(transport.sendCallCount, 0, "the delete waits: its own predecessor is still outstanding")
        guard case .notAcknowledged(let id, _) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("the failed acknowledgement is reported, got \(outcomes)")
        }
        XCTAssertEqual(id, upsert, "it is the upsert whose acknowledgement failed")
        guard case .blocked(let blocked, let by) = try XCTUnwrap(
            outcomes.first { $0.operationID == deleteRow })
        else {
            return XCTFail("the delete is blocked by the upsert that is still queued, got \(outcomes)")
        }
        XCTAssertEqual(by, upsert, "and it names what holds it")
        XCTAssertEqual(blocked, deleteRow)
        XCTAssertEqual(
            try pendingRelay(store).map(\.operationID), [upsert, deleteRow],
            "both rows are untouched: the failed write rolled back")
    }

    /// The snapshot must be on record **before** the request that carries it goes out, not after the answer.
    ///
    /// A process death between the send and the write would otherwise leave a sent operation with no
    /// snapshot: the retry would reuse the same `operation_id` with a different `client_payload_hash`, which
    /// the receiver reads as a permanent conflict rather than the duplicate it should be. The transport is
    /// asked, while it holds the batch and before any answer exists, what the journal holds — so a record
    /// written afterwards would not be visible and this would fail.
    func testASnapshotIsRecordedBeforeTheRequestCarryingItIsSent() async throws {
        let (store, transport, _) = try makeWorker()
        try store.create(sampleIntake(id: intakeID), components: components(), product: nil, now: when)
        try store.create(sampleIntake(id: otherIntakeID), components: components(), product: nil, now: when)
        transport.observeRecords(of: store)
        transport.answerEverythingAccepted()

        _ = await makeWorker(
            store: store, transport: transport, links: { _, _ in projection(sequence: 2).links }
        ).runOnce(now: when)

        XCTAssertEqual(transport.recordsAtSendTime.count, 1)
        for (operationID, recorded) in try XCTUnwrap(transport.recordsAtSendTime.first) {
            XCTAssertTrue(
                recorded,
                "the snapshot for \(operationID) must already be on record when its request is handed over")
        }
    }

    /// The same holds for each half of a split, which is a request of its own. A snapshot written after the
    /// 413 that produced the split would leave the head unsent at the moment it goes out.
    func testASplitPieceIsSentWithItsSnapshotAlreadyRecorded() async throws {
        let store = try makeStore(try makeDirectory())
        try store.create(sampleIntake(id: intakeID), components: components(), product: nil, now: when)
        try store.create(sampleIntake(id: otherIntakeID), components: components(), product: nil, now: when)
        let transport = FakeIntakeContextTransport(capabilities: Self.capabilities())
        transport.observeRecords(of: store)
        transport.answer(.init(statusCode: 413, error: "body too large"))
        transport.answerEverythingAccepted()

        _ = await makeWorker(
            store: store, transport: transport, links: { _, _ in projection(sequence: 2).links }
        ).runOnce(now: when)

        // Every request is handed over with its own snapshots already on record — including the oversized one,
        // which is a request that really was made. What the 413 does is release those records afterwards, so
        // each half records its own and an item whose half never goes out is left with nothing.
        XCTAssertEqual(transport.recordsAtSendTime.count, 3, "the refused batch and its two halves")
        for (index, batch) in transport.recordsAtSendTime.enumerated() {
            for (operationID, recorded) in batch {
                XCTAssertTrue(
                    recorded,
                    "request \(index): the snapshot for \(operationID) is on record when it is handed over")
            }
        }
    }

    /// A record write that fails means the piece is **not sent**. Putting a payload on the wire whose snapshot
    /// is not on record is what produces the permanent conflict above, and the operation is still deliverable:
    /// nothing was sent, so it is rescheduled and the next attempt encodes against the links current then.
    func testAFailedSnapshotRecordSendsNothingAndReschedulesInstead() async throws {
        let (store, transport, _) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        let operation = try XCTUnwrap(relayOperation(store, kind: .upsert)?.operationID)
        transport.answerEverythingAccepted()
        // The next write fails, which is the snapshot record this piece makes before it goes out.
        store.failNextSaveForTesting = true

        let outcomes = await makeWorker(
            store: store, transport: transport, links: { _, _ in projection(sequence: 2).links }
        ).runOnce(now: when)

        XCTAssertEqual(transport.sendCallCount, 0, "a payload whose snapshot is not on record is not sent")
        guard case .retryScheduled(let id, _, let reason) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("the operation is rescheduled rather than lost, got \(outcomes)")
        }
        XCTAssertEqual(id, operation)
        XCTAssertTrue(reason.contains("snapshot"), "the reason names the write that failed: \(reason)")
        XCTAssertNil(
            try store.recordedLinks(operationID: operation),
            "and the failed write left nothing on record")
        XCTAssertEqual(try pendingRelay(store).count, 1, "the operation is still queued")
    }

    /// A projection of an older revision is superseded only once the newer revision's upsert is **accepted**.
    ///
    /// The receiver holds a newer revision is a fact about the receiver, and an upsert merely being queued does
    /// not make it one. When that upsert is refused, the receiver still holds the older revision, so the older
    /// projection is something it can take and must stay queued — reported as blocked by the upsert that has
    /// not landed rather than discarded as superseded.
    func testAnOlderRevisionProjectionIsNotSupersededWhenTheNewerUpsertIsRefused() async throws {
        let (store, transport, _) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "more", now: when)
        let queue = RecordingProjectionQueue()
        let older = projection(sequence: 2)
        queue.offer([older])
        let queued = try pendingRelay(store).map(\.operationID)
        let newerUpsert = queued[1]
        transport.answer(.init(resultsByOperation: [newerUpsert: .permanentFailure]))
        let worker = makeWorker(store: store, transport: transport, projections: queue)

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(
            queue.recorded, [],
            "the projection stays queued: its queue is told nothing, because nothing settled it")
        guard case .blocked(let id, let by) = try XCTUnwrap(
            outcomes.first { $0.operationID == older.operationID })
        else {
            return XCTFail("the projection is reported as blocked, not superseded, got \(outcomes)")
        }
        XCTAssertEqual(id, older.operationID)
        XCTAssertEqual(by, newerUpsert, "it names the upsert that has not been accepted")
    }

    /// The other half of that decision: an accepted or duplicate upsert does supersede the older projection,
    /// because the receiver now holds the newer revision and would answer the projection `stale_revision`.
    func testAnOlderRevisionProjectionIsSupersededOnceTheNewerUpsertIsAccepted() async throws {
        let (store, transport, _) = try makeWorker()
        try store.create(sampleIntake(), components: components(), product: nil, now: when)
        try store.edit(
            intakeID: intakeID, components: components(), product: nil, changeReason: "more", now: when)
        let queue = RecordingProjectionQueue()
        let older = projection(sequence: 2)
        queue.offer([older])
        // Revision 2's upsert, the newest this run finds queued for the intake.
        let newerUpsert = try XCTUnwrap(pendingRelay(store).last?.operationID)
        transport.answer(.init(resultsByOperation: [newerUpsert: .duplicate]))
        let worker = makeWorker(store: store, transport: transport, projections: queue)

        let outcomes = await worker.runOnce(now: when)

        XCTAssertEqual(
            queue.recorded, [.superseded],
            "a duplicate means the receiver holds the newer revision, so the projection is finished with")
        guard case .superseded = try XCTUnwrap(
            outcomes.first { $0.operationID == older.operationID })
        else {
            return XCTFail("and the run reports it superseded, got \(outcomes)")
        }
    }
}