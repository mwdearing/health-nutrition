import NutritionDomain
import XCTest

@testable import NutritionUI

final class TrendsSummaryTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    // Wednesday 2023-11-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_049_600)

    private func total(_ amount: Decimal, _ unit: MeasureUnit) -> NutrientTotal {
        NutrientTotal(
            value: .known(amount, unit),
            coverage: Coverage(knownCount: 1, totalCount: 1, hasBelowReportingThreshold: false, hasUnknown: false))
    }

    private func day(
        _ key: String, kcal: Decimal, protein: Decimal = 0, carbs: Decimal = 0, fat: Decimal = 0
    ) -> InsightsAverages.Day {
        InsightsAverages.Day(
            key: key,
            totals: DailyTotals(totals: [
                "energy": total(kcal, .kcal), "protein": total(protein, .g),
                "carbohydrate": total(carbs, .g), "fat": total(fat, .g),
            ]))
    }

    private func make(_ days: [InsightsAverages.Day], goal: Decimal? = 2_000) -> TrendsSummary {
        TrendsSummary.make(days: days, goal: goal, now: now, zone: utc, locale: Locale(identifier: "en_US"))
    }

    /// The summary counts the days Insights counts for a week: a day only Health knows counts, a day outside the
    /// seven does not, and a day with only water does not.
    func testTheAverageUsesTheSameDaysAsInsights() {
        let healthOnly = InsightsAverages.Day(
            key: "2023-11-14", totals: DailyTotals(totals: [:]), isLogged: false,
            outside: .read(values: ["energy": 1_000], readKeys: ["energy"]))
        let waterOnly = InsightsAverages.Day(key: "2023-11-13", totals: DailyTotals(totals: [:]), isLogged: false)
        let days = [
            day("2023-11-15", kcal: 2_000), healthOnly, waterOnly,
            day("2023-11-08", kcal: 5_000),  // eight days back: outside the seven
        ]
        let summary = make(days)
        XCTAssertEqual(summary.averageKcal, 1_500)
        let insights = InsightsAverages.make(days: days, nutrients: ["energy"], now: now, zone: utc, window: 7)
        XCTAssertEqual(insights.lines.count, 1)
        XCTAssertTrue(insights.lines[0].text.contains("1,500"), insights.lines[0].text)
        XCTAssertEqual(summary.bars.count, 7)
        XCTAssertEqual(summary.bars.map(\.kcal), [nil, nil, nil, nil, nil, 1_000, 2_000])
        XCTAssertEqual(summary.bars.last?.isToday, true)
        XCTAssertEqual(summary.bars.filter(\.isToday).count, 1)
    }

    func testUnderAndOverGoalAreBothPositiveFigures() {
        XCTAssertEqual(make([day("2023-11-15", kcal: 1_850)]).difference, .under(150))
        XCTAssertEqual(make([day("2023-11-15", kcal: 2_150)]).difference, .over(150))
        XCTAssertEqual(make([day("2023-11-15", kcal: 2_000)]).difference, .onGoal)
        XCTAssertEqual(TrendsSummary.GoalDifference.under(150).text, "150 under goal")
        XCTAssertEqual(TrendsSummary.GoalDifference.over(150).text, "150 over goal")
        XCTAssertEqual(TrendsSummary.GoalDifference.onGoal.text, "On goal")
        XCTAssertFalse(TrendsSummary.GoalDifference.under(150).text.contains("-"))
    }

    func testNoGoalMeansNoRuleAndNoDifference() {
        for goal in [nil, Decimal(0)] as [Decimal?] {
            let summary = make([day("2023-11-15", kcal: 1_850)], goal: goal)
            XCTAssertNil(summary.goal)
            XCTAssertNil(summary.difference)
            XCTAssertEqual(summary.averageKcal, 1_850)
        }
    }

    func testMacroSharesComeFromTheAverageGrams() {
        // 100 g protein (400 kcal), 200 g carbs (800 kcal), 100 g fat (900 kcal): 2,100 kcal.
        let summary = make([day("2023-11-15", kcal: 2_100, protein: 100, carbs: 200, fat: 100)])
        XCTAssertEqual(summary.proteinGrams, 100)
        XCTAssertEqual(summary.carbGrams, 200)
        XCTAssertEqual(summary.fatGrams, 100)
        let shares = try! XCTUnwrap(summary.macroShares)
        XCTAssertEqual(shares.protein, 400.0 / 2_100.0, accuracy: 0.0001)
        XCTAssertEqual(shares.carbs, 800.0 / 2_100.0, accuracy: 0.0001)
        XCTAssertEqual(shares.fat, 900.0 / 2_100.0, accuracy: 0.0001)
        XCTAssertEqual(shares.protein + shares.carbs + shares.fat, 1, accuracy: 0.0001)
    }

    func testNothingLoggedShowsNoAverage() {
        let summary = make([])
        XCTAssertFalse(summary.hasData)
        XCTAssertNil(summary.averageKcal)
        XCTAssertNil(summary.difference)
        XCTAssertNil(summary.macroShares)
        XCTAssertTrue(summary.bars.allSatisfy { $0.kcal == nil })
        XCTAssertEqual(TrendsSummary.emptyText, "Nothing logged this week")
    }

    /// A day that states only part of a figure makes the average a minimum, as Insights says, and the cards agree.
    func testAPartialDayShowsAtLeast() {
        let healthOnlyWithJournalGap = InsightsAverages.Day(
            key: "2023-11-14", totals: DailyTotals(totals: [:]), isLogged: false,
            outside: .read(values: ["energy": 1_000], readKeys: []))
        let partial = make([day("2023-11-15", kcal: 2_000), healthOnlyWithJournalGap])
        XCTAssertTrue(partial.energyIsPartial)
        let insights = InsightsAverages.make(
            days: [day("2023-11-15", kcal: 2_000), healthOnlyWithJournalGap], nutrients: ["energy"], now: now,
            zone: utc, window: 7)
        XCTAssertTrue(insights.lines[0].text.contains("at least"), insights.lines[0].text)
        XCTAssertEqual(TrendsSummary.gramsText(42, partial: true), "at least 42 g")
        let whole = make([day("2023-11-15", kcal: 2_000, protein: 80)])
        XCTAssertFalse(whole.energyIsPartial)
        XCTAssertFalse(whole.proteinIsPartial)
        XCTAssertEqual(TrendsSummary.gramsText(42), "42 g")
    }
}
