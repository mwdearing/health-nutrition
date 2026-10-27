import XCTest
@testable import NutritionDomain

/// The planned goal day rounds up to a whole day, the same way the trend's projected day does: it is the
/// first day the steady pace has covered the whole distance.
final class PlanProjectionRoundUpTests: XCTestCase {
    private func d(_ text: String) -> Decimal { Decimal(string: text)! }

    private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }

    func testAFractionBelowAHalfStillRoundsUp() {
        // 3.03 / 0.5 * 7 = 42.42 -> 43 days; April 15 + 43 days = May 28.
        XCTAssertEqual(
            PlanProjection.goalDay(
                currentKilograms: d("83.03"), goalKilograms: d("80"), weeklyPaceKilograms: d("0.5"),
                from: day("2026-04-15")),
            day("2026-05-28"))
    }

    func testAWholeNumberOfDaysIsNotRoundedFurther() {
        // 9 / 0.5 * 7 = 126 days exactly; April 15 + 126 days = August 19.
        XCTAssertEqual(
            PlanProjection.goalDay(
                currentKilograms: d("89"), goalKilograms: d("80"), weeklyPaceKilograms: d("0.5"),
                from: day("2026-04-15")),
            day("2026-08-19"))
    }

    func testAGainRoundsUpTheSameWay() {
        // 2.1 / 0.25 * 7 = 58.8 -> 59 days; May 22 + 59 days = July 20.
        XCTAssertEqual(
            PlanProjection.goalDay(
                currentKilograms: d("60.9"), goalKilograms: d("63"), weeklyPaceKilograms: d("0.25"),
                from: day("2026-05-22")),
            day("2026-07-20"))
    }

    func testOnePoundAWeekTowardAPoundGoalRoundsUp() {
        // (89 - 176 lb) / 1 lb * 7 = 141.48 -> 142 days; April 15 + 142 days = September 4.
        let pound = d("0.45359237")
        XCTAssertEqual(
            PlanProjection.goalDay(
                currentKilograms: d("89"), goalKilograms: d("176") * pound, weeklyPaceKilograms: pound,
                from: day("2026-04-15")),
            day("2026-09-04"))
    }

    func testTheComparisonUsesTheRoundedUpDay() {
        let trend = WeightTrendResult(
            from: day("2026-03-19"), through: day("2026-04-15"), daysUsed: 2,
            weeklyChangeKilograms: d("-0.5"), trendKilograms: d("83.03"), projectedGoalDay: nil)
        let comparison = PlanProjection.compare(
            aim: .lose, weeklyPaceKilograms: d("0.5"), currentKilograms: d("83.03"), goalKilograms: d("80"),
            trend: trend)
        XCTAssertEqual(comparison.plannedGoalDay, day("2026-05-28"))
    }
}
