import Foundation
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A reminder scheduler that records every call and answers from settable state. It models the
/// one-request-per-identifier rule: scheduling again replaces the pending request rather than adding one.
private final class FakeReminderScheduler: ReminderScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var currentPermission: ReminderPermission = .notDetermined
    private var answer = true
    private var requests = 0
    private var scheduled: [ReminderTime] = []
    private var cancels = 0
    private var pending: ReminderTime?
    private var failure: Error?
    private var hook: (@Sendable () async -> Void)?
    private var schedulingHook: (@Sendable () async -> Void)?

    /// Run while `scheduleDaily` is in flight, before it records the request.
    var whileScheduling: (@Sendable () async -> Void)? {
        get { locked { schedulingHook } }
        set { locked { schedulingHook = newValue } }
    }

    /// Run while `permission()` is answering, to model a second tap landing mid-await.
    var whilePermissionIsAnswering: (@Sendable () async -> Void)? {
        get { locked { hook } }
        set { locked { hook = newValue } }
    }

    /// When set, `scheduleDaily` throws it and schedules nothing.
    var scheduleFailure: Error? {
        get { locked { failure } }
        set { locked { failure = newValue } }
    }

    var settablePermission: ReminderPermission {
        get { locked { currentPermission } }
        set { locked { currentPermission = newValue } }
    }

    /// What the simulated system prompt answers when it is asked.
    var requestAnswer: Bool {
        get { locked { answer } }
        set { locked { answer = newValue } }
    }

    var permissionRequestCount: Int { locked { requests } }
    var scheduledTimes: [ReminderTime] { locked { scheduled } }
    var cancelCount: Int { locked { cancels } }
    var pendingTime: ReminderTime? { locked { pending } }

    func permission() async -> ReminderPermission {
        if let hook = whilePermissionIsAnswering { await hook() }
        return locked { currentPermission }
    }

    func requestPermission() async -> Bool {
        locked {
            requests += 1
            currentPermission = answer ? .allowed : .denied
            return answer
        }
    }

    func scheduleDaily(at time: ReminderTime) async throws {
        if let hook = whileScheduling { await hook() }
        if let error = scheduleFailure { throw error }
        locked {
            scheduled.append(time)
            pending = time
        }
    }

    func cancelDaily() {
        locked {
            cancels += 1
            pending = nil
        }
    }

    func pendingDailyCount() async -> Int {
        locked { pending == nil ? 0 : 1 }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private let withdrawnMessage =
    "Notifications are turned off for this app. You can allow them in the iPhone Settings app."

/// The daily reminder's controller: the permission prompt, the single pending request and the launch
/// sync, checked against a fake scheduler and an in-memory preference store.
@MainActor
final class ReminderControllerTests: XCTestCase {
    private let sevenThirty = ReminderTime(hour: 7, minute: 30)

    private func makeController(
        _ scheduler: FakeReminderScheduler, preferences: InMemoryDisplayPreferences = InMemoryDisplayPreferences()
    ) -> (ReminderController, InMemoryDisplayPreferences) {
        (ReminderController(preferences: preferences, scheduler: scheduler), preferences)
    }

    func testReminderIsOffByDefaultAndSchedulesNothing() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .notDetermined
        let (controller, _) = makeController(scheduler)

        XCTAssertFalse(controller.isOn)
        XCTAssertEqual(controller.time, ReminderTime.standard)
        XCTAssertNil(controller.message)

        await controller.syncOnLaunch()

        XCTAssertFalse(controller.isOn)
        XCTAssertEqual(scheduler.scheduledTimes, [])
        XCTAssertEqual(scheduler.permissionRequestCount, 0)
        XCTAssertEqual(scheduler.cancelCount, 0)
        XCTAssertNil(scheduler.pendingTime)
    }

    func testSyncOnLaunchNeverRequestsPermission() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .notDetermined

        let (off, _) = makeController(scheduler)
        await off.syncOnLaunch()

        let storedOn = InMemoryDisplayPreferences()
        storedOn.setReminderOn(true)
        let (on, _) = makeController(scheduler, preferences: storedOn)
        await on.syncOnLaunch()

        XCTAssertEqual(scheduler.permissionRequestCount, 0)
    }

    func testTurningOnAsksOnceWhenNotDetermined() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .notDetermined
        scheduler.requestAnswer = true
        let (controller, preferences) = makeController(scheduler)

        await controller.setOn(true)
        XCTAssertEqual(scheduler.permissionRequestCount, 1)
        XCTAssertTrue(controller.isOn)
        XCTAssertTrue(preferences.isReminderOn)

        // Once allowed, switching off and on again does not ask a second time.
        await controller.setOn(false)
        await controller.setOn(true)
        XCTAssertEqual(scheduler.permissionRequestCount, 1)
    }

    func testTurningOnSchedulesAtTheDefaultTime() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .notDetermined
        scheduler.requestAnswer = true
        let (controller, _) = makeController(scheduler)

        await controller.setOn(true)

        XCTAssertEqual(scheduler.scheduledTimes, [ReminderTime.standard])
        XCTAssertEqual(scheduler.pendingTime, ReminderTime(hour: 20, minute: 0))
        XCTAssertNil(controller.message)
    }

    func testTurningOnWhenDeniedStaysOffWithMessageAndSchedulesNothing() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .denied
        let (controller, preferences) = makeController(scheduler)

        await controller.setOn(true)

        XCTAssertEqual(scheduler.permissionRequestCount, 0)
        XCTAssertFalse(controller.isOn)
        XCTAssertFalse(preferences.isReminderOn)
        XCTAssertEqual(controller.message, withdrawnMessage)
        XCTAssertEqual(scheduler.scheduledTimes, [])
        XCTAssertNil(scheduler.pendingTime)
    }

    func testRefusingThePromptStaysOffWithMessageAndSchedulesNothing() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .notDetermined
        scheduler.requestAnswer = false
        let (controller, preferences) = makeController(scheduler)

        await controller.setOn(true)

        XCTAssertEqual(scheduler.permissionRequestCount, 1)
        XCTAssertFalse(controller.isOn)
        XCTAssertFalse(preferences.isReminderOn)
        XCTAssertEqual(controller.message, withdrawnMessage)
        XCTAssertNil(scheduler.pendingTime)
    }

    func testChangingTheTimeWhileOnReplacesTheSingleRequest() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .allowed
        let (controller, preferences) = makeController(scheduler)
        await controller.setOn(true)
        do { let pending = await scheduler.pendingDailyCount(); XCTAssertEqual(pending, 1) }

        await controller.setTime(sevenThirty)

        do { let pending = await scheduler.pendingDailyCount(); XCTAssertEqual(pending, 1) }
        XCTAssertEqual(scheduler.pendingTime, sevenThirty)
        XCTAssertEqual(scheduler.scheduledTimes, [ReminderTime.standard, sevenThirty])
        XCTAssertEqual(controller.time, sevenThirty)
        XCTAssertEqual(preferences.reminderTime, sevenThirty)
    }

    func testChangingTheTimeWhileOffOnlyStoresIt() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .allowed
        let (controller, preferences) = makeController(scheduler)

        await controller.setTime(sevenThirty)

        XCTAssertFalse(controller.isOn)
        XCTAssertFalse(preferences.isReminderOn)
        XCTAssertEqual(preferences.reminderTime, sevenThirty)
        XCTAssertEqual(scheduler.scheduledTimes, [])
        XCTAssertNil(scheduler.pendingTime)
    }

    func testTurningOffCancels() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .allowed
        let (controller, preferences) = makeController(scheduler)
        await controller.setOn(true)
        XCTAssertNotNil(scheduler.pendingTime)

        await controller.setOn(false)

        XCTAssertFalse(controller.isOn)
        XCTAssertFalse(preferences.isReminderOn)
        XCTAssertGreaterThanOrEqual(scheduler.cancelCount, 1)
        do { let pending = await scheduler.pendingDailyCount(); XCTAssertEqual(pending, 0) }
    }

    func testSyncOnLaunchReschedulesOnceWhenOnAndAllowed() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .allowed
        let preferences = InMemoryDisplayPreferences()
        preferences.setReminderOn(true)
        preferences.setReminderTime(sevenThirty)
        let controller = ReminderController(preferences: preferences, scheduler: scheduler)

        await controller.syncOnLaunch()

        XCTAssertEqual(scheduler.scheduledTimes, [sevenThirty])
        do { let pending = await scheduler.pendingDailyCount(); XCTAssertEqual(pending, 1) }
        XCTAssertTrue(controller.isOn)
        XCTAssertNil(controller.message)
        XCTAssertEqual(scheduler.permissionRequestCount, 0)
    }

    func testSyncOnLaunchTurnsTheSettingOffWhenPermissionWasWithdrawn() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .denied
        let preferences = InMemoryDisplayPreferences()
        preferences.setReminderOn(true)
        let controller = ReminderController(preferences: preferences, scheduler: scheduler)

        await controller.syncOnLaunch()

        XCTAssertFalse(controller.isOn)
        XCTAssertFalse(preferences.isReminderOn)
        XCTAssertEqual(controller.message, withdrawnMessage)
        XCTAssertGreaterThanOrEqual(scheduler.cancelCount, 1)
        XCTAssertEqual(scheduler.scheduledTimes, [])
        XCTAssertEqual(scheduler.permissionRequestCount, 0)
    }

    func testRefreshFromPreferencesReadsTheStoredValues() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .allowed
        let (controller, preferences) = makeController(scheduler)
        await controller.setOn(true)
        await controller.setTime(sevenThirty)

        // What an erase leaves behind: both stored values back at their defaults.
        preferences.resetToDefaults()
        controller.refreshFromPreferences()

        XCTAssertFalse(controller.isOn)
        XCTAssertEqual(controller.time, ReminderTime.standard)
    }

    func testEraserCancelsThePendingRequest() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .allowed
        let (controller, _) = makeController(scheduler)
        await controller.setOn(true)
        do { let pending = await scheduler.pendingDailyCount(); XCTAssertEqual(pending, 1) }

        let eraser = ReminderEraser(scheduler: scheduler)
        try eraser.eraseAll()

        do { let pending = await scheduler.pendingDailyCount(); XCTAssertEqual(pending, 0) }
        XCTAssertGreaterThanOrEqual(scheduler.cancelCount, 1)
    }

    func testSwitchingOnThenOffBeforeTheStatusIsReadLeavesItOff() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .allowed
        let (controller, preferences) = makeController(scheduler)
        // The second tap (off) lands while the first (on) is still reading the status.
        scheduler.whilePermissionIsAnswering = { [weak controller] in
            await controller?.setOn(false)
        }

        await controller.setOn(true)
        scheduler.whilePermissionIsAnswering = nil

        XCTAssertFalse(controller.isOn, "the last tap wins")
        XCTAssertFalse(preferences.isReminderOn)
        XCTAssertNil(scheduler.pendingTime)
        XCTAssertEqual(scheduler.scheduledTimes, [])
    }

    func testAFailedScheduleTurnsTheSwitchOffWithAMessage() async throws {
        struct Refused: Error {}
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .allowed
        scheduler.scheduleFailure = Refused()
        let (controller, preferences) = makeController(scheduler)

        await controller.setOn(true)

        XCTAssertFalse(controller.isOn)
        XCTAssertFalse(preferences.isReminderOn)
        XCTAssertNotNil(controller.message)
        XCTAssertNil(scheduler.pendingTime)
    }

    func testEraseRefreshInvalidatesAnEnableThatIsStillScheduling() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .allowed
        let (controller, preferences) = makeController(scheduler)
        scheduler.whileScheduling = { [weak controller] in
            await MainActor.run {
                preferences.resetToDefaults()
                controller?.refreshFromPreferences()
            }
        }

        await controller.setOn(true)
        scheduler.whileScheduling = nil

        XCTAssertFalse(controller.isOn)
        XCTAssertFalse(preferences.isReminderOn, "the erase is not undone by the enable that was in flight")
    }

    func testTheLastTimeChosenWinsWhenAnEarlierRescheduleFinishesLate() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .allowed
        let (controller, preferences) = makeController(scheduler)
        await controller.setOn(true)
        let early = ReminderTime(hour: 6, minute: 0)
        let late = ReminderTime(hour: 9, minute: 15)
        // While the first change is still being scheduled, a second one arrives and finishes first.
        scheduler.whileScheduling = { [weak controller] in
            scheduler.whileScheduling = nil
            await controller?.setTime(late)
        }

        await controller.setTime(early)

        XCTAssertEqual(controller.time, late)
        XCTAssertEqual(preferences.reminderTime, late)
        XCTAssertEqual(scheduler.pendingTime, late, "the request left pending is the latest time chosen")
        XCTAssertTrue(controller.isOn)
    }

    func testTheNoticeClearsOnceNotificationsAreAllowedAgain() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .denied
        let (controller, _) = makeController(scheduler)
        await controller.setOn(true)
        XCTAssertEqual(controller.message, withdrawnMessage)

        scheduler.settablePermission = .allowed
        await controller.syncOnLaunch()

        XCTAssertNil(controller.message)
        XCTAssertFalse(controller.isOn, "allowing notifications does not switch the reminder on by itself")
    }

    func testSwitchingOffWhileATimeChangeIsBeingScheduledLeavesNothingPending() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .allowed
        let (controller, preferences) = makeController(scheduler)
        await controller.setOn(true)
        scheduler.whileScheduling = { [weak controller] in
            scheduler.whileScheduling = nil
            await controller?.setOn(false)
        }

        await controller.setTime(ReminderTime(hour: 9, minute: 15))

        XCTAssertFalse(controller.isOn)
        XCTAssertFalse(preferences.isReminderOn)
        XCTAssertNil(scheduler.pendingTime, "the late add must not leave a request behind")
    }

    func testASyncOverlappedBySwitchingOffDoesNotTurnItBackOn() async throws {
        let scheduler = FakeReminderScheduler()
        scheduler.settablePermission = .allowed
        let (controller, preferences) = makeController(scheduler)
        await controller.setOn(true)
        scheduler.whileScheduling = { [weak controller] in
            scheduler.whileScheduling = nil
            await controller?.setOn(false)
        }

        await controller.syncOnLaunch()

        XCTAssertFalse(controller.isOn)
        XCTAssertFalse(preferences.isReminderOn)
        XCTAssertNil(scheduler.pendingTime)
    }
}
