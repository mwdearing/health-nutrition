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

    @Published public private(set) var isOn: Bool
    @Published public private(set) var time: ReminderTime
    @Published public private(set) var message: String?

    private let preferences: ReminderPreferences
    private let scheduler: ReminderScheduling

    public init(preferences: ReminderPreferences, scheduler: ReminderScheduling) {
        self.preferences = preferences
        self.scheduler = scheduler
        self.isOn = preferences.isReminderOn
        self.time = preferences.reminderTime
    }

    /// Switches the reminder on or off. Turning on asks for permission only when it is not yet decided,
    /// and stays off with a message when the answer is no.
    public func setOn(_ on: Bool) async {
        guard on else {
            preferences.setReminderOn(false)
            isOn = false
            message = nil
            scheduler.cancelDaily()
            return
        }
        var permission = await scheduler.permission()
        if permission == .notDetermined {
            permission = await scheduler.requestPermission() ? .allowed : .denied
        }
        guard permission == .allowed else {
            preferences.setReminderOn(false)
            isOn = false
            message = Self.withdrawnMessage
            return
        }
        preferences.setReminderOn(true)
        isOn = true
        message = nil
        await scheduler.scheduleDaily(at: time)
    }

    /// Stores the new time. While the reminder is on, the pending request is replaced, never added to.
    public func setTime(_ newTime: ReminderTime) async {
        preferences.setReminderTime(newTime)
        time = newTime
        if isOn {
            await scheduler.scheduleDaily(at: newTime)
        }
    }

    /// Brings the system's pending request in line with the stored setting. Never asks for permission.
    /// Called at launch and each time the app becomes active.
    public func syncOnLaunch() async {
        time = preferences.reminderTime
        let permission = await scheduler.permission()
        if preferences.isReminderOn {
            if permission == .allowed {
                isOn = true
                message = nil
                await scheduler.scheduleDaily(at: time)
            } else {
                scheduler.cancelDaily()
                preferences.setReminderOn(false)
                isOn = false
                message = Self.withdrawnMessage
            }
        } else {
            isOn = false
            if await scheduler.pendingDailyCount() > 0 {
                scheduler.cancelDaily()
            }
        }
    }

    /// Re-reads the stored values. Erase all data resets them, so the screen reads them again.
    public func refreshFromPreferences() {
        isOn = preferences.isReminderOn
        time = preferences.reminderTime
        message = nil
    }
}
