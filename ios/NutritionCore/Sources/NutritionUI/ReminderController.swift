import Foundation

/// Drives the daily reminder: the switch and time the settings screen shows, the one permission prompt,
/// and the single pending request the system holds for the app.
///
/// The system prompt is asked for only when a person switches the reminder on while the status is not
/// determined. Launch and every return to the foreground read the status and never ask.
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
    /// Bumped by every switch tap so a slow earlier call can tell it has been superseded.
    private var generation = 0

    public init(preferences: ReminderPreferences, scheduler: ReminderScheduling) {
        self.preferences = preferences
        self.scheduler = scheduler
        self.isOn = preferences.isReminderOn
        self.time = preferences.reminderTime
    }

    /// Switches the reminder on or off. Turning on asks for permission only when it is not yet decided,
    /// and stays off with a message when the answer is no.
    ///
    /// Each call supersedes the one before it: a switch tapped on and then off again before the system has
    /// answered ends off, because the older call finds on resuming that it is no longer the latest.
    public func setOn(_ on: Bool) async {
        generation += 1
        let token = generation
        guard on else {
            preferences.setReminderOn(false)
            isOn = false
            message = nil
            scheduler.cancelDaily()
            return
        }
        var permission = await scheduler.permission()
        guard token == generation else { return }
        if permission == .notDetermined {
            let granted = await scheduler.requestPermission()
            guard token == generation else { return }
            permission = granted ? .allowed : .denied
        }
        guard permission == .allowed else {
            preferences.setReminderOn(false)
            isOn = false
            message = Self.withdrawnMessage
            return
        }
        do {
            try await scheduler.scheduleDaily(at: time)
        } catch {
            guard token == generation else { return }
            turnOffAfterRefusal()
            return
        }
        guard token == generation else {
            // A later switch-off arrived while the request was being added: do not leave it pending.
            if !isOn { scheduler.cancelDaily() }
            return
        }
        preferences.setReminderOn(true)
        isOn = true
        message = nil
    }

    /// Stores the new time. While the reminder is on, the pending request is replaced, never added to.
    ///
    /// The last time chosen wins: a change that finishes after a later one has been made schedules the
    /// latest time again, so a stale request never stays pending.
    public func setTime(_ newTime: ReminderTime) async {
        generation += 1
        let token = generation
        preferences.setReminderTime(newTime)
        time = newTime
        guard isOn else { return }
        do {
            try await scheduler.scheduleDaily(at: newTime)
        } catch {
            guard token == generation else { return }
            turnOffAfterRefusal()
            return
        }
        if token != generation {
            if isOn {
                try? await scheduler.scheduleDaily(at: time)
            } else {
                // Switched off while this request was being added: the late add must not stay pending.
                scheduler.cancelDaily()
            }
        }
    }

    /// Brings the system's pending request in line with the stored setting. Never asks for permission.
    /// Called at launch and each time the app becomes active.
    public func syncOnLaunch() async {
        time = preferences.reminderTime
        let permission = await scheduler.permission()
        if preferences.isReminderOn {
            if permission == .allowed {
                let token = generation
                do {
                    try await scheduler.scheduleDaily(at: time)
                } catch {
                    if token == generation { turnOffAfterRefusal() }
                    return
                }
                guard token == generation else {
                    // A switch tap or an erase arrived while the request was being added: that action
                    // decides the state, and a request it switched off must not stay pending.
                    if !preferences.isReminderOn { scheduler.cancelDaily() }
                    return
                }
                isOn = true
                message = nil
            } else {
                scheduler.cancelDaily()
                preferences.setReminderOn(false)
                isOn = false
                message = Self.withdrawnMessage
            }
        } else {
            isOn = false
            // A notice about notifications being off no longer holds once they are allowed again.
            if permission == .allowed, message == Self.withdrawnMessage { message = nil }
            if await scheduler.pendingDailyCount() > 0 {
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

    /// Re-reads the stored values. Erase all data resets them, so the screen reads them again.
    public func refreshFromPreferences() {
        // Anything still in flight was started against settings that no longer exist.
        generation += 1
        isOn = preferences.isReminderOn
        time = preferences.reminderTime
        message = nil
    }
}
