import Foundation
import NutritionDomain
import NutritionJournal
import NutritionUI
import XCTest

@testable import HealthNutrition

/// Apple Health delivery as the app wires it in every build: the store `AppServices` opens, the real
/// snapshot totals, and the driver's automatic runs. HealthKit itself is replaced by a writer that
/// records what it was handed; the real save, the permission sheet and Health's per-type answers need
/// a device.
@MainActor
final class AppleHealthDeliveryTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    /// Allows every type and keeps what it was asked to save.
    private final class RecordingWriter: HealthSampleWriter, @unchecked Sendable {
        private let lock = NSLock()
        private var specs: [HealthKitSampleSpec] = []
        var saved: [HealthKitSampleSpec] { lock.withLock { specs } }

        func canWrite(identifiers: [String]) async -> [String: Bool] {
            Dictionary(uniqueKeysWithValues: identifiers.map { ($0, true) })
        }
        func deniedWriteTypes(identifiers: [String]) async -> Set<String> { [] }
        func save(_ specs: [HealthKitSampleSpec]) async throws { lock.withLock { self.specs += specs } }
        func deleteSamples(syncIdentifiers: [String]) async throws -> Int { 0 }
    }

    private final class AccessBox {
        var access = AppleHealthAccess(undetermined: 0, authorized: 0, denied: 15)
    }

    private func makeServices() throws -> AppServices {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleHealthDeliveryTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try AppServices.make(directory: directory, reminderScheduler: RecordingReminderScheduler())
    }

    private func worker(_ services: AppServices, writer: RecordingWriter) -> HealthKitDeliveryWorker {
        let totals = JournalSnapshotTotals(store: services.journalStore)
        return HealthKitDeliveryWorker(
            store: services.journalStore, writer: writer,
            totals: { intakeID, revision in try await totals.totals(intakeID: intakeID, revision: revision) })
    }

    /// Every build now queues HealthKit work, so an entry logged before the person connects is written
    /// when they do. The relay destination stays off.
    func testTheAppStoreQueuesHealthKitWorkAndNoRelayWork() throws {
        let services = try makeServices()
        try services.journalStore.create(
            Intake(id: UUID().uuidString.lowercased(), category: "water", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "water", name: "Water", amount: 250, unit: .mL)],
            product: nil, now: when)

        XCTAssertEqual(Set(try services.journalStore.pendingOutbox().map(\.destination)), [.healthKit])
    }

    /// The "does it actually write" check: a glass of water and a scaled portion of a labelled food,
    /// logged through the app's own store, reach the writer as water, protein and a mineral in Health's
    /// units, with the label's per-100 g values scaled to the 40 g logged.
    func testLoggedWaterAndScaledFoodNutrientsAreWrittenToHealth() async throws {
        let services = try makeServices()
        let waterID = "0f6c1a52-7a43-4b1e-9d58-2b7e3c4d5a61"
        let foodID = "5d2e8b17-3c49-4f0a-8e61-7a9b0c1d2e3f"
        try services.journalStore.create(
            Intake(id: waterID, category: "water", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "water", name: "Water", amount: 250, unit: .mL)],
            product: nil, now: when)
        let oats = ProductDefinition(
            snapshotID: "snap-1", productID: "product-1", name: "Sample oats", brand: nil, barcode: nil,
            labelBasis: "per100g", catalogOrigin: "sample", catalogVersion: "1",
            nutrients: [
                "protein": .known(Decimal(13), .g),
                "calcium": .known(Decimal(50), .mg),
            ])
        try services.journalStore.create(
            Intake(id: foodID, category: "food", occurredAt: when, timeZoneIdentifier: "UTC", meal: "breakfast"),
            components: [IntakeComponent(componentID: "oats", name: "Rolled oats", amount: 40, unit: .g)],
            product: oats, now: when)
        let writer = RecordingWriter()

        _ = await worker(services, writer: writer).runOnce(now: when)

        let written = Dictionary(uniqueKeysWithValues: writer.saved.map { ($0.syncIdentifier, $0) })
        XCTAssertEqual(written["intake:\(waterID):water"]?.amount, Decimal(250))
        XCTAssertEqual(written["intake:\(waterID):water"]?.unitSymbol, "mL")
        XCTAssertEqual(written["intake:\(foodID):protein"]?.amount, Decimal(string: "5.2"), "13 g per 100 g, 40 g logged")
        XCTAssertEqual(written["intake:\(foodID):protein"]?.unitSymbol, "g")
        XCTAssertEqual(written["intake:\(foodID):calcium"]?.amount, Decimal(20), "50 mg per 100 g, 40 g logged")
        XCTAssertEqual(written["intake:\(foodID):calcium"]?.unitSymbol, "mg")
        XCTAssertTrue(try services.journalStore.pendingOutbox().isEmpty, "both deliveries were acknowledged")
    }

    /// An entry parked by "Don't Allow" is delivered once the person allows Health in the Health app:
    /// the next automatic run sees the changed access and re-arms it. While access is unchanged the
    /// suspension stands, so a refused type is not retried on every foreground.
    func testAccessChangedInTheHealthAppReArmsWhatADenialParked() async throws {
        let services = try makeServices()
        let box = AccessBox()
        let status = HealthKitDeliveryStatus(
            healthKitDelivery: worker(services, writer: RecordingWriter()), store: services.journalStore,
            authorizationProbe: { .requested }, accessProbe: { box.access })
        await status.run(now: when, automatic: true)

        try services.journalStore.create(
            Intake(id: UUID().uuidString.lowercased(), category: "water", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "water", name: "Water", amount: 250, unit: .mL)],
            product: nil, now: when)
        let operation = try XCTUnwrap(try services.journalStore.pendingOutbox().first)
        try services.journalStore.recordFailure(
            operationID: operation.operationID, retryAt: nil, needsAttention: true,
            reason: "HealthKit access is not granted, so it cannot be written")

        await status.run(now: when, automatic: true)
        XCTAssertEqual(status.counts.suspended, 1, "nothing changed in Health, so the suspension stands")

        box.access = AppleHealthAccess(undetermined: 0, authorized: 15, denied: 0)
        await status.run(now: when, automatic: true)

        XCTAssertEqual(status.counts.suspended, 0)
        XCTAssertEqual(status.counts.pending, 0, "the re-armed operation was delivered in the same pass")
        XCTAssertTrue(status.lastRunLines.contains { $0.hasPrefix("delivered \(operation.operationID)") })
    }

    /// Turning one type on and another off leaves the counts equal; the set of allowed types still
    /// differs, so the parked entry is re-armed.
    func testSwappingWhichTypesAreAllowedReArmsWhatADenialParked() async throws {
        let services = try makeServices()
        let box = AccessBox()
        box.access = AppleHealthAccess(undetermined: 0, authorized: 1, denied: 1, authorizedTypes: ["protein"])
        let status = HealthKitDeliveryStatus(
            healthKitDelivery: worker(services, writer: RecordingWriter()), store: services.journalStore,
            authorizationProbe: { .requested }, accessProbe: { box.access })
        await status.run(now: when, automatic: true)
        try services.journalStore.create(
            Intake(id: UUID().uuidString.lowercased(), category: "water", occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "water", name: "Water", amount: 250, unit: .mL)],
            product: nil, now: when)
        let operation = try XCTUnwrap(try services.journalStore.pendingOutbox().first)
        try services.journalStore.recordFailure(
            operationID: operation.operationID, retryAt: nil, needsAttention: true,
            reason: "HealthKit access is not granted, so it cannot be written")

        box.access = AppleHealthAccess(undetermined: 0, authorized: 1, denied: 1, authorizedTypes: ["water"])
        await status.run(now: when, automatic: true)

        XCTAssertEqual(status.counts.suspended, 0)
        XCTAssertTrue(status.lastRunLines.contains { $0.hasPrefix("delivered \(operation.operationID)") })
    }

    /// Settings' row reads the same driver, so what it shows is Health's answer.
    func testTheSettingsRowReflectsTheDriversAccess() throws {
        let services = try makeServices()
        let box = AccessBox()
        box.access = AppleHealthAccess(undetermined: 15, authorized: 0, denied: 0)
        let status = HealthKitDeliveryStatus(
            healthKitDelivery: services.healthKitDelivery, store: services.journalStore,
            authorizationProbe: { .notRequested }, accessProbe: { box.access })
        let row = AppleHealthConnectionViewModel(connector: status)

        XCTAssertEqual(row.state, .notConnected)
        XCTAssertEqual(row.actionTitle, "Connect Apple Health")
    }
}
