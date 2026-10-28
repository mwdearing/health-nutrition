import Foundation
import NutritionDomain
import XCTest

@testable import NutritionUI

/// The weight lines on Today's activity card: the 28-day trend's weekly change, and with a saved loss or
/// gain plan, the planned pace and the day each one reaches the goal. Plain numbers only.
@MainActor
final class BodyActivityPlanTests: XCTestCase {
    private final class Reader: BodyActivityReading {
        var hasAskedForReadAccess = true
        var readings = BodyActivityReadings.empty

        func requestReadAccess() async {}

        func read(now: Date) async -> BodyActivityReadings { readings }
    }

    /// 2026-04-15 12:00 UTC, read in a UTC calendar, so "today" is April 15 on every machine.
    private let now = Date(timeIntervalSince1970: 1_776_254_400)

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func d(_ text: String) -> Decimal { Decimal(string: text)! }

    private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }

    /// 90 kg on April 1 and 89 kg on April 15: a trend of 0.5 kg a week down, at 89 kg today.
    private func losingReadings() -> BodyActivityReadings {
        var readings = BodyActivityReadings(latestWeightKg: 89, latestWeightDate: now)
        readings.weightSamples = [
            WeightSample(day: day("2026-04-01"), kilograms: 90),
            WeightSample(day: day("2026-04-15"), kilograms: 89),
        ]
        return readings
    }

    private func makeModel(
        readings: BodyActivityReadings, system: UnitSystem = .metric, plan: @escaping () -> WeightPlan? = { nil }
    ) -> BodyActivityViewModel {
        let reader = Reader()
        reader.readings = readings
        return BodyActivityViewModel(reader: reader, unitSystem: { system }, weightPlan: plan, calendar: utc)
    }

    func testTheTrendLineGivesTheWeeklyChange() async {
        let model = makeModel(readings: losingReadings())
        await model.load(now: now)

        XCTAssertEqual(model.weightTrendText, "Trend: down 0.5 kg a week")
        XCTAssertNil(model.planPaceText)
        XCTAssertNil(model.planGoalDayText)
        XCTAssertNil(model.trendGoalDayText)
    }

    func testTheTrendLineFollowsTheUnitSystem() async {
        let model = makeModel(readings: losingReadings(), system: .usCustomary)
        await model.load(now: now)

        // 0.5 kg is 1.1023 lb.
        XCTAssertEqual(model.weightTrendText, "Trend: down 1.1 lb a week")
    }

    func testARisingTrendSaysUp() async {
        var readings = BodyActivityReadings(latestWeightKg: 61, latestWeightDate: now)
        readings.weightSamples = [
            WeightSample(day: day("2026-04-01"), kilograms: d("60.5")),
            WeightSample(day: day("2026-04-15"), kilograms: 61),
        ]
        let model = makeModel(readings: readings)
        await model.load(now: now)

        XCTAssertEqual(model.weightTrendText, "Trend: up 0.25 kg a week")
    }

    func testAFlatTrendSaysNoChange() async {
        var readings = BodyActivityReadings(latestWeightKg: 80, latestWeightDate: now)
        readings.weightSamples = [
            WeightSample(day: day("2026-04-01"), kilograms: 80),
            WeightSample(day: day("2026-04-15"), kilograms: 80),
        ]
        let model = makeModel(readings: readings)
        await model.load(now: now)

        XCTAssertEqual(model.weightTrendText, "Trend: no change")
    }

    func testTooFewWeighInsGiveNoTrendLine() async {
        var readings = BodyActivityReadings(latestWeightKg: 89, latestWeightDate: now)
        readings.weightSamples = [WeightSample(day: day("2026-04-15"), kilograms: 89)]
        let model = makeModel(readings: readings)
        await model.load(now: now)

        XCTAssertNil(model.weightTrendText)
        XCTAssertEqual(model.weightText, "89 kg")
    }

    func testWeighInsOlderThanTheWindowAreLeftOut() async {
        var readings = BodyActivityReadings(latestWeightKg: 89, latestWeightDate: now)
        // March 18 is outside the 28 days that end on April 15 (March 19 to April 15).
        readings.weightSamples = [
            WeightSample(day: day("2026-03-18"), kilograms: 95),
            WeightSample(day: day("2026-04-15"), kilograms: 89),
        ]
        let model = makeModel(readings: readings)
        await model.load(now: now)

        XCTAssertNil(model.weightTrendText)
    }

    func testALosingPlanShowsThePlanAndBothGoalDays() async {
        let plan = WeightPlan(aim: .lose, goalKilograms: 80, weeklyPaceKilograms: d("0.25"))
        let model = makeModel(readings: losingReadings(), plan: { plan })
        await model.load(now: now)

        XCTAssertEqual(model.weightTrendText, "Trend: down 0.5 kg a week")
        XCTAssertEqual(model.planPaceText, "Plan: down 0.25 kg a week")
        // 9 kg at 0.25 kg a week is 252 days from April 15; at the trend's 0.5 kg a week, 126 days.
        XCTAssertEqual(model.planGoalDayText, "Plan reaches 80 kg on Dec 23, 2026")
        XCTAssertEqual(model.trendGoalDayText, "Trend reaches 80 kg on Aug 19, 2026")
        XCTAssertEqual(model.paceComparison?.plannedGoalDay, day("2026-12-23"))
        XCTAssertEqual(model.paceComparison?.trendGoalDay, day("2026-08-19"))
    }

    func testAPoundPlanIsShownInPoundsWithRoundedUpDays() async {
        let pound = d("0.45359237")
        let plan = WeightPlan(aim: .lose, goalKilograms: d("176") * pound, weeklyPaceKilograms: pound)
        let model = makeModel(readings: losingReadings(), system: .usCustomary, plan: { plan })
        await model.load(now: now)

        XCTAssertEqual(model.planPaceText, "Plan: down 1 lb a week")
        // 9.168 kg at 1 lb a week is 141.48 days -> 142; at 0.5 kg a week, 128.35 days -> 129.
        XCTAssertEqual(model.planGoalDayText, "Plan reaches 176 lb on Sep 4, 2026")
        XCTAssertEqual(model.trendGoalDayText, "Trend reaches 176 lb on Aug 22, 2026")
    }

    func testAGainingPlanSaysUp() async {
        var readings = BodyActivityReadings(latestWeightKg: 61, latestWeightDate: now)
        readings.weightSamples = [
            WeightSample(day: day("2026-04-01"), kilograms: d("60.5")),
            WeightSample(day: day("2026-04-15"), kilograms: 61),
        ]
        let plan = WeightPlan(aim: .gain, goalKilograms: 63, weeklyPaceKilograms: d("0.5"))
        let model = makeModel(readings: readings, plan: { plan })
        await model.load(now: now)

        XCTAssertEqual(model.planPaceText, "Plan: up 0.5 kg a week")
        // 2 kg at 0.5 kg a week is 28 days from April 15; at the trend's 0.25 kg a week, 56 days.
        XCTAssertEqual(model.planGoalDayText, "Plan reaches 63 kg on May 13, 2026")
        XCTAssertEqual(model.trendGoalDayText, "Trend reaches 63 kg on Jun 10, 2026")
    }

    func testWithoutATrendThePlanCountsFromTheLatestWeight() async {
        var readings = BodyActivityReadings(latestWeightKg: 89, latestWeightDate: now)
        readings.weightSamples = [WeightSample(day: day("2026-04-15"), kilograms: 89)]
        let plan = WeightPlan(aim: .lose, goalKilograms: 80, weeklyPaceKilograms: d("0.5"))
        let model = makeModel(readings: readings, plan: { plan })
        await model.load(now: now)

        XCTAssertNil(model.weightTrendText)
        XCTAssertNil(model.trendGoalDayText)
        XCTAssertEqual(model.planPaceText, "Plan: down 0.5 kg a week")
        XCTAssertEqual(model.planGoalDayText, "Plan reaches 80 kg on Aug 19, 2026")
    }

    func testAGoalAlreadyPassedHasNoPlannedDay() async {
        let plan = WeightPlan(aim: .lose, goalKilograms: 90, weeklyPaceKilograms: d("0.5"))
        let model = makeModel(readings: losingReadings(), plan: { plan })
        await model.load(now: now)

        XCTAssertEqual(model.planPaceText, "Plan: down 0.5 kg a week")
        XCTAssertNil(model.planGoalDayText)
        XCTAssertNil(model.trendGoalDayText)
    }

    func testMaintainAndNoPlanShowNoPlanLines() async {
        let maintain = WeightPlan(aim: .maintain, goalKilograms: nil, weeklyPaceKilograms: nil)
        let model = makeModel(readings: losingReadings(), plan: { maintain })
        await model.load(now: now)

        XCTAssertEqual(model.weightTrendText, "Trend: down 0.5 kg a week")
        XCTAssertNil(model.planPaceText)
        XCTAssertNil(model.planGoalDayText)
        XCTAssertNil(model.trendGoalDayText)
        XCTAssertNil(model.paceComparison)
    }

    func testEachLoadReadsThePlanAgain() async {
        var stored: WeightPlan?
        let model = makeModel(readings: losingReadings(), plan: { stored })
        await model.load(now: now)
        XCTAssertNil(model.planPaceText)

        stored = WeightPlan(aim: .lose, goalKilograms: 80, weeklyPaceKilograms: d("0.5"))
        await model.load(now: now)

        XCTAssertEqual(model.planPaceText, "Plan: down 0.5 kg a week")
    }

    func testDaysAreWrittenWithEnglishMonthNames() {
        XCTAssertEqual(BodyActivityViewModel.dayText(day("2027-01-05")), "Jan 5, 2027")
        XCTAssertEqual(BodyActivityViewModel.dayText(day("2026-12-23")), "Dec 23, 2026")
    }

    func testNoLineGradesTheResult() async {
        let plan = WeightPlan(aim: .lose, goalKilograms: 80, weeklyPaceKilograms: d("0.25"))
        let model = makeModel(readings: losingReadings(), plan: { plan })
        await model.load(now: now)

        let lines = [model.weightTrendText, model.planPaceText, model.planGoalDayText, model.trendGoalDayText]
            .compactMap { $0?.lowercased() }
        XCTAssertEqual(lines.count, 4)
        for word in ["ahead", "behind", "on track", "off track", "great", "good", "bad", "slow", "fast"] {
            XCTAssertFalse(lines.contains { $0.contains(word) }, word)
        }
    }
}
