import Foundation

/// A day on the Gregorian calendar, with no time and no time zone.
///
/// The caller turns a sample's time into the person's local day before building one of these; nothing
/// here knows about clocks or zones. Arithmetic is whole days on integers, so adding and counting days
/// gives the same answer on every device.
public struct CalendarDay: Sendable, Hashable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Nil for a date that does not exist (February 29 outside a leap year, April 31) or a year outside
    /// 1...9999.
    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month) else { return nil }
        guard day >= 1, day <= Self.daysIn(month: month, year: year) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses exactly `YYYY-MM-DD`: four digits, two digits and two digits, joined by hyphens. Anything
    /// else, a time suffix included, is nil.
    public init?(iso: String) {
        let chars = Array(iso.utf8)
        guard chars.count == 10, chars[4] == UInt8(ascii: "-"), chars[7] == UInt8(ascii: "-") else {
            return nil
        }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let c = chars[index]
                guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int(c - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10) else {
            return nil
        }
        self.init(year: year, month: month, day: day)
    }

    /// The day as `YYYY-MM-DD`.
    public var isoString: String {
        func padded(_ value: Int, _ width: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(padded(year, 4))-\(padded(month, 2))-\(padded(day, 2))"
    }

    /// The day `days` later, or earlier for a negative count.
    public func adding(days: Int) -> CalendarDay {
        Self(dayNumber: dayNumber + days)
    }

    /// The number of days from this day to `other`: `other` minus `self`, negative when `other` is earlier.
    public func days(until other: CalendarDay) -> Int {
        other.dayNumber - dayNumber
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01, counted on the proleptic Gregorian calendar.
    private var dayNumber: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The day for a count of days since 1970-01-01. The result is not range-checked against 1...9999.
    private init(dayNumber: Int) {
        let z = dayNumber + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        self.year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        self.month = month
        self.day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
    }
}
