import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// The read half of Apple Health nutrition: what other apps' samples add to the day, and which
/// samples are skipped. Every value is synthetic.
final class OutsideIntakeTotalsTests: XCTestCase {
    private let protein = "HKQuantityTypeIdentifierDietaryProtein"
    private let water = "HKQuantityTypeIdentifierDietaryWater"
    private let vitaminD = "HKQuantityTypeIdentifierDietaryVitaminD"

    func testReadTypesAreExactlyTheWrittenTypes() {
        let written = Set(HealthKitWritePlanner.mappings.map(\.quantityTypeIdentifier))
        XCTAssertEqual(Set(OutsideIntakeTotals.readQuantityTypeIdentifiers), written)
        XCTAssertEqual(OutsideIntakeTotals.readQuantityTypeIdentifiers.count, written.count)
    }

    func testEveryMappingRowHasItsOwnIdentifier() {
        let identifiers = HealthKitWritePlanner.mappings.map(\.quantityTypeIdentifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func testSumsOtherAppsSamplesPerNutrient() {
        let totals = OutsideIntakeTotals.totals(from: [
            sample(protein, 12, .g),
            sample(protein, 8, .g),
        ])
        XCTAssertEqual(totals["protein"], 20)
    }

    func testSkipsSamplesThisAppWrote() {
        let totals = OutsideIntakeTotals.totals(from: [
            sample(protein, 12, .g, own: true),
            sample(protein, 5, .g),
        ])
        XCTAssertEqual(totals["protein"], 5)
    }

    func testConvertsIntoTheMappingUnit() {
        // Water is stored in milliliters; a liter from another app is 1000 mL.
        let totals = OutsideIntakeTotals.totals(from: [
            sample(water, 1, .L),
        ])
        XCTAssertEqual(totals["water"], 1000)
    }

    func testVitaminDInIUIsRestatedInMicrograms() {
        // 400 IU of vitamin D is 10 mcg (0.025 mcg per IU), the same restatement the writer applies.
        let totals = OutsideIntakeTotals.totals(from: [
            sample(vitaminD, 400, .iu),
        ])
        XCTAssertEqual(totals["vitaminD"], 10)
    }

    func testUnmappedTypesAndUnconvertibleUnitsAddNothing() {
        let totals = OutsideIntakeTotals.totals(from: [
            sample("HKQuantityTypeIdentifierStepCount", 9_000, .g),
            sample(protein, 4, .mL),
        ])
        XCTAssertTrue(totals.isEmpty)
    }

    private func sample(_ identifier: String, _ value: Decimal, _ unit: MeasureUnit, own: Bool = false) -> OutsideNutrientSample {
        OutsideNutrientSample(quantityTypeIdentifier: identifier, value: value, unit: unit, isWrittenByThisApp: own)
    }
}
