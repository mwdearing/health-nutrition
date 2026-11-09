import NutritionDomain
import XCTest

@testable import NutritionUI

final class TrendsRangeTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    // Wednesday 2023-11-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_049_600)

    private func day(_ offset: Int, kcal: Decimal) -> InsightsAverages.Day {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let date = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd"
        let energy = NutrientTotal(
            value: .known(kcal, .kcal),
            coverage: Coverage(knownCount: 1, totalCount: 1, hasBelowReportingThreshold: false, hasUnknown: false))
        return InsightsAverages.Day(key: formatter.string(from: date), totals: DailyTotals(totals: ["energy": energy]))
    }

    private func make(_ days: [InsightsAverages.Day], _ range: TrendsRange) -> TrendsSummary {
        TrendsSummary.make(
            days: days, goal: 2_000, now: now, zone: utc, locale: Locale(identifier: "en_US"), range: range)
    }

    func testWeekHasSevenDailyBars() {
        let summary = make([day(0, kcal: 2_000)], .week)
        XCTAssertEqual(summary.bars.count, 7)
        XCTAssertEqual(summary.bars.last?.isToday, true)
        XCTAssertEqual(summary.bars.last?.kcal, 2_000)
    }

    func testMonthHasThirtyDailyBars() {
        let summary = make([day(0, kcal: 2_000), day(29, kcal: 1_000)], .month)
        XCTAssertEqual(summary.bars.count, 30)
        XCTAssertEqual(summary.bars.first?.kcal, 1_000)
        XCTAssertEqual(summary.bars.last?.kcal, 2_000)
        XCTAssertEqual(summary.bars.filter(\.isToday).count, 1)
        XCTAssertEqual(summary.bars.last?.spoken, "Nov 15, 2,000 calories")
    }

    func testSixMonthsHasTwentySixWeeklyBars() {
        // Two counted days in the newest week average to 1,500; the oldest week holds one day.
        let days = [day(0, kcal: 1_000), day(1, kcal: 2_000), day(181, kcal: 1_800), day(10, kcal: 900)]
        let summary = make(days, .sixMonths)
        XCTAssertEqual(summary.bars.count, 26)
        XCTAssertEqual(summary.bars.last?.kcal, 1_500)
        XCTAssertEqual(summary.bars.first?.kcal, 1_800)
        XCTAssertEqual(summary.bars[24].kcal, 900)
        XCTAssertNil(summary.bars[10].kcal)
        XCTAssertEqual(summary.bars.last?.isToday, true)
        XCTAssertTrue(summary.bars.last?.spoken.hasPrefix("Week of ") ?? false)
    }

    func testTheAverageCoversTheWholeRange() {
        let days = [day(0, kcal: 2_000), day(20, kcal: 1_000)]
        XCTAssertEqual(make(days, .week).averageKcal, 2_000)
        XCTAssertEqual(make(days, .month).averageKcal, 1_500)
        XCTAssertEqual(make(days, .sixMonths).averageKcal, 1_500)
        XCTAssertEqual(make(days, .month).range.cardTitle, "Last 30 days")
    }

    func testTheRangeWords() {
        XCTAssertEqual(TrendsRange.allCases.map(\.days), [7, 30, 182])
        XCTAssertEqual(TrendsRange.allCases.map(\.title), ["Week", "Month", "6 months"])
    }

    func testTheHealthReadNeverShrinksBelowTheInsightsWindow() {
        XCTAssertEqual(TrendsRange.week.healthReadDays, InsightsAverages.windowDays)
        XCTAssertEqual(TrendsRange.month.healthReadDays, InsightsAverages.windowDays)
        XCTAssertEqual(TrendsRange.sixMonths.healthReadDays, 182)
        XCTAssertTrue(TrendsRange.allCases.allSatisfy { $0.healthReadDays >= InsightsAverages.windowDays })
    }

    func testSixMonthsBucketsAcrossADaylightSavingChange() throws {
        // The clocks go back on 2023-11-05 in Chicago. Now is 2023-11-12, so the newest week is Nov 6 to Nov 12 and
        // the one before it Oct 30 to Nov 5, which holds the 25-hour day.
        let chicago = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        let chicagoNow = Date(timeIntervalSince1970: 1_699_812_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chicago
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = chicago
        formatter.dateFormat = "yyyy-MM-dd"
        func keyed(_ key: String, _ kcal: Decimal) -> InsightsAverages.Day {
            let energy = NutrientTotal(
                value: .known(kcal, .kcal),
                coverage: Coverage(knownCount: 1, totalCount: 1, hasBelowReportingThreshold: false, hasUnknown: false))
            return InsightsAverages.Day(key: key, totals: DailyTotals(totals: ["energy": energy]))
        }
        let today = calendar.startOfDay(for: chicagoNow)
        let oldest = formatter.string(from: try XCTUnwrap(calendar.date(byAdding: .day, value: -181, to: today)))
        let tooOld = formatter.string(from: try XCTUnwrap(calendar.date(byAdding: .day, value: -182, to: today)))
        let days = [
            keyed("2023-11-02", 1_000),  // three days before the change
            keyed("2023-11-06", 2_000),  // the day after it
            keyed(oldest, 1_800), keyed(tooOld, 5_000),
        ]
        let summary = TrendsSummary.make(
            days: days, goal: nil, now: chicagoNow, zone: chicago, locale: Locale(identifier: "en_US"),
            range: .sixMonths)
        XCTAssertEqual(summary.bars.count, 26)
        XCTAssertEqual(summary.bars[25].kcal, 2_000)
        XCTAssertEqual(summary.bars[24].kcal, 1_000)
        XCTAssertEqual(summary.bars[0].kcal, 1_800)
        XCTAssertEqual(summary.bars.compactMap(\.kcal).count, 3)
        XCTAssertEqual(summary.averageKcal, 1_600)
    }

    func testAWeeklyBarIsPartialWhenOneOfItsDaysIsPartial() {
        let partialDay = InsightsAverages.Day(
            key: formattedKey(daysBack: 1), totals: DailyTotals(totals: [:]), isLogged: false,
            outside: .read(values: ["energy": 1_000], readKeys: ["protein"]))
        let summary = make([day(0, kcal: 2_000), partialDay, day(10, kcal: 1_500)], .sixMonths)
        XCTAssertTrue(summary.bars[25].isPartial)
        XCTAssertTrue(summary.bars[25].spoken.contains("at least"))
        XCTAssertFalse(summary.bars[24].isPartial)
    }

    private func formattedKey(daysBack: Int) -> String { day(daysBack, kcal: 0).key }
}
