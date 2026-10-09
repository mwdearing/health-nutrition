import Foundation

/// A time of day for the daily reminder, on a 24-hour clock. Out-of-range parts are clamped rather
/// than rejected, so no value of this type can name a time that does not exist.
public struct ReminderTime: Equatable, Sendable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    /// Twenty hundred: the time a reminder is set for until the person chooses another.
    public static let standard = ReminderTime(hour: 20, minute: 0)

    /// The stored text form, two digits each side of the colon, for example "07:05".
    var storedText: String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// Reads the stored text form. Anything that is not two numbers separated by a colon, or that is
    /// out of range, is nil, so the caller can fall back to the default.
    init?(storedText text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        self.init(hour: hour, minute: minute)
    }
}

/// The stored settings of the one optional daily reminder: whether it is on and at what time.
///
/// Off and 20:00 until a person changes them. Erase all data removes both values through the display
/// reset, so nothing about the reminder survives an erase.
public protocol ReminderPreferences: AnyObject {
    var isReminderOn: Bool { get }
    var reminderTime: ReminderTime { get }
    func setReminderOn(_ on: Bool)
    func setReminderTime(_ time: ReminderTime)
}
