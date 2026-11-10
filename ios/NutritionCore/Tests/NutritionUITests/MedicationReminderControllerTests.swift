import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

private final class FakeMedicationReminderScheduler: ReminderScheduling, MedicationReminderScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _permission: ReminderPermission = .notDetermined
    private var _answer = true
    private var _asks = 0
    private var _pending: [MedicationReminderRequest] = []
    private var _cancels = 0
    private var _failure: Error?

    var permissionState: ReminderPermission {
        get { lock.withLock { _permission } }
        set { lock.withLock { _permission = newValue } }
    }
    var answer: Bool {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }
    var failure: Error? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
    var asks: Int { lock.withLock { _asks } }
    var pending: [MedicationReminderRequest] { lock.withLock { _pending } }
    var cancels: Int { lock.withLock { _cancels } }

    func permission() async -> ReminderPermission { permissionState }
    func requestPermission() async -> Bool {
        lock.withLock {
            _asks += 1
            _permission = _answer ? .allowed : .denied
            return _answer
        }
    }
    func scheduleDaily(at time: ReminderTime) async throws {}
    func cancelDaily() {}
    func pendingDailyCount() async -> Int { 0 }

    func replaceAll(with requests: [MedicationReminderRequest]) async throws {
        if let error = failure { throw error }
        lock.withLock { _pending = requests }
    }
    func cancelAll() {
        lock.withLock {
            _cancels += 1
            _pending = []
        }
    }
}

private struct Refused: Error {}

private struct FakeCenter: PendingReminderCenter {
    let identifiers: [String]
    func pendingRequestIdentifiers() async -> [String] { identifiers }
}

/// The medication reminder settings and the system's pending requests: switching one on asks for permission only
/// when it is not decided, a sync never asks, the Medication log switch and the medication's state decide what is
/// pending, and Erase all data removes the settings and every pending request.
@MainActor
final class MedicationReminderControllerTests: XCTestCase {
    /// 2026-04-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_776_254_400)
    private let utc = TimeZone(identifier: "UTC")!
    private let medication = Medication(name: "Example weekly injection", unit: .mg, scheduleDays: 7)

    private func make(
        _ scheduler: FakeMedicationReminderScheduler, store: InMemoryMedicationReminderStore = InMemoryMedicationReminderStore(),
        logIsOn: Bool = true, erasures: ReminderErasures = ReminderErasures()
    ) throws -> (MedicationReminderController, InMemoryMedicationStore, InMemoryDisplayPreferences) {
        let medications = InMemoryMedicationStore()
        try medications.saveMedication(medication)
        try medications.saveDose(MedicationDose(
            medicationID: medication.id, takenAt: now.addingTimeInterval(-5 * 86_400), timeZoneIdentifier: "UTC",
            amount: 2.5, unit: .mg))
        let preferences = InMemoryDisplayPreferences()
        preferences.setMedicationLogOn(logIsOn)
        let fixed = now
        let zone = utc
        let controller = MedicationReminderController(
            store: store, permissions: scheduler, scheduler: scheduler, medications: medications,
            preferences: preferences, erasures: erasures, now: { fixed }, timeZone: { zone })
        return (controller, medications, preferences)
    }

    func testSwitchingOnAsksOnceAndSchedulesTheNextDueDay() async throws {
        let scheduler = FakeMedicationReminderScheduler()
        let (controller, _, _) = try make(scheduler)
        await controller.setReminder(ReminderTime(hour: 8, minute: 0), for: medication.id)
        XCTAssertEqual(scheduler.asks, 1)
        XCTAssertEqual(controller.time(for: medication.id), ReminderTime(hour: 8, minute: 0))
        XCTAssertEqual(scheduler.pending.map(\.day), [CalendarDay(year: 2026, month: 4, day: 17)])
        XCTAssertNil(controller.message)
        await controller.setReminder(ReminderTime(hour: 9, minute: 0), for: medication.id)
        XCTAssertEqual(scheduler.asks, 1, "asked only while not decided")
        XCTAssertEqual(scheduler.pending.map(\.time), [ReminderTime(hour: 9, minute: 0)])
    }

    func testADeniedAnswerLeavesItOffWithTheMessage() async throws {
        let scheduler = FakeMedicationReminderScheduler()
        scheduler.answer = false
        let (controller, _, _) = try make(scheduler)
        await controller.setReminder(ReminderTime(hour: 8, minute: 0), for: medication.id)
        XCTAssertNil(controller.time(for: medication.id))
        XCTAssertEqual(controller.message, ReminderController.withdrawnMessage)
        XCTAssertEqual(scheduler.pending, [])
    }

    func testARefusedRequestTurnsItOffWithTheMessage() async throws {
        let scheduler = FakeMedicationReminderScheduler()
        scheduler.permissionState = .allowed
        scheduler.failure = Refused()
        let (controller, _, _) = try make(scheduler)
        await controller.setReminder(ReminderTime(hour: 8, minute: 0), for: medication.id)
        XCTAssertNil(controller.time(for: medication.id))
        XCTAssertEqual(controller.message, MedicationReminderController.refusedMessage)
    }

    func testSyncNeverAsksAndSchedulesTheStoredSettingWhenAllowed() async throws {
        let undecided = FakeMedicationReminderScheduler()
        let first = InMemoryMedicationReminderStore()
        first.save([MedicationReminderSetting(medicationID: medication.id, time: ReminderTime(hour: 8, minute: 0))])
        let (notAsked, _, _) = try make(undecided, store: first)
        await notAsked.sync()
        XCTAssertEqual(undecided.asks, 0)
        XCTAssertEqual(undecided.pending, [])

        let allowed = FakeMedicationReminderScheduler()
        allowed.permissionState = .allowed
        let second = InMemoryMedicationReminderStore()
        second.save([MedicationReminderSetting(medicationID: medication.id, time: ReminderTime(hour: 8, minute: 0))])
        let (controller, _, _) = try make(allowed, store: second)
        await controller.sync()
        XCTAssertEqual(allowed.asks, 0)
        XCTAssertEqual(allowed.pending.map(\.day), [CalendarDay(year: 2026, month: 4, day: 17)])
    }

    func testSyncWithNotificationsWithdrawnSwitchesThemOffWithTheMessage() async throws {
        let scheduler = FakeMedicationReminderScheduler()
        scheduler.permissionState = .allowed
        let (controller, _, _) = try make(scheduler)
        await controller.setReminder(ReminderTime(hour: 8, minute: 0), for: medication.id)
        scheduler.permissionState = .denied
        await controller.sync()
        XCTAssertEqual(scheduler.pending, [])
        XCTAssertNil(controller.time(for: medication.id))
        XCTAssertEqual(controller.message, ReminderController.withdrawnMessage)
    }

    func testTheLogSwitchOffRemovesThePendingRequestAndKeepsTheSetting() async throws {
        let scheduler = FakeMedicationReminderScheduler()
        scheduler.permissionState = .allowed
        let (controller, _, preferences) = try make(scheduler)
        await controller.setReminder(ReminderTime(hour: 8, minute: 0), for: medication.id)
        XCTAssertEqual(scheduler.pending.count, 1)
        preferences.setMedicationLogOn(false)
        await controller.sync()
        XCTAssertEqual(scheduler.pending, [])
        XCTAssertEqual(controller.time(for: medication.id), ReminderTime(hour: 8, minute: 0))
    }

    func testANewDoseMovesTheReminderAndADeletedMedicationDropsIt() async throws {
        let scheduler = FakeMedicationReminderScheduler()
        scheduler.permissionState = .allowed
        let (controller, medications, _) = try make(scheduler)
        await controller.setReminder(ReminderTime(hour: 8, minute: 0), for: medication.id)
        try medications.saveDose(MedicationDose(
            medicationID: medication.id, takenAt: now, timeZoneIdentifier: "UTC", amount: 2.5, unit: .mg))
        await controller.sync()
        XCTAssertEqual(scheduler.pending.map(\.day), [CalendarDay(year: 2026, month: 4, day: 22)])
        try medications.removeMedication(id: medication.id)
        await controller.sync()
        XCTAssertEqual(scheduler.pending, [])
        XCTAssertNil(controller.time(for: medication.id))
    }

    func testSwitchingOffRemovesIt() async throws {
        let scheduler = FakeMedicationReminderScheduler()
        scheduler.permissionState = .allowed
        let (controller, _, _) = try make(scheduler)
        await controller.setReminder(ReminderTime(hour: 8, minute: 0), for: medication.id)
        await controller.setReminder(nil, for: medication.id)
        XCTAssertNil(controller.time(for: medication.id))
        XCTAssertEqual(scheduler.pending, [])
    }

    func testEraseRemovesTheSettingsAndEveryPendingRequest() async throws {
        let scheduler = FakeMedicationReminderScheduler()
        scheduler.permissionState = .allowed
        let store = InMemoryMedicationReminderStore()
        let erasures = ReminderErasures()
        let (controller, _, _) = try make(scheduler, store: store, erasures: erasures)
        await controller.setReminder(ReminderTime(hour: 8, minute: 0), for: medication.id)
        let eraser = MedicationReminderEraser(store: store, scheduler: scheduler, erasures: erasures)
        XCTAssertEqual(eraser.erasureName, "medication reminders")
        eraser.eraseAll()
        controller.refreshFromStore()
        XCTAssertEqual(store.settings, [])
        XCTAssertGreaterThanOrEqual(scheduler.cancels, 1)
        XCTAssertEqual(scheduler.pending, [])
        XCTAssertNil(controller.time(for: medication.id))
    }

    func testTheEraseReadbackNamesAMedicationReminderStillPending() async {
        let center = FakeCenter(identifiers: [MedicationReminderPlan.identifierPrefix + UUID().uuidString])
        let names = await ReminderReadback.namesStillPending(in: center, pause: {})
        XCTAssertEqual(names, ["medication reminders"])
    }
}
