import Foundation
import NutritionJournal
import XCTest
@testable import NutritionUI

private final class FakeCustomScheduler: ReminderScheduling, CustomReminderScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _permission: ReminderPermission = .notDetermined
    private var _answer = true
    private var _requests = 0
    private var _pending: [UUID: ReminderTime] = [:]
    private var _failure: Error?

    var permissionState: ReminderPermission {
        get { lock.withLock { _permission } }
        set { lock.withLock { _permission = newValue } }
    }
    var requestAnswer: Bool {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }
    var failure: Error? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
    var requests: Int { lock.withLock { _requests } }
    var pending: [UUID: ReminderTime] { lock.withLock { _pending } }

    func permission() async -> ReminderPermission { permissionState }
    func requestPermission() async -> Bool {
        lock.withLock {
            _requests += 1
            _permission = _answer ? .allowed : .denied
            return _answer
        }
    }
    func scheduleDaily(at time: ReminderTime) async throws {}
    func cancelDaily() {}
    func pendingDailyCount() async -> Int { 0 }

    func replaceAll(with reminders: [CustomReminder]) async throws {
        if let error = failure { throw error }
        lock.withLock { _pending = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0.time) }) }
    }
    func cancel(ids: [UUID]) {
        lock.withLock { ids.forEach { _pending[$0] = nil } }
    }
    func pendingCustomCount() async -> Int { lock.withLock { _pending.count } }
}

private final class MemoryStore: CustomReminderStoring {
    var reminders: [CustomReminder] = []
    func save(_ reminders: [CustomReminder]) { self.reminders = reminders }
    func clear() { reminders = [] }
}

@MainActor
final class CustomReminderControllerTests: XCTestCase {
    private func make(_ scheduler: FakeCustomScheduler, store: MemoryStore = MemoryStore(),
                      erasures: ReminderErasures = ReminderErasures()) -> CustomReminderController {
        CustomReminderController(store: store, permissions: scheduler, scheduler: scheduler, erasures: erasures)
    }

    func testAddingAskedOnceThenSchedulesBothKinds() async {
        let scheduler = FakeCustomScheduler()
        let controller = make(scheduler)
        await controller.add(.water)
        await controller.add(.supplement, at: ReminderTime(hour: 7, minute: 15))
        XCTAssertEqual(scheduler.requests, 1)
        XCTAssertEqual(scheduler.pending.count, 2)
        XCTAssertEqual(Set(scheduler.pending.values.map(\.hour)), [10, 7])
    }

    func testSwitchingOffRemovesOnlyThatRequest() async {
        let scheduler = FakeCustomScheduler()
        let controller = make(scheduler)
        await controller.add(.water)
        await controller.add(.supplement)
        let first = controller.reminders[0].id
        await controller.setOn(false, id: first)
        XCTAssertNil(scheduler.pending[first])
        XCTAssertEqual(scheduler.pending.count, 1)
        XCTAssertFalse(controller.reminders[0].isOn)
    }

    func testChangingTimeReplacesNeverAdds() async {
        let scheduler = FakeCustomScheduler()
        let controller = make(scheduler)
        await controller.add(.water)
        let id = controller.reminders[0].id
        await controller.setTime(ReminderTime(hour: 14, minute: 5), id: id)
        XCTAssertEqual(scheduler.pending.count, 1)
        XCTAssertEqual(scheduler.pending[id], ReminderTime(hour: 14, minute: 5))
    }

    func testRemoveCancelsAndForgets() async {
        let scheduler = FakeCustomScheduler()
        let controller = make(scheduler)
        await controller.add(.water)
        let id = controller.reminders[0].id
        await controller.remove(id: id)
        XCTAssertTrue(controller.reminders.isEmpty)
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    func testDeniedPermissionSwitchesRemindersOffWithMessage() async {
        let scheduler = FakeCustomScheduler()
        scheduler.requestAnswer = false
        let controller = make(scheduler)
        await controller.add(.water)
        XCTAssertTrue(scheduler.pending.isEmpty)
        XCTAssertFalse(controller.reminders[0].isOn)
        XCTAssertEqual(controller.message, CustomReminderController.withdrawnMessage)
    }

    func testSyncNeverAsksForPermission() async {
        let scheduler = FakeCustomScheduler()
        let store = MemoryStore()
        store.reminders = [CustomReminder(kind: .water, time: .standard)]
        let controller = make(scheduler, store: store)
        await controller.sync()
        XCTAssertEqual(scheduler.requests, 0)
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    func testEraseClearsStoreAndPending() async throws {
        let scheduler = FakeCustomScheduler()
        let store = MemoryStore()
        let erasures = ReminderErasures()
        let controller = make(scheduler, store: store, erasures: erasures)
        await controller.add(.water)
        try CustomReminderEraser(store: store, scheduler: scheduler, erasures: erasures).eraseAll()
        controller.refreshFromStore()
        XCTAssertTrue(store.reminders.isEmpty)
        XCTAssertTrue(scheduler.pending.isEmpty)
        XCTAssertTrue(controller.reminders.isEmpty)
    }

    func testListIsCapped() async {
        let scheduler = FakeCustomScheduler()
        scheduler.permissionState = .allowed
        let controller = make(scheduler)
        for _ in 0..<(CustomReminderController.maximumCount + 3) { await controller.add(.water) }
        XCTAssertEqual(controller.reminders.count, CustomReminderController.maximumCount)
    }

    func testStoreRoundTripAndUnreadableData() {
        let defaults = UserDefaults(suiteName: "custom-reminders-test-\(UUID().uuidString)")!
        let store = UserDefaultsCustomReminderStore(defaults: defaults)
        XCTAssertTrue(store.reminders.isEmpty)
        let reminder = CustomReminder(kind: .supplement, time: ReminderTime(hour: 6, minute: 45))
        store.save([reminder])
        XCTAssertEqual(store.reminders, [reminder])
        defaults.set(Data("not json".utf8), forKey: UserDefaultsCustomReminderStore.key)
        XCTAssertTrue(store.reminders.isEmpty)
    }
}
