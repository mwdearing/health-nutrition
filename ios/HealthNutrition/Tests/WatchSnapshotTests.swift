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
        private(set) var sent: [[String: Any]] = []
        func send(context: [String: Any]) throws {
            if fails { throw Refused() }
            sent.append(context)
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

    func testASummaryIsSentWhenTheSessionCanSend() {
        let transport = FakeTransport()
        let sender = WatchSnapshotSender(transport: transport)
        sender.submit(WatchSnapshotEnvelope(eraseGeneration: 0, snapshot: sample()))
        XCTAssertEqual(transport.lastEnvelope?.snapshot, sample())
    }

    func testASummaryIsHeldUntilTheSessionIsReady() {
        let transport = FakeTransport()
        transport.canSend = false
        let sender = WatchSnapshotSender(transport: transport)
        sender.submit(WatchSnapshotEnvelope(eraseGeneration: 0, snapshot: sample()))
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
        let sender = WatchSnapshotSender(transport: transport)
        sender.submit(WatchSnapshotEnvelope(eraseGeneration: 0, snapshot: sample()))
        sender.erased(generation: 1)
        transport.canSend = true
        sender.transportBecameReady()
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertNil(transport.lastEnvelope?.snapshot, "only the empty envelope is sent")
        XCTAssertEqual(transport.lastEnvelope?.eraseGeneration, 1)
    }

    func testASummaryFromBeforeAnEraseNeverReplacesTheErase() {
        let transport = FakeTransport()
        transport.canSend = false
        let sender = WatchSnapshotSender(transport: transport)
        sender.erased(generation: 2)
        sender.submit(WatchSnapshotEnvelope(eraseGeneration: 1, snapshot: sample()))
        transport.canSend = true
        sender.transportBecameReady()
        XCTAssertNil(transport.lastEnvelope?.snapshot)
        XCTAssertEqual(transport.lastEnvelope?.eraseGeneration, 2)
    }

    func testAFailedSendIsKeptForTheNextAttempt() {
        let transport = FakeTransport()
        transport.fails = true
        let sender = WatchSnapshotSender(transport: transport)
        sender.erased(generation: 1)
        XCTAssertTrue(transport.sent.isEmpty)
        transport.fails = false
        sender.transportBecameReady()
        XCTAssertEqual(transport.lastEnvelope?.eraseGeneration, 1)
    }

    func testNothingIsSentWithoutATransport() {
        let sender = WatchSnapshotSender(transport: nil)
        sender.submit(WatchSnapshotEnvelope(eraseGeneration: 0, snapshot: sample()))
        sender.erased(generation: 1)
        sender.transportBecameReady()
    }

    // MARK: Erase

    func testEraseAllDataLeavesAnEmptyContextForTheWatch() throws {
        let transport = FakeTransport()
        let sender = WatchSnapshotSender(transport: transport)
        let erasure = WidgetSnapshotErasure()
        sender.submit(WatchSnapshotEnvelope(eraseGeneration: erasure.generation, snapshot: sample()))
        try WidgetSnapshotEraser(store: nil, erasure: erasure, watch: sender).eraseAll()
        // What the Watch will be handed is the empty envelope under the new generation: nothing of the summary.
        let last = try XCTUnwrap(transport.lastEnvelope)
        XCTAssertNil(last.snapshot)
        XCTAssertEqual(last.eraseGeneration, 1)
    }
}
