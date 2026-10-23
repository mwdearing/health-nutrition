import Foundation

/// The planned pace set against the pace the weight trend shows, with the day each one reaches the goal.
///
/// Every field is a plain number or a day. Nothing here says whether the trend is near, far or
/// different from the plan; the screen shows both figures side by side and leaves the reading to the person.
public struct PaceComparison: Sendable, Equatable {
    /// The planned weekly change in kilograms: negative when losing, positive when gaining, zero otherwise.
    public let plannedWeeklyChangeKilograms: Decimal
    /// The weekly change the trend shows in kilograms, or nil when the trend has too few weigh-ins.
    public let trendWeeklyChangeKilograms: Decimal?
    /// The day the planned pace reaches the goal, or nil when the aim does not point at the goal.
    public let plannedGoalDay: CalendarDay?
    /// The day the trend projects the goal is reached, or nil when the trend projects none.
    public let trendGoalDay: CalendarDay?

    public init(
        plannedWeeklyChangeKilograms: Decimal, trendWeeklyChangeKilograms: Decimal?,
        plannedGoalDay: CalendarDay?, trendGoalDay: CalendarDay?
    ) {
        self.plannedWeeklyChangeKilograms = plannedWeeklyChangeKilograms
        self.trendWeeklyChangeKilograms = trendWeeklyChangeKilograms
        self.plannedGoalDay = plannedGoalDay
        self.trendGoalDay = trendGoalDay
    }
}

/// Arithmetic for the day a steady pace reaches a goal, and the planned pace in signed form.
///
/// Pace is kilograms a week. The days to the goal are the distance divided by the pace, times seven,
/// rounded to a whole day with halves away from zero.
public enum PlanProjection {
    /// The day a steady pace reaches the goal, counted from `from`.
    ///
    /// Nil when the pace is not above zero, when the current weight is already the goal, or when the day
    /// would fall after 9999-12-31.
    public static func goalDay(
        currentKilograms: Decimal, goalKilograms: Decimal, weeklyPaceKilograms: Decimal, from: CalendarDay
    ) -> CalendarDay? {
        guard weeklyPaceKilograms > 0 else { return nil }
        let distance = (currentKilograms - goalKilograms).magnitude
        guard distance > 0 else { return nil }

        // Round to six decimal places first so a quotient that is one part in a million short of a
        // half day does not flip the whole day.
        var days = distance / weeklyPaceKilograms * 7
        var sixPlaces = Decimal()
        NSDecimalRound(&sixPlaces, &days, 6, .plain)
        var wholeDays = Decimal()
        NSDecimalRound(&wholeDays, &sixPlaces, 0, .plain)

        return from.adding(wholeDays: wholeDays)
    }

    /// The planned weekly change: minus the pace when losing, plus it when gaining, zero for the rest.
    public static func plannedWeeklyChangeKilograms(aim: GoalAim, weeklyPaceKilograms: Decimal) -> Decimal {
        switch aim {
        case .lose: return -weeklyPaceKilograms
        case .gain: return weeklyPaceKilograms
        case .maintain, .justTrack: return 0
        }
    }

    /// The planned pace beside the trend's pace and projected day.
    ///
    /// The planned goal day is set only when the aim points at the goal: losing toward a lower goal or
    /// gaining toward a higher one. It counts from the day the trend was computed through.
    public static func compare(
        aim: GoalAim, weeklyPaceKilograms: Decimal, currentKilograms: Decimal, goalKilograms: Decimal,
        trend: WeightTrendResult
    ) -> PaceComparison {
        let pointsAtGoal: Bool
        switch aim {
        case .lose: pointsAtGoal = goalKilograms < currentKilograms
        case .gain: pointsAtGoal = goalKilograms > currentKilograms
        case .maintain, .justTrack: pointsAtGoal = false
        }
        let plannedDay = pointsAtGoal
            ? goalDay(
                currentKilograms: currentKilograms, goalKilograms: goalKilograms,
                weeklyPaceKilograms: weeklyPaceKilograms, from: trend.through)
            : nil
        return PaceComparison(
            plannedWeeklyChangeKilograms: plannedWeeklyChangeKilograms(
                aim: aim, weeklyPaceKilograms: weeklyPaceKilograms),
            trendWeeklyChangeKilograms: trend.weeklyChangeKilograms,
            plannedGoalDay: plannedDay,
            trendGoalDay: trend.projectedGoalDay)
    }
}
