#if DEBUG
import Foundation
import NutritionDomain
import NutritionJournal
import XCTest

@testable import HealthNutrition

/// The DEBUG-only HealthKit delivery wiring, read from inside the app target.
///
/// What is checked here is only what can be checked without a device: that a debug build's store
/// actually queues HealthKit operations (which is what gives the worker something to deliver), and
/// that each outcome is reported in plain text. The delivery itself, the authorization prompt and the
/// counts a real HealthKit failure produces need a device and are not covered here.
@MainActor
final class HealthKitDeliveryDebugTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)
    private let intakeID = "9b2d4f60-1c73-4a58-8f21-6d0c5a7e93b4"

    /// A fresh directory per test, so a store one test wrote is never read by another and the app's
    /// real Application Support files are never touched.
    private func makeServices() throws -> AppServices {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionDebugTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try AppServices.make(directory: directory)
    }

    private func sampleIntake() -> Intake {
        Intake(id: intakeID, category: "water", occurredAt: when, timeZoneIdentifier: "UTC")
    }

    private func sampleComponent() -> IntakeComponent {
        IntakeComponent(componentID: "water", name: "Water", amount: 250, unit: .mL)
    }

    /// A debug build's journal store queues HealthKit operations, which is the whole point of the
    /// build: with nothing queued the worker has nothing to deliver and the device run proves nothing.
    /// The relay destination stays off, so no operation for it is ever written.
    func testADebugBuildQueuesHealthKitOperationsAndNoRelayOnes() throws {
        let services = try makeServices()

        try services.journalStore.create(sampleIntake(), components: [sampleComponent()], product: nil, now: when)

        let destinations = Set(try services.journalStore.pendingOutbox().map(\.destination))
        XCTAssertEqual(destinations, [.healthKit])
    }

    /// The status counts the debug section shows are read from the queue, so an entry that was just
    /// added shows as pending before any delivery has run.
    func testTheStatusCountsWhatIsQueued() throws {
        let services = try makeServices()
        let status = HealthKitDeliveryStatus(
            healthKitDelivery: services.healthKitDelivery, store: services.journalStore)

        status.refresh()
        XCTAssertEqual(status.counts.pending, 0)

        try services.journalStore.create(sampleIntake(), components: [sampleComponent()], product: nil, now: when)

        status.refresh()
        XCTAssertEqual(status.counts.pending, 1)
        XCTAssertEqual(status.counts.needsAttention, 0)
        XCTAssertEqual(status.counts.suspended, 0)
    }

    /// A delivery that failed in a way only a person can fix is parked: the operation stops being
    /// attempted, the projection is left for a person, and both numbers on screen say so.
    func testAParkedOperationIsCountedAsNeedingAttentionAndSuspended() throws {
        let services = try makeServices()
        let status = HealthKitDeliveryStatus(
            healthKitDelivery: services.healthKitDelivery, store: services.journalStore)
        try services.journalStore.create(sampleIntake(), components: [sampleComponent()], product: nil, now: when)

        let operation = try XCTUnwrap(try services.journalStore.pendingOutbox().first)
        try services.journalStore.recordFailure(
            operationID: operation.operationID, retryAt: nil, needsAttention: true,
            reason: "HealthKit access is not granted, so it cannot be written")

        status.refresh()
        XCTAssertEqual(status.counts.pending, 1)
        XCTAssertEqual(status.counts.needsAttention, 1)
        XCTAssertEqual(status.counts.suspended, 1)
    }

    /// Every outcome is reported in plain text naming the operation, so a device run's failures and
    /// retries are readable on screen and a copied transcript says what happened.
    func testEveryOutcomeIsReportedInPlainText() {
        let outcomes: [HealthKitDeliveryOutcome] = [
            .delivered(operationID: "op-1", samples: 2),
            .retracted(operationID: "op-2", samples: 1),
            .partlyRetracted(operationID: "op-3", samples: 1, denied: ["HKQuantityTypeIdentifierDietaryWater"]),
            .superseded(operationID: "op-4"),
            .notDue(operationID: "op-5", nextAttemptAt: when),
            .blocked(operationID: "op-6", blockedBy: "op-5"),
            .needsAttention(operationID: "op-7", reason: "HealthKit access is not granted"),
            .retryScheduled(operationID: "op-8", nextAttemptAt: when, reason: "a store error"),
            .notAcknowledged(operationID: "op-9", detail: "the journal could not record the delivery"),
        ]
        let lines = outcomes.map(HealthKitDeliveryStatus.line(for:))

        XCTAssertEqual(lines.count, 9)
        for line in lines {
            XCTAssertFalse(line.isEmpty)
        }
        XCTAssertEqual(
            lines[0], "delivered op-1: 2 sample(s) written")
        XCTAssertEqual(
            lines[2],
            "partly retracted op-3: 1 removed, still in Health for HKQuantityTypeIdentifierDietaryWater")
        XCTAssertEqual(
            lines[6], "needs attention op-7: HealthKit access is not granted")
        XCTAssertTrue(lines[7].hasPrefix("retry scheduled op-8: a store error; next attempt at "))
    }
}
#endif