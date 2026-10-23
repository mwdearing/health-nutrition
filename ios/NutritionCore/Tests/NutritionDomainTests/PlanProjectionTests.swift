import XCTest
@testable import NutritionDomain

/// The goal-day arithmetic and the planned-versus-trend comparison, each expected day worked out by hand
/// in its test: days = distance / pace * 7, rounded to a whole day, counted from the start day.
final class PlanProjectionTests: XCTestCase {
    private func d(_ text: String) -> Decimal { Decimal(string: text)! }

    private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }

    private func trend(through: String, weekly: String?, goalDay: String?) -> WeightTrendResult {
        WeightTrendResult(
            from: day("2026-03-01"), through: day(through), daysUsed: 28,
            weeklyChangeKilograms: weekly.map(d), trendKilograms: d("85.0"),
            projectedGoalDay: goalDay.map(day))
    }

    func testLosingNineKilogramsAtHalfAKilogramAWeekReachesTheGoalOnAugust19() {
        // 9 / 0.5 * 7 = 126 days; April 15 + 126 days = August 19.
        XCTAssertEqual(
            PlanProjection.goalDay(
                currentKilograms: d("89"), goalKilograms: d("80"), weeklyPaceKilograms: d("0.5"),
                from: day("2026-04-15")),
            day("2026-08-19"))
    }

    func testAPaceOfPointFourFiveGivesSeptember2() {
        // 9 / 0.45 * 7 = 140 days; April 15 + 140 days = September 2.
        XCTAssertEqual(
            PlanProjection.goalDay(
                currentKilograms: d("89"), goalKilograms: d("80"), weeklyPaceKilograms: d("0.45"),
                from: day("2026-04-15")),
            day("2026-09-02"))
    }

    func testGainingToAHigherGoalCountsTheSameWay() {
        // 4.1 / 0.25 * 7 = 114.8 -> 115 days; May 22 + 115 days = September 14.
        XCTAssertEqual(
            PlanProjection.goalDay(
                currentKilograms: d("60.9"), goalKilograms: d("65"), weeklyPaceKilograms: d("0.25"),
                from: day("2026-05-22")),
            day("2026-09-14"))
    }

    func testAHalfDayOfQuotientRoundsUpToTheNextWholeDay() {
        // 0.33 / 0.14 * 7 = 16.5 exactly -> 17 days; April 15 + 17 days = May 2.
        XCTAssertEqual(
            PlanProjection.goalDay(
                currentKilograms: d("80.33"), goalKilograms: d("80"), weeklyPaceKilograms: d("0.14"),
                from: day("2026-04-15")),
            day("2026-05-02"))
    }

    func testWhenCurrentWeightIsTheGoalThereIsNoDay() {
        XCTAssertNil(
            PlanProjection.goalDay(
                currentKilograms: d("80"), goalKilograms: d("80"), weeklyPaceKilograms: d("0.5"),
                from: day("2026-04-15")))
    }

    func testAZeroPaceGivesNoDay() {
        XCTAssertNil(
            PlanProjection.goalDay(
                currentKilograms: d("89"), goalKilograms: d("80"), weeklyPaceKilograms: 0,
                from: day("2026-04-15")))
    }

    func testANegativePaceGivesNoDay() {
        XCTAssertNil(
            PlanProjection.goalDay(
                currentKilograms: d("89"), goalKilograms: d("80"), weeklyPaceKilograms: d("-0.5"),
                from: day("2026-04-15")))
    }

    func testPlannedWeeklyChangeSignsFollowTheAim() {
        XCTAssertEqual(
            PlanProjection.plannedWeeklyChangeKilograms(aim: .lose, weeklyPaceKilograms: d("0.5")), d("-0.5"))
        XCTAssertEqual(
            PlanProjection.plannedWeeklyChangeKilograms(aim: .gain, weeklyPaceKilograms: d("0.25")), d("0.25"))
        XCTAssertEqual(
            PlanProjection.plannedWeeklyChangeKilograms(aim: .maintain, weeklyPaceKilograms: d("0.5")), 0)
        XCTAssertEqual(
            PlanProjection.plannedWeeklyChangeKilograms(aim: .justTrack, weeklyPaceKilograms: d("0.5")), 0)
    }

    func testLosingComparesPlannedAndTrendDays() {
        let comparison = PlanProjection.compare(
            aim: .lose, weeklyPaceKilograms: d("0.5"), currentKilograms: d("89"), goalKilograms: d("80"),
            trend: trend(through: "2026-04-15", weekly: "-0.71", goalDay: "2026-07-12"))
        XCTAssertEqual(
            comparison,
            PaceComparison(
                plannedWeeklyChangeKilograms: d("-0.5"), trendWeeklyChangeKilograms: d("-0.71"),
                plannedGoalDay: day("2026-08-19"), trendGoalDay: day("2026-07-12")))
    }

    func testLosingWhileAlreadyBelowTheGoalHasNoPlannedDay() {
        let comparison = PlanProjection.compare(
            aim: .lose, weeklyPaceKilograms: d("0.5"), currentKilograms: d("79"), goalKilograms: d("80"),
            trend: trend(through: "2026-04-15", weekly: "-0.71", goalDay: "2026-07-12"))
        XCTAssertNil(comparison.plannedGoalDay)
        XCTAssertEqual(comparison.plannedWeeklyChangeKilograms, d("-0.5"))
    }

    func testMaintainHasZeroPlannedChangeNoPlannedDayAndCopiesTheTrendDay() {
        let comparison = PlanProjection.compare(
            aim: .maintain, weeklyPaceKilograms: d("0.5"), currentKilograms: d("89"), goalKilograms: d("80"),
            trend: trend(through: "2026-04-15", weekly: "-0.71", goalDay: "2026-07-12"))
        XCTAssertEqual(comparison.plannedWeeklyChangeKilograms, 0)
        XCTAssertNil(comparison.plannedGoalDay)
        XCTAssertEqual(comparison.trendGoalDay, day("2026-07-12"))
    }

    func testAThinTrendLeavesTheTrendFieldsNilAndStillProjectsThePlan() {
        // 11 / 0.5 * 7 = 154 days; March 27 + 154 days = August 28.
        let comparison = PlanProjection.compare(
            aim: .lose, weeklyPaceKilograms: d("0.5"), currentKilograms: d("91"), goalKilograms: d("80"),
            trend: trend(through: "2026-03-27", weekly: nil, goalDay: nil))
        XCTAssertNil(comparison.trendWeeklyChangeKilograms)
        XCTAssertNil(comparison.trendGoalDay)
        XCTAssertEqual(comparison.plannedGoalDay, day("2026-08-28"))
    }

    func testGainingTowardALowerGoalHasNoPlannedDay() {
        let comparison = PlanProjection.compare(
            aim: .gain, weeklyPaceKilograms: d("0.25"), currentKilograms: d("60.9"), goalKilograms: d("58"),
            trend: trend(through: "2026-05-22", weekly: "0.2", goalDay: nil))
        XCTAssertNil(comparison.plannedGoalDay)
        XCTAssertEqual(comparison.plannedWeeklyChangeKilograms, d("0.25"))
    }

    func testGainingTowardAHigherGoalProjectsAPlannedDay() {
        let comparison = PlanProjection.compare(
            aim: .gain, weeklyPaceKilograms: d("0.25"), currentKilograms: d("60.9"), goalKilograms: d("65"),
            trend: trend(through: "2026-05-22", weekly: "0.2", goalDay: nil))
        XCTAssertEqual(comparison.plannedGoalDay, day("2026-09-14"))
    }

    func testJustTrackHasNoPlannedChangeOrDayWhateverTheGoal() {
        let comparison = PlanProjection.compare(
            aim: .justTrack, weeklyPaceKilograms: d("0.5"), currentKilograms: d("89"), goalKilograms: d("80"),
            trend: trend(through: "2026-04-15", weekly: "-0.71", goalDay: "2026-07-12"))
        XCTAssertEqual(comparison.plannedWeeklyChangeKilograms, 0)
        XCTAssertNil(comparison.plannedGoalDay)
        XCTAssertEqual(comparison.trendGoalDay, day("2026-07-12"))
    }

    func testATinyPaceWhoseGoalDayIsPastTheCalendarHasNoDay() {
        let tiny = PlanProjection.goalDay(
            currentKilograms: d("89"), goalKilograms: d("80"), weeklyPaceKilograms: d("0.0000000000001"),
            from: day("2026-04-15"))
        XCTAssertNil(tiny)
    }

    func testAGoalDayOnTheLastCalendarDayIsKept() {
        // 1 kg at 7 kg a week is one day.
        let last = PlanProjection.goalDay(
            currentKilograms: d("81"), goalKilograms: d("80"), weeklyPaceKilograms: d("7"),
            from: day("9999-12-30"))
        XCTAssertEqual(last, day("9999-12-31"))
        let past = PlanProjection.goalDay(
            currentKilograms: d("81"), goalKilograms: d("80"), weeklyPaceKilograms: d("7"),
            from: day("9999-12-31"))
        XCTAssertNil(past)
    }
}
