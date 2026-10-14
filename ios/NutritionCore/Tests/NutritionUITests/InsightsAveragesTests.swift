import NutritionDomain
import XCTest

@testable import NutritionUI

final class InsightsAveragesTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    // Wednesday 2023-11-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_049_600)

    private func day(_ key: String, protein: Decimal?) -> InsightsAverages.Day {
        let value: NutrientValue = protein.map { .known($0, .g) } ?? .unknown
        let total = NutrientTotal(
            value: value,
            coverage: Coverage(
                knownCount: protein == nil ? 0 : 1, totalCount: 1, hasBelowReportingThreshold: false,
                hasUnknown: protein == nil))
        return InsightsAverages.Day(key: key, totals: DailyTotals(totals: ["protein": total]))
    }

    private func make(_ days: [InsightsAverages.Day]) -> InsightsAverages {
        InsightsAverages.make(days: days, nutrients: ["protein"], now: now, zone: utc)
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

    func testNothingKnownGivesNoLineRatherThanAZero() {
        XCTAssertTrue(make([day("2023-11-15", protein: nil)]).lines.isEmpty)
        XCTAssertTrue(make([]).lines.isEmpty)
    }
}
