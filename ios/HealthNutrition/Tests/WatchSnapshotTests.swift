import Foundation
import XCTest

@testable import HealthNutrition

/// The Watch envelope and the phone's sender against a fake transport (WatchConnectivity itself cannot be
/// exercised in a unit test). Synthetic figures only.
final class WatchSnapshotTests: XCTestCase {
    private final class FakeTransport: WatchSnapshotTransport, @unchecked Sendable {
        struct Refused: Error {}
        var canSend = true
        var fails = false
        /// Makes each send slow, so concurrent sends overlap.
        var delay: TimeInterval = 0
        private let lock = NSLock()
        private var all: [[String: Any]] = []
        var sent: [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return all
        }
        func send(context: [String: Any]) throws {
            if fails { throw Refused() }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            lock.lock()
            all.append(context)
            lock.unlock()
        }
        var lastEnvelope: WatchSnapshotEnvelope? {
            guard let last = sent.last, case .envelope(let envelope) = WatchSnapshotEnvelope.decode(context: last)
            else { return nil }
            return envelope
        }
    }

    private func sample() -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000), hasEntries: true, energyKcal: 1_050,
            energyGoalKcal: 2_100, proteinGrams: 80, carbohydrateGrams: 120, fatGrams: 40, waterMilliliters: 750)
    }

    // MARK: Envelope

    func testAnEnvelopeRoundTripsThroughItsContext() throws {
        let envelope = WatchSnapshotEnvelope(eraseGeneration: 3, snapshot: sample())
        let decoded = WatchSnapshotEnvelope.decode(context: try envelope.context())
        XCTAssertEqual(decoded, .envelope(envelope))
    }

    func testAnEmptyEnvelopeCarriesNoSummary() throws {
        let envelope = WatchSnapshotEnvelope(eraseGeneration: 4, snapshot: nil)
        guard case .envelope(let decoded) = WatchSnapshotEnvelope.decode(context: try envelope.context()) else {
            return XCTFail("an empty envelope decodes")
        }
        XCTAssertNil(decoded.snapshot)
        XCTAssertEqual(decoded.eraseGeneration, 4)
    }

    func testTheEnvelopeCarriesOnlyTheSummaryFields() throws {
        let data = try XCTUnwrap(
            try WatchSnapshotEnvelope(eraseGeneration: 1, snapshot: sample()).context()[WatchSnapshotEnvelope.contextKey]
                as? Data)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "eraseGeneration", "snapshot"])
        let snapshot = try XCTUnwrap(object["snapshot"] as? [String: Any])
        XCTAssertEqual(
            Set(snapshot.keys),
            [
                "generatedAt", "hasEntries", "energyKcal", "energyGoalKcal", "proteinGrams", "carbohydrateGrams",
                "fatGrams", "waterMilliliters",
            ])
    }

    func testUnknownFieldsAreTolerated() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(
                    try WatchSnapshotEnvelope(eraseGeneration: 1, snapshot: sample()).context()[
                        WatchSnapshotEnvelope.contextKey] as? Data)) as? [String: Any])
        object["addedLater"] = "x"
        let data = try JSONSerialization.data(withJSONObject: object)
        guard case .envelope = WatchSnapshotEnvelope.decode(context: [WatchSnapshotEnvelope.contextKey: data]) else {
            return XCTFail("an extra field must not break decoding")
        }
    }

    func testAnUnknownSchemaVersionIsReportedNotDecoded() throws {
        let newer = WatchSnapshotEnvelope(
            eraseGeneration: 1, snapshot: sample(), schemaVersion: WatchSnapshotEnvelope.currentSchemaVersion + 1)
        XCTAssertEqual(WatchSnapshotEnvelope.decode(context: try newer.context()), .unsupportedSchema)
    }

    func testMalformedMissingAndOversizedPayloadsAreInvalid() {
        XCTAssertEqual(WatchSnapshotEnvelope.decode(context: [:]), .invalid)
        XCTAssertEqual(WatchSnapshotEnvelope.decode(context: [WatchSnapshotEnvelope.contextKey: "text"]), .invalid)
        XCTAssertEqual(
            WatchSnapshotEnvelope.decode(context: [WatchSnapshotEnvelope.contextKey: Data("{".utf8)]), .invalid)
        let oversized = Data(repeating: 0x20, count: WatchSnapshotEnvelope.maximumPayloadBytes + 1)
        XCTAssertEqual(WatchSnapshotEnvelope.decode(context: [WatchSnapshotEnvelope.contextKey: oversized]), .invalid)
    }

    // MARK: Sender

    private final class MemoryState: WatchSenderState, @unchecked Sendable {
        var eraseGeneration = 0
        var eraseUnsent = false
    }

    func testASummaryIsSentWhenTheSessionCanSend() {
        let transport = FakeTransport()
        let sender = WatchSnapshotSender(transport: transport, state: MemoryState())
        sender.submit(sample(), erasureGeneration: 0)
        XCTAssertEqual(transport.lastEnvelope?.snapshot, sample())
    }

    func testASummaryIsHeldUntilTheSessionIsReady() {
        let transport = FakeTransport()
        transport.canSend = false
        let sender = WatchSnapshotSender(transport: transport, state: MemoryState())
        sender.submit(sample(), erasureGeneration: 0)
        XCTAssertTrue(transport.sent.isEmpty)
        transport.canSend = true
        sender.transportBecameReady()
        XCTAssertEqual(transport.sent.count, 1)
        sender.transportBecameReady()
        XCTAssertEqual(transport.sent.count, 1, "a sent envelope is not sent again")
    }

    func testAnEraseBeforeActivationReplacesTheHeldSummary() {
        let transport = FakeTransport()
        transport.canSend = false
        let sender = WatchSnapshotSender(transport: transport, state: MemoryState())
        sender.submit(sample(), erasureGeneration: 0)
        sender.erased(erasureGeneration: 1)
        transport.canSend = true
        sender.transportBecameReady()
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertNil(transport.lastEnvelope?.snapshot, "only the empty envelope is sent")
        XCTAssertEqual(transport.lastEnvelope?.eraseGeneration, 1)
    }

    func testASummaryFromBeforeAnEraseNeverReplacesTheEraseEvenOnceTheEraseWasSent() {
        let transport = FakeTransport()
        let sender = WatchSnapshotSender(transport: transport, state: MemoryState())
        sender.erased(erasureGeneration: 1)
        XCTAssertEqual(transport.sent.count, 1, "the erase went out at once")
        // A load announced before the erase reaches the sender after it: dropped, the erase stays the last context.
        sender.submit(sample(), erasureGeneration: 0)
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertNil(transport.lastEnvelope?.snapshot)
        // A load announced after the erase is sent, under the new generation.
        sender.submit(sample(), erasureGeneration: 1)
        XCTAssertEqual(transport.lastEnvelope?.snapshot, sample())
        XCTAssertEqual(transport.lastEnvelope?.eraseGeneration, 1)
    }

    func testAFailedSendIsKeptForTheNextAttempt() {
        let transport = FakeTransport()
        transport.fails = true
        let sender = WatchSnapshotSender(transport: transport, state: MemoryState())
        sender.erased(erasureGeneration: 1)
        XCTAssertTrue(transport.sent.isEmpty)
        transport.fails = false
        sender.transportBecameReady()
        XCTAssertEqual(transport.lastEnvelope?.eraseGeneration, 1)
    }

    func testAnEraseThatNeverReachedTheWatchIsSentAfterARelaunch() {
        let state = MemoryState()
        let first = FakeTransport()
        first.canSend = false
        WatchSnapshotSender(transport: first, state: state).erased(erasureGeneration: 1)
        XCTAssertTrue(state.eraseUnsent, "remembered while it is unsent")
        // The app is terminated; the next run reads the remembered state.
        let second = FakeTransport()
        second.canSend = false
        let relaunched = WatchSnapshotSender(transport: second, state: state)
        relaunched.resumeAfterLaunch()
        second.canSend = true
        relaunched.transportBecameReady()
        XCTAssertNil(second.lastEnvelope?.snapshot)
        XCTAssertEqual(second.lastEnvelope?.eraseGeneration, 1)
        XCTAssertFalse(state.eraseUnsent, "cleared once the Watch has been handed it")
    }

    func testTheEraseGenerationOnlyGoesUpAcrossRelaunches() {
        let state = MemoryState()
        WatchSnapshotSender(transport: FakeTransport(), state: state).erased(erasureGeneration: 1)
        let transport = FakeTransport()
        let relaunched = WatchSnapshotSender(transport: transport, state: state)
        relaunched.submit(sample(), erasureGeneration: 0)
        XCTAssertEqual(transport.lastEnvelope?.eraseGeneration, 1, "summaries carry the persisted generation")
        relaunched.erased(erasureGeneration: 1)
        XCTAssertEqual(transport.lastEnvelope?.eraseGeneration, 2)
    }

    func testConcurrentSubmissionsNeverLeaveAnOlderEnvelopeLast() {
        for _ in 0..<20 {
            let transport = FakeTransport()
            transport.delay = 0.01
            let sender = WatchSnapshotSender(transport: transport, state: MemoryState())
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) {
                sender.submit(self.sample(), erasureGeneration: 0)
            }
            DispatchQueue.global().async(group: group) {
                sender.erased(erasureGeneration: 1)
            }
            group.wait()
            // Whatever the interleaving, the last context the Watch was handed is the erase.
            XCTAssertEqual(transport.lastEnvelope?.eraseGeneration, 1)
            XCTAssertNil(transport.lastEnvelope?.snapshot)
        }
    }

    func testNothingIsSentWithoutATransport() {
        let sender = WatchSnapshotSender(transport: nil, state: MemoryState())
        sender.submit(sample(), erasureGeneration: 0)
        sender.erased(erasureGeneration: 1)
        sender.resumeAfterLaunch()
        sender.transportBecameReady()
    }

    // MARK: Erase

    func testEraseAllDataLeavesAnEmptyContextForTheWatch() throws {
        let transport = FakeTransport()
        let sender = WatchSnapshotSender(transport: transport, state: MemoryState())
        let erasure = WidgetSnapshotErasure()
        sender.submit(sample(), erasureGeneration: erasure.generation)
        try WidgetSnapshotEraser(store: nil, erasure: erasure, watch: sender).eraseAll()
        // What the Watch will be handed is the empty envelope under the new generation: nothing of the summary.
        let last = try XCTUnwrap(transport.lastEnvelope)
        XCTAssertNil(last.snapshot)
        XCTAssertEqual(last.eraseGeneration, 1)
    }
}
