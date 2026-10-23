import XCTest
@testable import NutritionDomain

/// The weight trend's arithmetic, with each figure worked out by hand in its test: a least-squares line
/// through the daily values, the slope times seven for the week, and the days to the goal rounded up.
final class WeightTrendTests: XCTestCase {
    private let fixtureA: [WeightSample] = WeightTrendTests.samples([
        ("2026-03-26", "91"), ("2026-04-08", "89.5"), ("2026-04-15", "89"),
    ])

    private func testDay(_ iso: String) -> CalendarDay {
        CalendarDay(iso: iso)!
    }

    private func decimal(_ text: String) -> Decimal {
        Decimal(string: text)!
    }

    private static func samples(_ pairs: [(String, String)]) -> [WeightSample] {
        pairs.map { WeightSample(day: CalendarDay(iso: $0.0)!, kilograms: Decimal(string: $0.1)!) }
    }

    func testThreeWeighInsWithAGoalGiveTheWeeklyChangeTrendAndGoalDay() {
        // Days from 2026-03-19: 7, 20, 27. Slope -21 / 206 per day, so -0.71 a week.
        // The line at day 27 is 89.8333 - 0.9175 = 88.9159 -> 88.92. 8.9159 / 0.101942 = 87.46 -> 88 days.
        let result = WeightTrend.compute(
            samples: fixtureA, through: testDay("2026-04-15"), goalKilograms: decimal("80"))
        XCTAssertEqual(result.from, testDay("2026-03-19"))
        XCTAssertEqual(result.through, testDay("2026-04-15"))
        XCTAssertEqual(result.daysUsed, 3)
        XCTAssertEqual(result.weeklyChangeKilograms, decimal("-0.71"))
        XCTAssertEqual(result.trendKilograms, decimal("88.92"))
        XCTAssertEqual(result.projectedGoalDay, testDay("2026-07-12"))
        XCTAssertTrue(result.hasEnoughData)
    }

    func testAFourteenDayWindowUsesOnlyTheRecentTwoDays() {
        // Window starts 2026-04-02, so only 04-08 and 04-15 count: slope -0.5 / 7 per day.
        let result = WeightTrend.compute(
            samples: fixtureA, through: testDay("2026-04-15"), windowDays: 14, goalKilograms: decimal("80"))
        XCTAssertEqual(result.from, testDay("2026-04-02"))
        XCTAssertEqual(result.daysUsed, 2)
        XCTAssertEqual(result.weeklyChangeKilograms, decimal("-0.5"))
        XCTAssertEqual(result.trendKilograms, decimal("89"))
        // 9 / (0.5 / 7) = 126 days after 2026-04-15.
        XCTAssertEqual(result.projectedGoalDay, testDay("2026-08-19"))
    }

    func testTheWindowLengthIsClampedIntoItsRange() {
        XCTAssertEqual(
            WeightTrend.compute(samples: fixtureA, through: testDay("2026-04-15"), windowDays: 7,
                goalKilograms: nil).from,
            testDay("2026-04-02"))
        XCTAssertEqual(
            WeightTrend.compute(samples: fixtureA, through: testDay("2026-04-15"), windowDays: 100,
                goalKilograms: nil).from,
            testDay("2026-02-19"))
        XCTAssertEqual(
            WeightTrend.compute(samples: fixtureA, through: testDay("2026-04-15"),
                goalKilograms: nil).from,
            testDay("2026-03-19"))
    }

    func testOneDayOfDataGivesNoTrend() {
        let result = WeightTrend.compute(
            samples: fixtureA, through: testDay("2026-03-27"), goalKilograms: decimal("80"))
        XCTAssertEqual(result.daysUsed, 1)
        XCTAssertNil(result.weeklyChangeKilograms)
        XCTAssertNil(result.trendKilograms)
        XCTAssertNil(result.projectedGoalDay)
        XCTAssertFalse(result.hasEnoughData)
    }

    func testASpanOfSixDaysIsNotEnough() {
        let twoDays = Self.samples([("2026-04-09", "90"), ("2026-04-15", "89")])
        let result = WeightTrend.compute(
            samples: twoDays, through: testDay("2026-04-15"), goalKilograms: decimal("80"))
        XCTAssertEqual(result.daysUsed, 2)
        XCTAssertNil(result.weeklyChangeKilograms)
        XCTAssertNil(result.trendKilograms)
        XCTAssertNil(result.projectedGoalDay)
        XCTAssertFalse(result.hasEnoughData)
    }

    func testASpanOfExactlySevenDaysIsEnough() {
        let twoDays = Self.samples([("2026-04-08", "90"), ("2026-04-15", "89")])
        let result = WeightTrend.compute(samples: twoDays, through: testDay("2026-04-15"), goalKilograms: nil)
        XCTAssertEqual(result.daysUsed, 2)
        XCTAssertEqual(result.weeklyChangeKilograms, decimal("-1"))
        XCTAssertEqual(result.trendKilograms, decimal("89"))
        XCTAssertTrue(result.hasEnoughData)
    }

    func testNoSamplesGivesZeroDays() {
        let result = WeightTrend.compute(samples: [], through: testDay("2026-04-15"), goalKilograms: decimal("80"))
        XCTAssertEqual(result.daysUsed, 0)
        XCTAssertNil(result.weeklyChangeKilograms)
        XCTAssertFalse(result.hasEnoughData)
    }

    func testSamplesOutsideTheWindowAreIgnoredAndSameDayReadingsAreAveraged() {
        // Window from 2026-03-19: 03-01 and 04-20 are out. The two 04-15 readings average to 89.
        // Daily values 04-01 90.2, 04-08 89.7, 04-15 89.0: slope -0.6 a week, trend 89.03.
        // 9.0333 / 0.085714 = 105.39 -> 106 days after 04-15, which is 2026-07-30.
        let mixed = Self.samples([
            ("2026-04-15", "88.6"), ("2026-03-01", "95"), ("2026-04-01", "90.2"),
            ("2026-04-15", "89.4"), ("2026-04-08", "89.7"), ("2026-04-20", "70"),
        ])
        let result = WeightTrend.compute(samples: mixed, through: testDay("2026-04-15"), goalKilograms: decimal("80"))
        XCTAssertEqual(result.daysUsed, 3)
        XCTAssertEqual(result.weeklyChangeKilograms, decimal("-0.6"))
        XCTAssertEqual(result.trendKilograms, decimal("89.03"))
        XCTAssertEqual(result.projectedGoalDay, testDay("2026-07-30"))
    }

    func testAGainingTrendProjectsTowardAHigherGoal() {
        // Days from 05-01: 0, 7, 14, 21. Slope 13.3 / 245 per day, so 0.38 a week.
        // The line at day 21 is 60.6 + 0.57 = 61.17. 3.83 / 0.054286 = 70.55 -> 71 days after 05-22.
        let gain = Self.samples([
            ("2026-05-01", "60"), ("2026-05-08", "60.4"), ("2026-05-15", "60.9"), ("2026-05-22", "61.1"),
        ])
        let result = WeightTrend.compute(samples: gain, through: testDay("2026-05-22"), goalKilograms: decimal("65"))
        XCTAssertEqual(result.daysUsed, 4)
        XCTAssertEqual(result.weeklyChangeKilograms, decimal("0.38"))
        XCTAssertEqual(result.trendKilograms, decimal("61.17"))
        XCTAssertEqual(result.projectedGoalDay, testDay("2026-08-01"))
    }

    func testAGainingTrendWithALowerGoalHasNoGoalDay() {
        let gain = Self.samples([
            ("2026-05-01", "60"), ("2026-05-08", "60.4"), ("2026-05-15", "60.9"), ("2026-05-22", "61.1"),
        ])
        let result = WeightTrend.compute(samples: gain, through: testDay("2026-05-22"), goalKilograms: decimal("55"))
        XCTAssertEqual(result.weeklyChangeKilograms, decimal("0.38"))
        XCTAssertNil(result.projectedGoalDay)
    }

    func testNoGoalGivesATrendWithoutAGoalDay() {
        let gain = Self.samples([
            ("2026-05-01", "60"), ("2026-05-08", "60.4"), ("2026-05-15", "60.9"), ("2026-05-22", "61.1"),
        ])
        let result = WeightTrend.compute(samples: gain, through: testDay("2026-05-22"), goalKilograms: nil)
        XCTAssertTrue(result.hasEnoughData)
        XCTAssertNil(result.projectedGoalDay)
    }

    func testAFlatWeightHasZeroChangeAndNoGoalDay() {
        let flat = Self.samples([("2026-04-01", "80"), ("2026-04-15", "80")])
        let result = WeightTrend.compute(samples: flat, through: testDay("2026-04-15"), goalKilograms: decimal("75"))
        XCTAssertEqual(result.weeklyChangeKilograms, decimal("0"))
        XCTAssertEqual(result.trendKilograms, decimal("80"))
        XCTAssertNil(result.projectedGoalDay)
        XCTAssertTrue(result.hasEnoughData)
    }

    func testTheResultTypeCarriesItsMemberwiseFields() {
        let result = WeightTrendResult(
            from: testDay("2026-03-19"), through: testDay("2026-04-15"), daysUsed: 3,
            weeklyChangeKilograms: nil, trendKilograms: nil, projectedGoalDay: nil)
        XCTAssertFalse(result.hasEnoughData)
        XCTAssertEqual(result.daysUsed, 3)
    }

    func testTheConstantsKeepTheirPublishedValues() {
        XCTAssertEqual(WeightTrend.defaultWindowDays, 28)
        XCTAssertEqual(WeightTrend.minimumSpanDays, 7)
        XCTAssertEqual(WeightTrend.windowRange, 14...56)
    }
}
