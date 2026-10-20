import Foundation

/// The system's pending notification requests, read back after an erase. The app supplies the system center; tests
/// supply a fake.
public protocol PendingReminderCenter: Sendable {
    /// The identifiers of every request the system still holds as pending.
    func pendingRequestIdentifiers() async -> [String]
}

/// Names the reminder stores that still have a pending request on the phone after an erase.
public enum ReminderReadback {
    /// The prefix of every custom reminder's request identifier.
    public static let customPrefix = "custom-reminder-"

    public static func namesStillPending(in center: PendingReminderCenter) async -> [String] {
        let identifiers = await center.pendingRequestIdentifiers()
        var names: [String] = []
        if identifiers.contains(ReminderIdentifier.daily) { names.append("reminders") }
        if identifiers.contains(where: { $0.hasPrefix(customPrefix) }) { names.append("custom reminders") }
        return names
    }
}
