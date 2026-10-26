import Foundation

/// One weigh-in: the local day it was taken and the body weight in kilograms.
public struct WeightSample: Sendable, Equatable {
    public let day: CalendarDay
    public let kilograms: Decimal

    public init(day: CalendarDay, kilograms: Decimal) {
        self.day = day
        self.kilograms = kilograms
    }
}

/// What the weight trend says about a window of weigh-ins.
///
/// Every optional field is nil together when there is not enough data: fewer than two days with a
/// weigh-in, or a first and last day closer than `WeightTrend.minimumSpanDays`. `projectedGoalDay` is
/// also nil when there is no goal, the trend is not moving toward it, or the day would fall after
/// 9999-12-31.
public struct WeightTrendResult: Sendable, Equatable {
    /// The first day of the window, inclusive.
    public let from: CalendarDay
    /// The last day of the window, inclusive.
    public let through: CalendarDay
    /// The number of distinct days with a weigh-in inside the window.
    public let daysUsed: Int
    /// The slope of the trend over a week, in kilograms. Negative means losing.
    public let weeklyChangeKilograms: Decimal?
    /// The trend's value on the `through` day, in kilograms.
    public let trendKilograms: Decimal?
    /// The day the trend is projected to reach the goal, or nil.
    public let projectedGoalDay: CalendarDay?

    public init(
        from: CalendarDay, through: CalendarDay, daysUsed: Int, weeklyChangeKilograms: Decimal?,
        trendKilograms: Decimal?, projectedGoalDay: CalendarDay?
    ) {
        self.from = from
        self.through = through
        self.daysUsed = daysUsed
        self.weeklyChangeKilograms = weeklyChangeKilograms
        self.trendKilograms = trendKilograms
        self.projectedGoalDay = projectedGoalDay
    }

    /// True when a weekly change could be computed.
    public var hasEnoughData: Bool {
        weeklyChangeKilograms != nil
    }
}

/// A straight-line trend through recent weigh-ins, with the weekly change and a projected goal day.
///
/// Several weigh-ins on one day are averaged into one value for that day. The trend is an ordinary
/// least-squares line of those daily values against the day number, so one noisy weigh-in moves it
/// only a little. Decimal arithmetic throughout, and no clock or zone: the caller supplies the
/// `through` day.
public enum WeightTrend {
    /// The window used when the caller does not choose one, in days.
    public static let defaultWindowDays = 28
    /// The shortest first-to-last span, in days, that gives a trend.
    public static let minimumSpanDays = 7
    /// The allowed window lengths, in days. A requested window outside this range is clamped into it.
    public static let windowRange: ClosedRange<Int> = 14...56

    /// Computes the trend of the weigh-ins that fall in the window ending on `through`.
    ///
    /// The window is `windowDays` days long, clamped into `windowRange`, and ends on `through`.
    /// Samples outside it are ignored. `goalKilograms` is optional; without it no projected goal day
    /// is given.
    public static func compute(
        samples: [WeightSample], through: CalendarDay, windowDays: Int = defaultWindowDays,
        goalKilograms: Decimal?
    ) -> WeightTrendResult {
        let window = min(max(windowDays, windowRange.lowerBound), windowRange.upperBound)
        let from = through.adding(days: -(window - 1))

        var totals: [CalendarDay: (sum: Decimal, count: Int)] = [:]
        for sample in samples where sample.day >= from && sample.day <= through {
            let current = totals[sample.day] ?? (sum: 0, count: 0)
            totals[sample.day] = (sum: current.sum + sample.kilograms, count: current.count + 1)
        }
        let daily = totals
            .map { (day: $0.key, value: $0.value.sum / Decimal($0.value.count)) }
            .sorted { $0.day < $1.day }

        guard let first = daily.first, let last = daily.last, daily.count >= 2,
            first.day.days(until: last.day) >= minimumSpanDays
        else {
            return WeightTrendResult(
                from: from, through: through, daysUsed: daily.count, weeklyChangeKilograms: nil,
                trendKilograms: nil, projectedGoalDay: nil)
        }

        // Least squares of the daily value on x, the days since the window start.
        let count = Decimal(daily.count)
        var sumX: Decimal = 0
        var sumY: Decimal = 0
        var sumXY: Decimal = 0
        var sumXX: Decimal = 0
        for point in daily {
            let x = Decimal(from.days(until: point.day))
            sumX += x
            sumY += point.value
            sumXY += x * point.value
            sumXX += x * x
        }
        let slope = (count * sumXY - sumX * sumY) / (count * sumXX - sumX * sumX)
        let intercept = (sumY - slope * sumX) / count

        let throughX = Decimal(from.days(until: through))
        let trendRaw = intercept + slope * throughX

        let weekly = rounded(slope * 7, scale: 2, mode: .plain)
        let trend = rounded(trendRaw, scale: 2, mode: .plain)

        var goalDay: CalendarDay?
        if let goal = goalKilograms, slope != 0 {
            let towardGoal = (slope < 0 && goal < trendRaw) || (slope > 0 && goal > trendRaw)
            if towardGoal {
                var days = abs(trendRaw - goal) / abs(slope)
                days = rounded(days, scale: 6, mode: .plain)
                days = rounded(days, scale: 0, mode: .up)
                goalDay = through.adding(wholeDays: days)
            }
        }

        return WeightTrendResult(
            from: from, through: through, daysUsed: daily.count, weeklyChangeKilograms: weekly,
            trendKilograms: trend, projectedGoalDay: goalDay)
    }

    /// `value` rounded to `scale` decimal places with the given mode.
    private static func rounded(
        _ value: Decimal, scale: Int, mode: NSDecimalNumber.RoundingMode
    ) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, scale, mode)
        return result
    }
}
