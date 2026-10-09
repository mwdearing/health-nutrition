import Foundation

/// What the system currently allows for the app's local notifications. Provisional and ephemeral
/// authorization count as allowed: they deliver quietly, which is still delivery.
public enum ReminderPermission: Equatable, Sendable {
    case notDetermined
    case denied
    case allowed
}

/// The names the reminder's pending request is stored under.
public enum ReminderIdentifier {
    /// The one daily reminder's request. Scheduling again under this identifier replaces the request,
    /// so there is never more than one.
    public static let daily = "daily-log-reminder"
}

/// The seam between the reminder's rules and the system's local notifications. The app target supplies
/// the system implementation; tests supply a fake, so none of the rules need a device.
public protocol ReminderScheduling: AnyObject, Sendable {
    func permission() async -> ReminderPermission
    /// Asks the system once. Returns whether the person allowed notifications.
    func requestPermission() async -> Bool
    /// Schedules the daily request at `time`, replacing any request already pending under the daily
    /// identifier.
    func scheduleDaily(at time: ReminderTime) async
    /// Removes the daily request, pending and delivered. Synchronous so an erase can finish before it
    /// returns.
    func cancelDaily()
    /// How many requests under the daily identifier are pending: zero or one.
    func pendingDailyCount() async -> Int
}
