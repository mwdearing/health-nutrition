import Foundation

/// RFC 3339 timestamps in the exact form the intake-context contract writes them.
///
/// The contract wants `occurred_at` in the intake's own time zone, with that zone's offset at that instant, so
/// the local wall clock and the instant agree for every consumer. The timestamps the app records for when it
/// wrote something down, `recorded_at` and `deleted_at`, are instants rather than wall clocks and are written
/// in UTC. Both forms are built from the calendar fields rather than asked of a formatter, so the text is the
/// same on every host and no fraction of a second is rounded away: the contract's pattern allows a fraction,
/// but a payload whose bytes move between two encodes of one revision would hash differently.
enum IntakeContextTimestamp {
    /// A whole-second instant in UTC, for example `2026-09-30T17:31:02Z`.
    static func utc(_ date: Date) -> String {
        let fields = calendarFields(of: date, in: utcZone)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            fields.year, fields.month, fields.day, fields.hour, fields.minute, fields.second) + "Z"
    }

    /// A whole-second instant in the named IANA zone, with that zone's offset at the instant, for example
    /// `2026-09-30T12:30:00-05:00` in `America/Chicago`.
    ///
    /// A zone name the platform does not know is refused: a host-local key such as `localtime` or a name only
    /// this device knows does not name one zone on every receiver, and silently falling back to the device's
    /// own zone would send a timestamp whose wall clock no longer agrees with `time_zone`.
    static func local(_ date: Date, timeZone identifier: String) throws -> String {
        guard let zone = TimeZone(identifier: identifier) else {
            throw IntakeContextEncoderError.unknownTimeZone(identifier)
        }
        let fields = calendarFields(of: date, in: zone)
        let wallClock = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            fields.year, fields.month, fields.day, fields.hour, fields.minute, fields.second)
        let offsetSeconds = zone.secondsFromGMT(for: date)
        let sign = offsetSeconds < 0 ? "-" : "+"
        let magnitude = abs(offsetSeconds)
        let offset = String(format: "%02d:%02d", magnitude / 3600, (magnitude % 3600) / 60)
        return wallClock + sign + offset
    }

    private static let utcZone = TimeZone(secondsFromGMT: 0)!

    /// The Gregorian calendar fields of an instant in a zone, with the seconds of the instant itself and
    /// nothing finer.
    private static func calendarFields(of date: Date, in zone: TimeZone) -> (
        year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return (
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }
}