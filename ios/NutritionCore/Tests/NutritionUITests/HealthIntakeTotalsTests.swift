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
            [line("energy", known: 500, unit: energyUnit)], outside: .read(["energy": 620]))
        XCTAssertEqual(combined.first?.amount, .known(1120, energyUnit))
        XCTAssertEqual(combined.first?.isPartial, false)
    }

    func testMissingHealthKeyMakesTheTotalAtLeastNotZero() {
        let combined = HealthIntakeTotals.combine(
            [line("protein", known: 40, unit: proteinUnit)], outside: .read(["energy": 620]))
        XCTAssertEqual(combined.first?.amount, .unknown)
        XCTAssertEqual(combined.first?.isPartial, true)
        XCTAssertEqual(combined.first?.knownSum, .known(40, proteinUnit))
    }

    func testFailedReadKeepsTheJournalTotalAsAtLeast() {
        let combined = HealthIntakeTotals.combine(
            [line("energy", known: 500, unit: energyUnit)], outside: .failed)
        XCTAssertEqual(combined.first?.isPartial, true)
        XCTAssertEqual(combined.first?.knownSum, .known(500, energyUnit))
    }

    func testPartialJournalPlusHealthStaysPartialWithTheSum() {
        let combined = HealthIntakeTotals.combine(
            [partialLine("energy", knownSum: 300, unit: energyUnit)], outside: .read(["energy": 620]))
        XCTAssertEqual(combined.first?.isPartial, true)
        XCTAssertEqual(combined.first?.knownSum, .known(920, energyUnit))
        XCTAssertEqual(combined.first?.missingCount, 1)
    }

    func testHealthOnlyDayIsAtLeastTheHealthValue() {
        let combined = HealthIntakeTotals.combine([unknownLine("energy")], outside: .read(["energy": 620]))
        XCTAssertEqual(combined.first?.isPartial, true)
        XCTAssertEqual(combined.first?.knownSum, .known(620, energyUnit))
    }

    func testExplicitZeroFromHealthIsAKnownValue() {
        let combined = HealthIntakeTotals.combine(
            [line("energy", known: 500, unit: energyUnit)], outside: .read(["energy": 0]))
        XCTAssertEqual(combined.first?.amount, .known(500, energyUnit))
        XCTAssertEqual(combined.first?.isPartial, false)
    }

    func testNothingKnownOnEitherSideStaysUnknown() {
        let lines = [unknownLine("energy")]
        XCTAssertEqual(HealthIntakeTotals.combine(lines, outside: .failed), lines)
        XCTAssertEqual(HealthIntakeTotals.combine(lines, outside: .read([:])), lines)
    }

    func testWaterLineIsNeverCombined() {
        let water = line(DailyTotalsBuilder.waterKey, known: 500, unit: .mL)
        let combined = HealthIntakeTotals.combine([water], outside: .read([DailyTotalsBuilder.waterKey: 250]))
        XCTAssertEqual(combined, [water])
    }

    func testReadingsMapToOutsideState() {
        XCTAssertEqual(BodyActivityReadings(outsideNutrients: ["energy": 620]).outsideIntake, .notConnected)
        XCTAssertEqual(
            BodyActivityReadings(outsideNutrients: ["energy": 620], outsideRead: true).outsideIntake,
            .read(["energy": 620]))
        XCTAssertEqual(BodyActivityReadings(outsideReadFailed: true, outsideRead: true).outsideIntake, .failed)
    }
}
