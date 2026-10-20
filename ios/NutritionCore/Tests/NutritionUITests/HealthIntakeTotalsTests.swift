import XCTest

import NutritionDomain
import NutritionJournal

@testable import NutritionUI

final class HealthIntakeTotalsTests: XCTestCase {
    private let energyUnit = HealthKitWritePlanner.mapping(for: "energy")!.unit
    private let proteinUnit = HealthKitWritePlanner.mapping(for: "protein")!.unit

    private func line(_ nutrient: String, known value: Decimal, unit: MeasureUnit) -> NutrientProgressLine {
        NutrientProgressLine(nutrient: nutrient, amount: .known(value, unit), goal: nil)
    }

    /// A day whose journal has entries with no value: the known part is in `knownSum`, the whole day is unknown.
    private func partialLine(_ nutrient: String, knownSum value: Decimal, unit: MeasureUnit) -> NutrientProgressLine {
        NutrientProgressLine(
            nutrient: nutrient, amount: .unknown, goal: nil, isPartial: true,
            knownSum: .known(value, unit), missingCount: 1)
    }

    private func unknownLine(_ nutrient: String) -> NutrientProgressLine {
        NutrientProgressLine(nutrient: nutrient, amount: .unknown, goal: nil)
    }

    func testNotConnectedLeavesEveryLineAsItWas() {
        let lines = [line("energy", known: 500, unit: energyUnit), unknownLine("protein")]
        XCTAssertEqual(HealthIntakeTotals.combine(lines, outside: .notConnected), lines)
    }

    func testHealthValueAddsToAFullyKnownJournalTotal() {
        let combined = HealthIntakeTotals.combine(
            [line("energy", known: 500, unit: energyUnit)], outside: .read(values: ["energy": 620], readKeys: ["energy"]))
        XCTAssertEqual(combined.first?.amount, .known(1120, energyUnit))
        XCTAssertEqual(combined.first?.isPartial, false)
    }

    func testMissingHealthKeyMakesTheTotalAtLeastNotZero() {
        let combined = HealthIntakeTotals.combine(
            [line("protein", known: 40, unit: proteinUnit)], outside: .read(values: ["energy": 620], readKeys: ["energy"]))
        XCTAssertEqual(combined.first?.amount, .unknown)
        XCTAssertEqual(combined.first?.isPartial, true)
        XCTAssertEqual(combined.first?.knownSum, .known(40, proteinUnit))
    }

    func testFailedReadKeepsTheJournalTotalAsAtLeast() {
        let combined = HealthIntakeTotals.combine(
            [line("energy", known: 500, unit: energyUnit)], outside: .read(values: [:], readKeys: []))
        XCTAssertEqual(combined.first?.isPartial, true)
        XCTAssertEqual(combined.first?.knownSum, .known(500, energyUnit))
    }

    func testPartialJournalPlusHealthStaysPartialWithTheSum() {
        let combined = HealthIntakeTotals.combine(
            [partialLine("energy", knownSum: 300, unit: energyUnit)], outside: .read(values: ["energy": 620], readKeys: ["energy"]))
        XCTAssertEqual(combined.first?.isPartial, true)
        XCTAssertEqual(combined.first?.knownSum, .known(920, energyUnit))
        XCTAssertEqual(combined.first?.missingCount, 1)
    }

    func testHealthOnlyDayIsAtLeastTheHealthValue() {
        let combined = HealthIntakeTotals.combine([unknownLine("energy")], outside: .read(values: ["energy": 620], readKeys: ["energy"]))
        XCTAssertEqual(combined.first?.isPartial, true)
        XCTAssertEqual(combined.first?.knownSum, .known(620, energyUnit))
    }

    func testExplicitZeroFromHealthIsAKnownValue() {
        let combined = HealthIntakeTotals.combine(
            [line("energy", known: 500, unit: energyUnit)], outside: .read(values: ["energy": 0], readKeys: ["energy"]))
        XCTAssertEqual(combined.first?.amount, .known(500, energyUnit))
        XCTAssertEqual(combined.first?.isPartial, false)
    }

    func testEmptyHealthReadIsAKnownZeroNotAtLeast() {
        let combined = HealthIntakeTotals.combine(
            [line("energy", known: 500, unit: energyUnit)], outside: .read(values: [:], readKeys: ["energy"]))
        XCTAssertEqual(combined.first?.amount, .known(500, energyUnit))
        XCTAssertEqual(combined.first?.isPartial, false)
    }

    func testFailedQueryForOneNutrientLeavesOnlyThatNutrientAtLeast() {
        let combined = HealthIntakeTotals.combine(
            [line("energy", known: 500, unit: energyUnit), line("protein", known: 40, unit: proteinUnit)],
            outside: .read(values: ["energy": 620], readKeys: ["energy"]))
        XCTAssertEqual(combined[0].amount, .known(1120, energyUnit))
        XCTAssertEqual(combined[1].isPartial, true)
        XCTAssertEqual(combined[1].knownSum, .known(40, proteinUnit))
    }

    func testNothingKnownOnEitherSideStaysUnknown() {
        let lines = [unknownLine("energy")]
        XCTAssertEqual(HealthIntakeTotals.combine(lines, outside: .read(values: [:], readKeys: [])), lines)
        // Health was read for protein only, so energy has no Health value and no known zero.
        XCTAssertEqual(HealthIntakeTotals.combine(lines, outside: .read(values: [:], readKeys: ["protein"])), lines)
    }

    func testWaterLineIsNeverCombined() {
        let water = line(DailyTotalsBuilder.waterKey, known: 500, unit: .mL)
        let combined = HealthIntakeTotals.combine([water], outside: .read(values: [DailyTotalsBuilder.waterKey: 250], readKeys: [DailyTotalsBuilder.waterKey]))
        XCTAssertEqual(combined, [water])
    }

    func testReadingsMapToOutsideState() {
        XCTAssertEqual(BodyActivityReadings(outsideNutrients: ["energy": 620]).outsideIntake, .notConnected)
        XCTAssertEqual(
            BodyActivityReadings(
                outsideNutrients: ["energy": 620], outsideRead: true, outsideReadKeys: ["energy"]).outsideIntake,
            .read(values: ["energy": 620], readKeys: ["energy"]))
        XCTAssertEqual(
            BodyActivityReadings(outsideReadFailed: true, outsideRead: true).outsideIntake,
            .read(values: [:], readKeys: []))
    }
}
