import HealthKit
import NutritionDomain
import NutritionJournal
import XCTest

@testable import HealthNutrition

/// How a HealthKit sample is read: in the nutrient's unit when HealthKit says it is compatible, IU only for a nutrient with
/// a fixed IU amount, and not at all otherwise. Quantities are built directly, so no HealthKit store is needed.
final class HealthKitSampleUnitTests: XCTestCase {
    func testAGramSampleIsReadInTheNutrientsUnit() throws {
        let protein = try XCTUnwrap(HealthKitWritePlanner.mapping(for: "protein"))
        let hkUnit = try XCTUnwrap(HealthKitReader.healthKitUnit(for: protein.unit))
        let read = try XCTUnwrap(HealthKitReader.sampleValue(
            HKQuantity(unit: .gram(), doubleValue: 5), hkUnit: hkUnit, unit: protein.unit, hasIUFactor: false))
        XCTAssertEqual(read.0, 5, accuracy: 0.0001)
        XCTAssertEqual(read.1, protein.unit)
    }

    func testAnIUSampleIsReadAsIUOnlyForAVitaminWithAFixedFactor() throws {
        let vitaminD = try XCTUnwrap(HealthKitWritePlanner.mapping(for: "vitaminD"))
        let hkUnit = try XCTUnwrap(HealthKitReader.healthKitUnit(for: vitaminD.unit))
        let iu = HKQuantity(unit: .internationalUnit(), doubleValue: 400)
        let read = try XCTUnwrap(HealthKitReader.sampleValue(iu, hkUnit: hkUnit, unit: vitaminD.unit, hasIUFactor: true))
        XCTAssertEqual(read.0, 400, accuracy: 0.0001)
        XCTAssertEqual(read.1, .iu)
        XCTAssertNil(HealthKitReader.sampleValue(iu, hkUnit: hkUnit, unit: vitaminD.unit, hasIUFactor: false))
    }

    func testAMassInAnEnergyNutrientIsUnconvertible() throws {
        let energy = try XCTUnwrap(HealthKitWritePlanner.mapping(for: "energy"))
        let hkUnit = try XCTUnwrap(HealthKitReader.healthKitUnit(for: energy.unit))
        XCTAssertNil(HealthKitReader.sampleValue(
            HKQuantity(unit: .gram(), doubleValue: 5), hkUnit: hkUnit, unit: energy.unit, hasIUFactor: false))
    }

    func testAUnitWithNoHealthKitUnitIsNil() {
        XCTAssertNil(HealthKitReader.healthKitUnit(for: .iu))
    }
}
