import HealthKit
import NutritionDomain
import NutritionJournal
import XCTest

@testable import HealthNutrition

/// How a HealthKit sample is read: in the nutrient's unit when HealthKit says it is compatible, IU only for a nutrient with
/// a fixed IU amount, and not at all otherwise. Quantities are built directly, so no HealthKit store is needed.
@MainActor
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

    /// One representative nutrient for each pinned unit (g, mg, mcg, mL, kcal), sampled in that same unit: each is
    /// read back as the value it was stored with, in the mapping's unit.
    func testEachPinnedUnitIsReadBackInTheMappingsUnit() throws {
        let cases: [(String, HKQuantity, Double, MeasureUnit)] = [
            ("protein", HKQuantity(unit: .gram(), doubleValue: 5), 5, .g),
            ("sodium", HKQuantity(unit: .gramUnit(with: .milli), doubleValue: 2300), 2300, .mg),
            ("folate", HKQuantity(unit: .gramUnit(with: .micro), doubleValue: 400), 400, .mcg),
            ("water", HKQuantity(unit: .literUnit(with: .milli), doubleValue: 250), 250, .mL),
            ("energy", HKQuantity(unit: .kilocalorie(), doubleValue: 350), 350, .kcal),
        ]
        for (key, quantity, expected, unit) in cases {
            let mappingUnit = try XCTUnwrap(HealthKitWritePlanner.mapping(for: key)).unit
            let read = try XCTUnwrap(readBack(quantity, key: key), key)
            XCTAssertEqual(read.0, expected, accuracy: 0.0001, key)
            XCTAssertEqual(read.1, unit, key)
            XCTAssertEqual(read.1, mappingUnit, key)
        }
    }

    /// A milligram sample is converted into a gram nutrient: 5000 mg is read as 5 g.
    func testAMilligramSampleIsReadInAGramNutrient() throws {
        let read = try XCTUnwrap(readBack(HKQuantity(unit: .gramUnit(with: .milli), doubleValue: 5000), key: "protein"))
        XCTAssertEqual(read.0, 5, accuracy: 0.0001)
        XCTAssertEqual(read.1, .g)
    }

    /// A litre sample is converted into a millilitre nutrient: 0.5 L of water is read as 500 mL.
    func testALiterSampleIsReadInMilliliters() throws {
        let read = try XCTUnwrap(readBack(HKQuantity(unit: .liter(), doubleValue: 0.5), key: "water"))
        XCTAssertEqual(read.0, 500, accuracy: 0.0001)
        XCTAssertEqual(read.1, .mL)
    }

    /// Vitamin A has no fixed IU amount (its IU depends on the form), so the planner gives it no factor and an IU
    /// sample is unconvertible for it: the reader returns nil rather than an IU value.
    func testAnIUSampleIsUnconvertibleForAVitaminWithoutAFixedFactor() throws {
        let vitaminA = try XCTUnwrap(HealthKitWritePlanner.mapping(for: "vitaminA"))
        XCTAssertNil(vitaminA.amountPerInternationalUnit)
        let hkUnit = try XCTUnwrap(HealthKitReader.healthKitUnit(for: vitaminA.unit))
        XCTAssertNil(HealthKitReader.sampleValue(
            HKQuantity(unit: .internationalUnit(), doubleValue: 5000), hkUnit: hkUnit, unit: vitaminA.unit, hasIUFactor: false))
    }

    /// A volume sample cannot be read into a mass nutrient.
    func testAVolumeSampleInAMassNutrientIsUnconvertible() {
        XCTAssertNil(readBack(HKQuantity(unit: .literUnit(with: .milli), doubleValue: 250), key: "protein"))
    }

    /// A mass sample cannot be read into a volume nutrient.
    func testAMassSampleInAVolumeNutrientIsUnconvertible() {
        XCTAssertNil(readBack(HKQuantity(unit: .gram(), doubleValue: 250), key: "water"))
    }

    /// Energy stored in kilojoules is read in kcal: 1000 kJ is about 239.006 kcal (1 kcal is 4184 J), and the
    /// `energyKcal` alias reads the same way as the canonical `energy` key.
    func testEnergyInKilojoulesIsReadInKilocalories() throws {
        let kilojoules = HKQuantity(unit: .jouleUnit(with: .kilo), doubleValue: 1000)
        let read = try XCTUnwrap(readBack(kilojoules, key: "energy"))
        XCTAssertEqual(read.0, 239.0057, accuracy: 0.001)
        XCTAssertEqual(read.1, .kcal)
        let aliased = try XCTUnwrap(readBack(kilojoules, key: "energyKcal"))
        XCTAssertEqual(aliased.0, read.0, accuracy: 0.0001)
        XCTAssertEqual(aliased.1, .kcal)
    }

    /// Reads one quantity the way the reader does for `key`: in the mapping's HealthKit unit, through `sampleValue`.
    private func readBack(_ quantity: HKQuantity, key: String, hasIUFactor: Bool = false) -> (Double, MeasureUnit)? {
        guard let mapping = HealthKitWritePlanner.mapping(for: key),
              let hkUnit = HealthKitReader.healthKitUnit(for: mapping.unit)
        else { return nil }
        return HealthKitReader.sampleValue(quantity, hkUnit: hkUnit, unit: mapping.unit, hasIUFactor: hasIUFactor)
    }
}
