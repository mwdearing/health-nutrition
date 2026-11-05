import NutritionDomain
import XCTest

@testable import NutritionUI

final class InsightsAveragesTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    // Wednesday 2023-11-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_049_600)

    private func day(_ key: String, protein: Decimal?, isLogged: Bool = true) -> InsightsAverages.Day {
        let value: NutrientValue = protein.map { .known($0, .g) } ?? .unknown
        let total = NutrientTotal(
            value: value,
            coverage: Coverage(
                knownCount: protein == nil ? 0 : 1, totalCount: 1, hasBelowReportingThreshold: false,
                hasUnknown: protein == nil))
        return InsightsAverages.Day(key: key, totals: DailyTotals(totals: ["protein": total]), isLogged: isLogged)
    }

    private func make(_ days: [InsightsAverages.Day]) -> InsightsAverages {
        InsightsAverages.make(days: days, nutrients: ["protein"], now: now, zone: utc)
    }

    private func healthDay(
        _ key: String, values: [String: Decimal], readKeys: Set<String>, journalProtein: Decimal? = nil,
        isLogged: Bool = false
    ) -> InsightsAverages.Day {
        let base = day(key, protein: journalProtein, isLogged: isLogged)
        return InsightsAverages.Day(
            key: key, totals: base.totals, isLogged: isLogged, outside: .read(values: values, readKeys: readKeys))
    }

    /// Health's amount is added to the journal's for the same day, as Today adds it (#1268).
    func testHealthAmountsAreAddedToTheJournalsForTheSameDay() {
        let result = make([healthDay("2023-11-15", values: ["protein": 20], readKeys: ["protein"], journalProtein: 40, isLogged: true)])
        XCTAssertEqual(result.lines.map(\.text), ["Protein: average 60 g a day over 1 logged day"])
    }

    /// A day only Health knows counts, and a nutrient Health read with no samples is a known zero for it.
    func testAHealthOnlyDayCountsAndAKnownZeroIsAverageIn() {
        let result = make([
            day("2023-11-15", protein: 60),
            healthDay("2023-11-14", values: ["energy": 500], readKeys: ["energy", "protein"]),
        ])
        XCTAssertEqual(result.lines.map(\.text), ["Protein: average 30 g a day over 2 logged days"])
    }

    func testAHealthOnlyDayWithAProteinAmountIsAveragedWithTheJournalDay() {
        let result = make([
            day("2023-11-15", protein: 50),
            healthDay("2023-11-14", values: ["protein": 30], readKeys: ["protein"]),
        ])
        XCTAssertEqual(result.lines.map(\.text), ["Protein: average 40 g a day over 2 logged days"])
    }

    /// A Health query that did not run leaves the day's figure a minimum, never a guessed total.
    func testAnUnreadHealthNutrientMakesTheDayAMinimum() {
        let result = make([
            healthDay("2023-11-15", values: ["energy": 500], readKeys: ["energy"], journalProtein: 40, isLogged: true)
        ])
        XCTAssertEqual(result.lines.map(\.text), ["Protein: at least 40 g a day over 1 logged day"])
    }

    /// Health adding nothing to a logged day that states no protein keeps the day unknown, as Today does, so it is
    /// not averaged in as a zero.
    func testAKnownZeroFromHealthDoesNotTurnAnUnknownJournalDayIntoZero() {
        let result = make([
            day("2023-11-15", protein: 60),
            healthDay("2023-11-14", values: ["energy": 500], readKeys: ["energy", "protein"], journalProtein: nil, isLogged: true),
        ])
        XCTAssertEqual(result.lines.map(\.text), ["Protein: average 60 g a day over 1 logged day"])
    }

    /// A query that did not finish and found nothing leaves the day unknown, never a zero minimum.
    func testAnUnfinishedHealthZeroLeavesTheDayOut() {
        let result = make([
            day("2023-11-15", protein: 60),
            healthDay("2023-11-14", values: ["energy": 500, "protein": 0], readKeys: ["energy"]),
            healthDay("2023-11-13", values: ["energy": 500, "protein": 0], readKeys: ["energy"], journalProtein: nil, isLogged: true),
        ])
        XCTAssertEqual(result.lines.map(\.text), ["Protein: average 60 g a day over 1 logged day"])
    }

    /// A query that did not finish keeps the subtotal it converted, and the day reads as at least.
    func testAnUnfinishedHealthQueryKeepsItsSubtotalAsAMinimum() {
        let result = make([
            healthDay("2023-11-15", values: ["protein": 25], readKeys: [], journalProtein: 40, isLogged: true),
            healthDay("2023-11-14", values: ["protein": 30], readKeys: []),
        ])
        XCTAssertEqual(result.lines.map(\.text), ["Protein: at least 47.5 g a day over 2 logged days"])
    }

    /// Water alone does not make a Health-only day a logged day.
    func testAWaterOnlyHealthDayIsLeftOut() {
        let result = make([
            day("2023-11-15", protein: 60),
            healthDay("2023-11-14", values: ["water": 500], readKeys: ["water", "protein"]),
        ])
        XCTAssertEqual(result.lines.map(\.text), ["Protein: average 60 g a day over 1 logged day"])
    }

    func testAveragesOnlyTheKnownDaysInTheWindowAndSaysHowManyThereWere() {
        let result = make([
            day("2023-11-15", protein: 60), day("2023-11-14", protein: 40), day("2023-11-13", protein: nil),
        ])
        XCTAssertEqual(result.lines.map(\.text), ["Protein: average 50 g a day over 2 logged days"])
    }

    func testDaysOlderThanThirtyDaysAndFutureDaysAreLeftOut() {
        // 2023-10-16 is 30 days before the 15th, so the window is 2023-10-17 through 2023-11-15.
        let result = make([
            day("2023-10-16", protein: 1_000), day("2023-10-17", protein: 30), day("2023-11-16", protein: 900),
        ])
        XCTAssertEqual(result.lines.map(\.text), ["Protein: average 30 g a day over 1 logged day"])
    }

    /// A partly logged day counts with its known sum, and the line says the average is a minimum (#510).
    func testPartlyLoggedDaysCountAsMinimums() {
        let partial = InsightsAverages.Day(
            key: "2023-11-14",
            totals: DailyTotals(
                totals: ["protein": NutrientTotal(value: .unknown, coverage: Coverage(
                    knownCount: 1, totalCount: 2, hasBelowReportingThreshold: false, hasUnknown: true))],
                knownSums: ["protein": .known(30, .g)], missingCounts: ["protein": 1]))
        let result = make([day("2023-11-15", protein: 60), partial])
        XCTAssertEqual(result.lines.map(\.text), ["Protein: at least 45 g a day over 2 logged days"])
    }

    /// A day with nothing known for the nutrient is left out of its count, never counted as 0.
    func testAWhollyUnknownDayIsLeftOutOfTheCount() {
        let result = make([day("2023-11-15", protein: 60), day("2023-11-14", protein: nil)])
        XCTAssertEqual(result.lines.map(\.text), ["Protein: average 60 g a day over 1 logged day"])
    }

    func testNothingKnownGivesNoLineRatherThanAZero() {
        XCTAssertTrue(make([day("2023-11-15", protein: nil)]).lines.isEmpty)
        XCTAssertTrue(make([]).lines.isEmpty)
    }

    func testADayWithOnlyWaterOrSupplementsDoesNotPullTheAverageDown() {
        let result = make([
            day("2023-11-15", protein: 60), day("2023-11-14", protein: 0, isLogged: false),
        ])
        XCTAssertEqual(result.lines.map(\.text), ["Protein: average 60 g a day over 1 logged day"])
    }
}
