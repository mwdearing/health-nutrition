import XCTest
@testable import NutritionUI

final class InsightsWeekTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let locale = Locale(identifier: "en_US_POSIX")
    // Wednesday 2023-11-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_049_600)

    private func make(_ dates: [Date]) -> InsightsWeek {
        InsightsWeek.make(occurredAt: dates, now: now, zone: utc, locale: locale)
    }

    func testSevenDaysEndingTodayWithCountsPerDay() {
        let day: TimeInterval = 86_400
        let week = make([now, now - 3600, now - day, now - 3 * day])
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.days.last?.entryCount, 2)
        XCTAssertEqual(week.days[5].entryCount, 1)
        XCTAssertEqual(week.days[3].entryCount, 1)
        XCTAssertEqual(week.loggedDays, 3)
        XCTAssertEqual(week.emptyDays, 4)
        XCTAssertEqual(week.headline, "3 of 7 days logged")
        XCTAssertEqual(week.entriesText, "4 entries")
    }

    func testEntriesOutsideTheWindowOrInTheFutureAreLeftOut() {
        let day: TimeInterval = 86_400
        let week = make([now - 8 * day, now + 3600])
        XCTAssertFalse(week.hasAnyEntry)
        XCTAssertEqual(week.entryCount, 0)
        XCTAssertEqual(week.barFraction(for: week.days[0]), 0)
    }

    func testSingularWording() {
        let day: TimeInterval = 86_400
        let week = make([now - 1 * day, now - 2 * day, now - 3 * day, now - 4 * day, now - 5 * day, now])
        XCTAssertEqual(week.emptyDays, 1)
        XCTAssertEqual(week.emptyDaysText, "1 day with no entries")
        XCTAssertEqual(make([now]).entriesText, "1 entry")
    }

    func testBarFractionIsRelativeToTheTallestDay() {
        let week = make([now, now - 60, now - 86_400])
        XCTAssertEqual(week.barFraction(for: week.days[6]), 1)
        XCTAssertEqual(week.barFraction(for: week.days[5]), 0.5, accuracy: 0.0001)
    }
}
