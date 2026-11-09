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
}
