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

    func testEmptyJournalWithCompleteHealthIsExact() {
        let combined = HealthIntakeTotals.combine([unknownLine("energy")], outside: .read(values: ["energy": 620], readKeys: ["energy"]))
        XCTAssertEqual(combined.first?.amount, .known(620, energyUnit))
        XCTAssertEqual(combined.first?.isPartial, false)
    }

    func testUnknownJournalWithEntriesAndHealthIsAtLeast() {
        let line = NutrientProgressLine(nutrient: "energy", amount: .unknown, goal: nil, missingCount: 1)
        let combined = HealthIntakeTotals.combine([line], outside: .read(values: ["energy": 620], readKeys: ["energy"]))
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

    func testPartiallyReadNutrientIsAtLeastEvenWithSomeSamplesSummed() {
        // Protein has samples summed, but its query skipped one, so its key is not in readKeys.
        let combined = HealthIntakeTotals.combine(
            [line("protein", known: 40, unit: proteinUnit)],
            outside: .read(values: ["protein": 10], readKeys: []))
        XCTAssertEqual(combined.first?.isPartial, true)
        XCTAssertEqual(combined.first?.knownSum, .known(50, proteinUnit))
    }

    func testPartialJournalWithNoKnownSumAndHealthKnownShowsHealthOnly() {
        let combined = HealthIntakeTotals.combine(
            [NutrientProgressLine(nutrient: "energy", amount: .unknown, goal: nil, isPartial: true, knownSum: nil)],
            outside: .read(values: ["energy": 620], readKeys: ["energy"]))
        XCTAssertEqual(combined.first?.isPartial, true)
        XCTAssertEqual(combined.first?.knownSum, .known(620, energyUnit))
    }

    func testMultipleReadKeysInOneReadAllCombine() {
        let combined = HealthIntakeTotals.combine(
            [line("energy", known: 500, unit: energyUnit), line("protein", known: 40, unit: proteinUnit)],
            outside: .read(values: ["energy": 620, "protein": 10], readKeys: ["energy", "protein"]))
        XCTAssertEqual(combined[0].amount, .known(1120, energyUnit))
        XCTAssertEqual(combined[1].amount, .known(50, proteinUnit))
    }

    func testReadKeysUseTheSameCanonicalKeysAsTheOutsideTotals() {
        // The reader's keys come from each identifier's mapping, and the totals are keyed the same way.
        for identifier in OutsideIntakeTotals.readQuantityTypeIdentifiers {
            let mapping = HealthKitWritePlanner.mappings.first { $0.quantityTypeIdentifier == identifier }
            XCTAssertNotNil(mapping, identifier)
            let sample = OutsideNutrientSample(
                quantityTypeIdentifier: identifier, value: 1, unit: mapping?.unit ?? .g, isWrittenByThisApp: false)
            let totals = OutsideIntakeTotals.totals(from: [sample])
            XCTAssertEqual(Set(totals.keys), Set([mapping?.nutrientKey].compactMap { $0 }), identifier)
        }
    }

    func testNothingKnownOnEitherSideStaysUnknown() {
        let lines = [unknownLine("energy")]
        XCTAssertEqual(HealthIntakeTotals.combine(lines, outside: .read(values: [:], readKeys: [])), lines)
        // Health was read for protein only, so energy has no Health value and no known zero.
        XCTAssertEqual(HealthIntakeTotals.combine(lines, outside: .read(values: [:], readKeys: ["protein"])), lines)
    }

    func testEmptyJournalAndZeroHealthStaysUnknown() {
        let lines = [unknownLine("energy")]
        XCTAssertEqual(HealthIntakeTotals.combine(lines, outside: .read(values: [:], readKeys: ["energy"])), lines)
        XCTAssertEqual(HealthIntakeTotals.combine(lines, outside: .read(values: [:], readKeys: [])), lines)
    }

    func testIUJournalTotalIsNeverAddedToHealthMicrograms() {
        // Vitamin D logged in IU on the journal and Health in mcg: the IU amount is not converted or added.
        let vitaminD = HealthKitWritePlanner.mapping(for: "vitaminD")!.unit
        let journalIU = NutrientProgressLine(nutrient: "vitaminD", amount: .known(100, .iu), goal: nil)
        let combined = HealthIntakeTotals.combine(
            [journalIU], outside: .read(values: ["vitaminD": 5], readKeys: ["vitaminD"]))
        XCTAssertEqual(combined.first?.isPartial, true)
        XCTAssertEqual(combined.first?.knownSum, .known(5, vitaminD))
    }

    func testUnknownJournalWithEntriesAndHealthZeroStaysUnknown() {
        let line = NutrientProgressLine(nutrient: "energy", amount: .unknown, goal: nil, missingCount: 1)
        XCTAssertEqual(HealthIntakeTotals.combine([line], outside: .read(values: [:], readKeys: ["energy"])), [line])
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
