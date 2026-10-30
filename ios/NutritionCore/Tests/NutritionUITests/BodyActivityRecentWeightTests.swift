import Foundation
import NutritionDomain
import XCTest

@testable import NutritionUI

/// With no trend, Today's planned goal day counts from the latest weigh-in only when that weigh-in falls
/// inside the trend's 28-day window. An older weigh-in still shows as the weight, but gives no planned day.
@MainActor
final class BodyActivityRecentWeightTests: XCTestCase {
    private final class Reader: BodyActivityReading {
        var hasAskedForReadAccess = true
        var readings = BodyActivityReadings.empty

        func requestReadAccess() async {}

        func read(now: Date) async -> BodyActivityReadings { readings }
    }

    /// 2026-04-15 12:00 UTC. In UTC the window is March 19 to April 15.
    private let now = Date(timeIntervalSince1970: 1_776_254_400)
    private let day: TimeInterval = 86_400
    private let plan = WeightPlan(aim: .lose, goalKilograms: 80, weeklyPaceKilograms: Decimal(string: "0.5")!)

    private func calendar(_ identifier: Calendar.Identifier = .gregorian, zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    /// One weigh-in of 89 kg at `date`, so there is never a trend, and a saved plan to lose to 80 kg at 0.5 kg a week.
    private func makeModel(latestAt date: Date?, calendar: Calendar? = nil) -> BodyActivityViewModel {
        let reader = Reader()
        var readings = BodyActivityReadings(latestWeightKg: 89, latestWeightDate: date)
        if let date {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = (calendar ?? self.calendar()).timeZone
            let parts = gregorian.dateComponents([.year, .month, .day], from: date)
            readings.weightSamples = [
                WeightSample(day: CalendarDay(year: parts.year!, month: parts.month!, day: parts.day!)!, kilograms: 89)
            ]
        }
        reader.readings = readings
        let saved = plan
        return BodyActivityViewModel(
            reader: reader, unitSystem: { .metric }, weightPlan: { saved }, calendar: calendar ?? self.calendar())
    }

    func testAWeighInFromTodayGivesThePlannedDay() async {
        let model = makeModel(latestAt: now)
        await model.load(now: now)

        XCTAssertNil(model.weightTrendText)
        // 9 kg at 0.5 kg a week is 126 days from April 15.
        XCTAssertEqual(model.planGoalDayText, "Plan reaches 80 kg on Aug 19, 2026")
    }

    func testAWeighInOnTheWindowsFirstDayStillCounts() async {
        // March 19 is the first of the 28 days that end on April 15.
        let model = makeModel(latestAt: now.addingTimeInterval(-27 * day))
        await model.load(now: now)

        XCTAssertEqual(model.planGoalDayText, "Plan reaches 80 kg on Aug 19, 2026")
    }

    func testAWeighInOlderThanTheWindowGivesNoPlannedDay() async {
        // March 18 is one day before the window.
        let model = makeModel(latestAt: now.addingTimeInterval(-28 * day))
        await model.load(now: now)

        XCTAssertEqual(model.weightText, "89 kg", "the latest weight still shows")
        XCTAssertEqual(model.planPaceText, "Plan: down 0.5 kg a week", "the plan's own pace still shows")
        XCTAssertNil(model.planGoalDayText)
        XCTAssertNil(model.trendGoalDayText)
        XCTAssertNil(model.paceComparison)
    }

    func testAWeighInWithNoDateGivesNoPlannedDay() async {
        let model = makeModel(latestAt: nil)
        await model.load(now: now)

        XCTAssertEqual(model.weightText, "89 kg")
        XCTAssertNil(model.planGoalDayText)
        XCTAssertNil(model.paceComparison)
    }

    func testAWeighInDatedAfterTodayGivesNoPlannedDay() async {
        let model = makeModel(latestAt: now.addingTimeInterval(day))
        await model.load(now: now)

        XCTAssertNil(model.planGoalDayText)
        XCTAssertNil(model.paceComparison)
    }

    func testTheWindowFollowsTheCalendarsTimeZone() async {
        // March 19 03:00 UTC is inside the UTC window, but it is still March 18 at 20:00 in Los Angeles,
        // where April 15 12:00 UTC is April 15 05:00 and the window starts on March 19.
        let weighIn = now.addingTimeInterval(-27 * day - 9 * 3_600)

        let utc = makeModel(latestAt: weighIn)
        await utc.load(now: now)
        XCTAssertEqual(utc.planGoalDayText, "Plan reaches 80 kg on Aug 19, 2026")

        let losAngeles = makeModel(latestAt: weighIn, calendar: calendar(zone: "America/Los_Angeles"))
        await losAngeles.load(now: now)
        XCTAssertNil(losAngeles.planGoalDayText)
    }

    func testTheWindowUsesGregorianDaysOnADeviceSetToAnotherCalendar() async {
        let inside = makeModel(latestAt: now.addingTimeInterval(-27 * day), calendar: calendar(.buddhist))
        await inside.load(now: now)
        XCTAssertEqual(inside.planGoalDayText, "Plan reaches 80 kg on Aug 19, 2026")

        let outside = makeModel(latestAt: now.addingTimeInterval(-28 * day), calendar: calendar(.buddhist))
        await outside.load(now: now)
        XCTAssertNil(outside.planGoalDayText)
    }

    func testATrendStillGivesThePlannedDayWhateverTheLatestWeighInsDate() async {
        // The trend weight is used when there is a trend; the latest weigh-in's date does not matter then.
        let reader = Reader()
        var readings = BodyActivityReadings(latestWeightKg: 89, latestWeightDate: nil)
        readings.weightSamples = [
            WeightSample(day: CalendarDay(iso: "2026-04-01")!, kilograms: 90),
            WeightSample(day: CalendarDay(iso: "2026-04-15")!, kilograms: 89),
        ]
        reader.readings = readings
        let saved = plan
        let model = BodyActivityViewModel(
            reader: reader, unitSystem: { .metric }, weightPlan: { saved }, calendar: calendar())
        await model.load(now: now)

        XCTAssertEqual(model.weightTrendText, "Trend: down 0.5 kg a week")
        XCTAssertEqual(model.planGoalDayText, "Plan reaches 80 kg on Aug 19, 2026")
    }
}
