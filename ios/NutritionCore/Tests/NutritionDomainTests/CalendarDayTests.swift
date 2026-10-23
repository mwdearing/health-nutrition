import XCTest
@testable import NutritionDomain

/// Whole-day arithmetic on the Gregorian calendar, each date checked against a printed calendar.
final class CalendarDayTests: XCTestCase {
    private func day(_ text: String) throws -> CalendarDay {
        try XCTUnwrap(CalendarDay(iso: text), "not a day: \(text)")
    }

    func testLeapYearsFollowTheGregorianRule() {
        XCTAssertNotNil(CalendarDay(year: 2024, month: 2, day: 29))
        XCTAssertNotNil(CalendarDay(year: 2000, month: 2, day: 29))
        XCTAssertNil(CalendarDay(year: 2026, month: 2, day: 29))
        XCTAssertNil(CalendarDay(year: 1900, month: 2, day: 29))
        XCTAssertNil(CalendarDay(year: 2100, month: 2, day: 29))
    }

    func testMonthEndsAndInvalidParts() {
        XCTAssertNotNil(CalendarDay(year: 2026, month: 1, day: 31))
        XCTAssertNotNil(CalendarDay(year: 2026, month: 4, day: 30))
        XCTAssertNil(CalendarDay(year: 2026, month: 4, day: 31))
        XCTAssertNil(CalendarDay(year: 2026, month: 6, day: 31))
        XCTAssertNil(CalendarDay(year: 2026, month: 0, day: 1))
        XCTAssertNil(CalendarDay(year: 2026, month: 13, day: 1))
        XCTAssertNil(CalendarDay(year: 2026, month: 1, day: 0))
    }

    func testYearsOutsideTheRangeAreRefused() {
        XCTAssertNil(CalendarDay(year: 0, month: 1, day: 1))
        XCTAssertNil(CalendarDay(year: 10000, month: 1, day: 1))
        XCTAssertNotNil(CalendarDay(year: 1, month: 1, day: 1))
        XCTAssertNotNil(CalendarDay(year: 9999, month: 12, day: 31))
    }

    func testISOParsingAcceptsOnlyTheExactForm() throws {
        let parsed = try day("2026-04-15")
        XCTAssertEqual(parsed.year, 2026)
        XCTAssertEqual(parsed.month, 4)
        XCTAssertEqual(parsed.day, 15)
        XCTAssertNil(CalendarDay(iso: "2026-4-15"))
        XCTAssertNil(CalendarDay(iso: "2026-04-5"))
        XCTAssertNil(CalendarDay(iso: "2026/04/15"))
        XCTAssertNil(CalendarDay(iso: "2026-04-15T00:00"))
        XCTAssertNil(CalendarDay(iso: " 2026-04-15"))
        XCTAssertNil(CalendarDay(iso: "+026-04-15"))
        XCTAssertNil(CalendarDay(iso: "2026-02-30"))
        XCTAssertNil(CalendarDay(iso: ""))
    }

    func testISOStringPadsEachPart() throws {
        XCTAssertEqual(CalendarDay(year: 2026, month: 1, day: 5)?.isoString, "2026-01-05")
        XCTAssertEqual(CalendarDay(year: 33, month: 3, day: 3)?.isoString, "0033-03-03")
        XCTAssertEqual(try day("2026-12-31").isoString, "2026-12-31")
    }

    func testAddingCrossesMonthAndYearEnds() throws {
        XCTAssertEqual(try day("2026-01-31").adding(days: 1), try day("2026-02-01"))
        XCTAssertEqual(try day("2026-02-28").adding(days: 1), try day("2026-03-01"))
        XCTAssertEqual(try day("2028-02-28").adding(days: 1), try day("2028-02-29"))
        XCTAssertEqual(try day("2026-12-31").adding(days: 1), try day("2027-01-01"))
        XCTAssertEqual(try day("2026-04-15").adding(days: 0), try day("2026-04-15"))
        XCTAssertEqual(try day("2026-01-01").adding(days: 365), try day("2027-01-01"))
        XCTAssertEqual(try day("2028-01-01").adding(days: 366), try day("2029-01-01"))
    }

    func testNegativeOffsetsGoBack() throws {
        XCTAssertEqual(try day("2024-03-01").adding(days: -1), try day("2024-02-29"))
        XCTAssertEqual(try day("2027-01-01").adding(days: -1), try day("2026-12-31"))
        XCTAssertEqual(try day("2026-04-15").adding(days: -27), try day("2026-03-19"))
        XCTAssertEqual(try day("1970-01-01").adding(days: -1), try day("1969-12-31"))
    }

    func testDaysUntilIsOtherMinusSelf() throws {
        XCTAssertEqual(try day("2026-02-01").days(until: try day("2027-03-01")), 393)
        XCTAssertEqual(try day("2027-03-01").days(until: try day("2026-02-01")), -393)
        XCTAssertEqual(try day("2026-04-15").days(until: try day("2026-04-15")), 0)
        XCTAssertEqual(try day("2000-01-01").days(until: try day("2100-01-01")), 36_525)
    }

    func testOrderingIsChronological() throws {
        XCTAssertTrue(try day("2026-03-31") < day("2026-04-01"))
        XCTAssertTrue(try day("2025-12-31") < day("2026-01-01"))
        XCTAssertFalse(try day("2026-04-01") < day("2026-04-01"))
        XCTAssertEqual(try day("2026-04-01"), CalendarDay(year: 2026, month: 4, day: 1))
    }

    func testRoundTripOverManyDays() throws {
        let start = try day("1999-12-25")
        var previous = start
        for offset in 1...1500 {
            let next = start.adding(days: offset)
            XCTAssertEqual(previous.adding(days: 1), next)
            XCTAssertEqual(start.days(until: next), offset)
            XCTAssertEqual(CalendarDay(iso: next.isoString), next)
            previous = next
        }
    }

    func testAddingWholeDaysStaysInsideTheCalendarRange() {
        let first = CalendarDay(year: 1, month: 1, day: 1)!
        XCTAssertNil(first.adding(wholeDays: -1))
        XCTAssertEqual(first.adding(wholeDays: 0), first)
        let last = CalendarDay(year: 9999, month: 12, day: 31)!
        XCTAssertNil(last.adding(wholeDays: 1))
        XCTAssertEqual(first.adding(wholeDays: Decimal(first.days(until: last))), last)
    }
}
