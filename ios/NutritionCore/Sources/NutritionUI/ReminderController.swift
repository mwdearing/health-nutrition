import Foundation

/// Counts how many times Erase all data has run, so an operation that was already under way when an erase
/// happened can tell and stand down. Shared by the controller and the eraser; safe to read from anywhere.
public final class ReminderErasures: @unchecked Sendable {
    private let lock = NSLock()
    private var erased = 0

    public init() {}

    /// How many erases have been recorded.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return erased
    }

    /// Notes that an erase is running.
    public func record() {
        lock.lock()
        erased += 1
        lock.unlock()
    }
}

/// Drives the daily reminder: the switch and time the settings screen shows, the one permission prompt,
/// and the single pending request the system holds for the app.
///
/// The system prompt is asked for only when a person switches the reminder on while the status is not
/// determined. Launch and every return to the foreground read the status and never ask.
///
/// **Every action runs in order.** A switch, a time change and a launch sync are queued behind whatever is
/// still under way and each reads the stored settings when its turn comes, so the last thing a person did
/// decides the outcome and no two actions ever overlap while they wait on the system. The one thing that can
/// happen outside the queue is Erase all data, which is recorded in `erasures`: an action that finds an erase
/// happened while it waited cancels what it added and changes nothing.
@MainActor
public final class ReminderController: ObservableObject {
    /// Shown when notifications are not allowed for the app, on the settings screen and at launch.
    public static let withdrawnMessage =
        "Notifications are turned off for this app. You can allow them in the iPhone Settings app."

    /// Shown when the system would not take the reminder, for example because notifications were switched
    /// off between the check and the request.
    public static let refusedMessage = "The reminder could not be set. Check the notification settings for this app and try again."

    @Published public private(set) var isOn: Bool
    @Published public private(set) var time: ReminderTime
    @Published public private(set) var message: String?

    private let preferences: ReminderPreferences
    private let scheduler: ReminderScheduling
    private let erasures: ReminderErasures
    /// The last queued action. A new one starts only after this one has finished.
    private var tail: Task<Void, Never>?

    public init(
        preferences: ReminderPreferences, scheduler: ReminderScheduling,
        erasures: ReminderErasures = ReminderErasures()
    ) {
        self.preferences = preferences
        self.scheduler = scheduler
        self.erasures = erasures
        self.isOn = preferences.isReminderOn
        self.time = preferences.reminderTime
    }

    /// Switches the reminder on or off. Turning on asks for permission only when it is not yet decided,
    /// and stays off with a message when the answer is no.
    public func setOn(_ on: Bool) async {
        await enqueue { [self] erased in await self.applyOn(on, erased: erased) }
    }

    /// Stores the new time at once, so the picker shows it, then queues the rescheduling. While the reminder
    /// is on, the pending request is replaced, never added to, and the latest stored time is the one set.
    public func setTime(_ newTime: ReminderTime) async {
        preferences.setReminderTime(newTime)
        time = newTime
        await enqueue { [self] erased in await self.applyTime(erased: erased) }
    }

    /// Brings the system's pending request in line with the stored setting. Never asks for permission.
    /// Called at launch and each time the app becomes active.
    public func syncOnLaunch() async {
        await enqueue { [self] erased in await self.applySync(erased: erased) }
    }

    /// Re-reads the stored values. Erase all data resets them, so the screen reads them again.
    public func refreshFromPreferences() {
        // Anything still under way was started against settings that no longer exist.
        erasures.record()
        isOn = preferences.isReminderOn
        time = preferences.reminderTime
        message = nil
    }

    // MARK: Queue

    /// Queues `body` behind the last action. The erase count is read now, when the action is requested: an
    /// erase that happens before its turn comes means it was asked for against settings that are gone, so it
    /// is dropped rather than run.
    private func enqueue(_ body: @escaping @MainActor (_ erased: Int) async -> Void) async {
        let erased = erasures.count
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            guard erased == erasures.count else { return }
            await body(erased)
        }
        tail = task
        await task.value
    }

    // MARK: Actions (each runs alone, in order)

    private func applyOn(_ on: Bool, erased: Int) async {
        guard on else {
            preferences.setReminderOn(false)
            isOn = false
            message = nil
            scheduler.cancelDaily()
            return
        }
        var permission = await scheduler.permission()
        guard erased == erasures.count else { return }
        if permission == .notDetermined {
            let granted = await scheduler.requestPermission()
            guard erased == erasures.count else { return }
            permission = granted ? .allowed : .denied
        }
        guard permission == .allowed else {
            preferences.setReminderOn(false)
            isOn = false
            message = Self.withdrawnMessage
            return
        }
        do {
            try await scheduler.scheduleDaily(at: preferences.reminderTime)
        } catch {
            if erased == erasures.count { turnOffAfterRefusal() }
            return
        }
        guard erased == erasures.count else {
            scheduler.cancelDaily()
            return
        }
        preferences.setReminderOn(true)
        isOn = true
        time = preferences.reminderTime
        message = nil
    }

    private func applyTime(erased: Int) async {
        guard preferences.isReminderOn else { return }
        do {
            try await scheduler.scheduleDaily(at: preferences.reminderTime)
        } catch {
            if erased == erasures.count { turnOffAfterRefusal() }
            return
        }
        if erased != erasures.count { scheduler.cancelDaily() }
    }

    private func applySync(erased: Int) async {
        time = preferences.reminderTime
        let permission = await scheduler.permission()
        guard erased == erasures.count else { return }
        if preferences.isReminderOn {
            guard permission == .allowed else {
                scheduler.cancelDaily()
                preferences.setReminderOn(false)
                isOn = false
                message = Self.withdrawnMessage
                return
            }
            do {
                try await scheduler.scheduleDaily(at: preferences.reminderTime)
            } catch {
                if erased == erasures.count { turnOffAfterRefusal() }
                return
            }
            guard erased == erasures.count else {
                scheduler.cancelDaily()
                return
            }
            isOn = true
            message = nil
        } else {
            isOn = false
            // A notice about notifications being off no longer holds once they are allowed again.
            if permission == .allowed, message == Self.withdrawnMessage { message = nil }
            if await scheduler.pendingDailyCount() > 0, erased == erasures.count {
                scheduler.cancelDaily()
            }
        }
    }

    /// The system refused the request, so no reminder is pending: the switch says so rather than staying on.
    private func turnOffAfterRefusal() {
        scheduler.cancelDaily()
        preferences.setReminderOn(false)
        isOn = false
        message = Self.refusedMessage
    }
}
