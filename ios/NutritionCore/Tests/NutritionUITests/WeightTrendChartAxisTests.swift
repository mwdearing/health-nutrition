import Foundation
import NutritionDomain
import XCTest
@testable import NutritionUI

/// The weight chart places each day on its axis and labels the axis in one fixed Gregorian UTC calendar, so a
/// device far east of UTC still sees each point under the day it was weighed, the day a marker's label names.
final class WeightTrendChartAxisTests: XCTestCase {
    private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }

    func testTheAxisCalendarIsGregorianUTC() {
        XCTAssertEqual(WeightTrendChart.axisCalendar.identifier, .gregorian)
        XCTAssertEqual(WeightTrendChart.axisCalendar.timeZone, TimeZone(identifier: "UTC"))
    }

    func testEachDayIsPlacedOnItsOwnDateInTheAxisCalendar() {
        for iso in ["2026-04-10", "2026-02-28", "2026-03-31", "2026-12-31"] {
            let parts = WeightTrendChart.axisCalendar.dateComponents(
                [.year, .month, .day], from: WeightTrendChart.position(of: day(iso)))
            XCTAssertEqual(CalendarDay(year: parts.year!, month: parts.month!, day: parts.day!), day(iso), iso)
        }
    }

    func testAFarEastDeviceWouldNameTheNextDayWithoutTheAxisCalendar() {
        let position = WeightTrendChart.position(of: day("2026-04-10"))
        var auckland = Calendar(identifier: .gregorian)
        auckland.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        XCTAssertEqual(auckland.component(.day, from: position), 11, "why the axis must not use the device zone")
        XCTAssertEqual(WeightTrendChart.axisCalendar.component(.day, from: position), 10)
    }
}
