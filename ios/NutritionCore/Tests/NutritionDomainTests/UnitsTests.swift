import XCTest
@testable import NutritionDomain

final class UnitsTests: XCTestCase {
    func testGramsToMilligrams() throws {
        let converted = try qty("1.5", .g).converted(to: .mg)
        XCTAssertEqual(converted.value, try dec("1500"))
        XCTAssertEqual(converted.unit, MeasureUnit.mg)
        let kilograms = try qty("2", .kg).converted(to: .g)
        XCTAssertEqual(kilograms.value, try dec("2000"))
    }

    func testMilligramsToMicrograms() throws {
        let large = try qty("1500", .mg).converted(to: .mcg)
        XCTAssertEqual(large.value, try dec("1500000"))
        let small = try qty("0.25", .mg).converted(to: .mcg)
        XCTAssertEqual(small.value, try dec("250"))
        XCTAssertEqual(small.unit, MeasureUnit.mcg)
    }

    func testMicrogramsToGramsRoundTripExact() throws {
        let start = try qty("1.5", .g)
        let milligrams = try start.converted(to: .mg)
        let micrograms = try milligrams.converted(to: .mcg)
        XCTAssertEqual(micrograms.value, try dec("1500000"))
        let back = try micrograms.converted(to: .g)
        XCTAssertEqual(back.value, try dec("1.5"))
        XCTAssertEqual(back, start)
        let fromMilligrams = try qty("1500", .mg).converted(to: .g)
        XCTAssertEqual(fromMilligrams.value, try dec("1.5"))
        let oneMicrogram = try qty("1", .mcg).converted(to: .g)
        XCTAssertEqual(oneMicrogram.value, try dec("0.000001"))
    }

    func testLitersToMilliliters() throws {
        let milliliters = try qty("1.25", .L).converted(to: .mL)
        XCTAssertEqual(milliliters.value, try dec("1250"))
        let liters = try qty("500", .mL).converted(to: .L)
        XCTAssertEqual(liters.value, try dec("0.5"))
        XCTAssertEqual(liters.unit, MeasureUnit.L)
    }

    func testUnitDimensionsRegistry() throws {
        XCTAssertEqual(MeasureUnit.g.dimension, UnitDimension.mass)
        XCTAssertEqual(MeasureUnit.mg.dimension, UnitDimension.mass)
        XCTAssertEqual(MeasureUnit.mcg.dimension, UnitDimension.mass)
        XCTAssertEqual(MeasureUnit.kg.dimension, UnitDimension.mass)
        XCTAssertEqual(MeasureUnit.mL.dimension, UnitDimension.volume)
        XCTAssertEqual(MeasureUnit.L.dimension, UnitDimension.volume)
        XCTAssertEqual(MeasureUnit.kcal.dimension, UnitDimension.energy)
        XCTAssertEqual(MeasureUnit.iu.dimension, UnitDimension.internationalUnit)
        for unit in [MeasureUnit.serving, .scoop, .tablet, .capsule] {
            XCTAssertEqual(unit.dimension, UnitDimension.count)
        }
        XCTAssertEqual(try UnitRegistry.unit(for: "mcg"), MeasureUnit.mcg)
        XCTAssertEqual(try UnitRegistry.unit(for: "IU"), MeasureUnit.iu)
        XCTAssertEqual(try MeasureUnit(symbol: "mL"), MeasureUnit.mL)
        XCTAssertEqual(try MeasureUnit(symbol: "oz"), MeasureUnit.oz)
        XCTAssertEqual(try MeasureUnit(symbol: "fl oz"), MeasureUnit.flOz)
        XCTAssertEqual(UnitRegistry.units(in: .mass).count, 5)
        XCTAssertEqual(UnitRegistry.units(in: .volume).count, 3)
        XCTAssertEqual(UnitRegistry.units(in: .energy).count, 1)
        XCTAssertEqual(UnitRegistry.units(in: .count).count, 4)
        XCTAssertEqual(UnitRegistry.units(in: .internationalUnit).count, 1)
        XCTAssertEqual(Set(UnitRegistry.all.map(\.symbol)).count, UnitRegistry.all.count)
    }

    func testAddSameDimensionDifferentUnits() throws {
        let gramsFirst = try qty("1", .g).adding(try qty("500", .mg))
        XCTAssertEqual(gramsFirst.value, try dec("1.5"))
        XCTAssertEqual(gramsFirst.unit, MeasureUnit.g)
        let milligramsFirst = try qty("500", .mg).adding(try qty("1", .g))
        XCTAssertEqual(milligramsFirst.value, try dec("1500"))
        XCTAssertEqual(milligramsFirst.unit, MeasureUnit.mg)
        let volume = try qty("0.5", .L).adding(try qty("250", .mL))
        XCTAssertEqual(volume.value, try dec("0.75"))
        XCTAssertEqual(volume.unit, MeasureUnit.L)
    }

    func testAddAcrossDimensionsThrows() throws {
        let mass = try qty("1", .g)
        XCTAssertThrowsError(try mass.adding(try qty("100", .mL))) { error in
            XCTAssertEqual(error as? UnitError, UnitError.dimensionMismatch(from: .mL, to: .g))
        }
        XCTAssertThrowsError(try mass.adding(try qty("10", .kcal))) { error in
            XCTAssertEqual(error as? UnitError, UnitError.dimensionMismatch(from: .kcal, to: .g))
        }
        XCTAssertThrowsError(try qty("2", .scoop).adding(try qty("1", .tablet))) { error in
            XCTAssertEqual(error as? UnitError, UnitError.incompatibleCountUnits(from: .tablet, to: .scoop))
        }
    }

    func testConvertMassToVolumeWithoutDensityThrows() throws {
        let mass = try qty("100", .g)
        XCTAssertThrowsError(try mass.converted(to: .mL)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.missingDensity(from: .g, to: .mL))
        }
        let volume = try qty("1", .L)
        XCTAssertThrowsError(try volume.converted(to: .kg)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.missingDensity(from: .L, to: .kg))
        }
        XCTAssertThrowsError(try mass.converted(to: .kcal)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.dimensionMismatch(from: .g, to: .kcal))
        }
    }

    func testConvertVolumeToMassWithDensity() throws {
        let density = try dec("1.03")
        let grams = try qty("250", .mL).converted(to: .g, density: density)
        XCTAssertEqual(grams.value, try dec("257.5"))
        let kilograms = try qty("2", .L).converted(to: .kg, density: try dec("0.8"))
        XCTAssertEqual(kilograms.value, try dec("1.6"))
        let milliliters = try qty("80", .g).converted(to: .mL, density: try dec("0.8"))
        XCTAssertEqual(milliliters.value, try dec("100"))
        XCTAssertThrowsError(try qty("1", .mL).converted(to: .g, density: try dec("0"))) { error in
            XCTAssertEqual(error as? UnitError, UnitError.invalidDensity(0))
        }
    }

    func testInternationalUnitsNeverConvertToMass() throws {
        let vitaminD = try qty("400", .iu)
        XCTAssertThrowsError(try vitaminD.converted(to: .mcg)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.internationalUnitNotConvertible(from: .iu, to: .mcg))
        }
        XCTAssertThrowsError(try qty("10", .mg).converted(to: .iu)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.internationalUnitNotConvertible(from: .mg, to: .iu))
        }
        let portion = try PortionDefinition(countUnit: .capsule, quantity: try qty("500", .mg))
        XCTAssertThrowsError(try vitaminD.converted(to: .g, density: try dec("1"), portion: portion)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.internationalUnitNotConvertible(from: .iu, to: .g))
        }
        let same = try vitaminD.converted(to: .iu)
        XCTAssertEqual(same.value, try dec("400"))
    }

    func testCountUnitsNeedPortionDefinition() throws {
        let scoops = try qty("2", .scoop)
        XCTAssertThrowsError(try scoops.converted(to: .g)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.missingPortionDefinition(from: .scoop, to: .g))
        }
        let capsulePortion = try PortionDefinition(countUnit: .capsule, quantity: try qty("500", .mg))
        XCTAssertThrowsError(try scoops.converted(to: .g, portion: capsulePortion)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.missingPortionDefinition(from: .scoop, to: .g))
        }
        XCTAssertThrowsError(try qty("10", .g).converted(to: .scoop)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.missingPortionDefinition(from: .g, to: .scoop))
        }
        XCTAssertThrowsError(try scoops.converted(to: .tablet, portion: capsulePortion)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.incompatibleCountUnits(from: .scoop, to: .tablet))
        }
        XCTAssertThrowsError(try PortionDefinition(countUnit: .g, quantity: try qty("5", .g))) { error in
            XCTAssertEqual(error as? UnitError, UnitError.invalidPortionDefinition(countUnit: .g, quantity: Quantity(value: 5, unit: .g)))
        }
        XCTAssertThrowsError(try PortionDefinition(countUnit: .scoop, quantity: try qty("0", .g)))
    }

    func testCountToMassWithPortionDefinition() throws {
        let scoopPortion = try PortionDefinition(countUnit: .scoop, quantity: try qty("5", .g))
        let grams = try qty("3", .scoop).converted(to: .g, portion: scoopPortion)
        XCTAssertEqual(grams.value, try dec("15"))
        let milligrams = try qty("3", .scoop).converted(to: .mg, portion: scoopPortion)
        XCTAssertEqual(milligrams.value, try dec("15000"))
        let capsulePortion = try PortionDefinition(countUnit: .capsule, quantity: try qty("500", .mg))
        let oneGram = try qty("2", .capsule).converted(to: .g, portion: capsulePortion)
        XCTAssertEqual(oneGram.value, try dec("1"))
        let scoops = try qty("10", .g).converted(to: .scoop, portion: scoopPortion)
        XCTAssertEqual(scoops.value, try dec("2"))
        let capsules = try qty("1", .g).converted(to: .capsule, portion: capsulePortion)
        XCTAssertEqual(capsules.value, try dec("2"))
    }

    /// One avoirdupois ounce is exactly 28.349523125 g. Multiplying by that factor is exact, so a
    /// weight in ounces lands on the gram exactly.
    func testOuncesConvertExactlyBothWays() throws {
        XCTAssertEqual(MeasureUnit.oz.dimension, UnitDimension.mass)
        XCTAssertEqual(try MeasureUnit(symbol: "oz"), MeasureUnit.oz)

        let grams = try qty("8", .oz).converted(to: .g)
        XCTAssertEqual(grams.value, try dec("226.796185"))
        XCTAssertEqual(grams.unit, MeasureUnit.g)
        XCTAssertEqual(try qty("1", .oz).converted(to: .mg).value, try dec("28349.523125"))
        XCTAssertEqual(try qty("1", .kg).converted(to: .g).value, try dec("1000"))

        // Grams to ounces divides by the same factor. The reciprocal is carried at the full precision
        // a Decimal holds, so the quotient is exact to beyond anything displayed and a round trip
        // returns the number that was converted.
        let ounces = try qty("226.796185", .g).converted(to: .oz)
        XCTAssertEqual(ounces.unit, MeasureUnit.oz)
        XCTAssertEqual(DisplayRounding.rounded(ounces.value, fractionDigits: 10), try dec("8"))
    }

    /// A round trip through grams or ounces returns the amount that went in, for sizes a person
    /// actually enters. This is the guarantee the display conversion rests on: a value converted for
    /// showing and converted back does not drift.
    func testOuncesRoundTripExactlyBothWays() throws {
        for text in ["0.25", "1", "16", "1000"] {
            let grams = try qty(text, .g)
            XCTAssertEqual(try grams.converted(to: .oz).converted(to: .g).value, try dec(text), text)
        }
        for text in ["0.5", "1", "2", "16", "40", "250", "300"] {
            let ounces = try qty(text, .oz)
            XCTAssertEqual(try ounces.converted(to: .g).converted(to: .oz).value, try dec(text), text)
        }
    }

    /// One US fluid ounce is exactly 29.5735295625 mL. `fl oz` is a separate symbol from `oz`, so a
    /// measure is never read as a weight.
    func testFluidOuncesConvertExactlyBothWays() throws {
        XCTAssertEqual(MeasureUnit.flOz.dimension, UnitDimension.volume)
        XCTAssertEqual(try MeasureUnit(symbol: "fl oz"), MeasureUnit.flOz)
        XCTAssertNotEqual(MeasureUnit.flOz.symbol, MeasureUnit.oz.symbol)

        let milliliters = try qty("8", .flOz).converted(to: .mL)
        XCTAssertEqual(milliliters.value, try dec("236.5882365"))
        XCTAssertEqual(milliliters.unit, MeasureUnit.mL)

        let fluidOunces = try qty("236.5882365", .mL).converted(to: .flOz)
        XCTAssertEqual(fluidOunces.unit, MeasureUnit.flOz)
        XCTAssertEqual(DisplayRounding.rounded(fluidOunces.value, fractionDigits: 10), try dec("8"))

        for text in ["0.25", "1", "16", "1000"] {
            let millilitersOf = try qty(text, .mL)
            XCTAssertEqual(try millilitersOf.converted(to: .flOz).converted(to: .mL).value, try dec(text), text)
        }
        for text in ["0.5", "1", "2", "16", "250", "300"] {
            let ouncesOf = try qty(text, .flOz)
            XCTAssertEqual(try ouncesOf.converted(to: .mL).converted(to: .flOz).value, try dec(text), text)
        }
    }

    /// The two new units do not widen the registry's shape: mass and volume gain one each, and an
    /// ounce still never converts to a volume without a density.
    func testOuncesKeepTheRegistryShapeAndStillNeedADensityAcrossDimensions() throws {
        XCTAssertEqual(UnitRegistry.units(in: .mass).count, 5)
        XCTAssertEqual(UnitRegistry.units(in: .volume).count, 3)
        XCTAssertTrue(UnitRegistry.units(in: .mass).contains(.oz))
        XCTAssertTrue(UnitRegistry.units(in: .volume).contains(.flOz))
        XCTAssertEqual(Set(UnitRegistry.all.map(\.symbol)).count, UnitRegistry.all.count)
        XCTAssertThrowsError(try qty("1", .oz).converted(to: .mL)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.missingDensity(from: .oz, to: .mL))
        }
        XCTAssertThrowsError(try qty("100", .mL).converted(to: .oz)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.missingDensity(from: .mL, to: .oz))
        }
        // A fluid ounce is a volume, so it converts across to mass with a density like any other.
        let grams = try qty("1", .flOz).converted(to: .g, density: try dec("1"))
        XCTAssertEqual(grams.value, try dec("29.5735295625"))
    }

    func testUnknownUnitSymbolRejected() throws {
        XCTAssertThrowsError(try MeasureUnit(symbol: "furlong")) { error in
            XCTAssertEqual(error as? UnitError, UnitError.unknownSymbol("furlong"))
        }
        XCTAssertThrowsError(try UnitRegistry.unit(for: "")) { error in
            XCTAssertEqual(error as? UnitError, UnitError.unknownSymbol(""))
        }
        XCTAssertThrowsError(try UnitRegistry.unit(for: "kJ")) { error in
            XCTAssertEqual(error as? UnitError, UnitError.unknownSymbol("kJ"))
        }
        XCTAssertEqual(try MeasureUnit(symbol: "kcal"), MeasureUnit.kcal)
        // Ounces are in the registry now, so the near misses are what a person would still be refused.
        XCTAssertThrowsError(try MeasureUnit(symbol: "lb")) { error in
            XCTAssertEqual(error as? UnitError, UnitError.unknownSymbol("lb"))
        }
        XCTAssertThrowsError(try MeasureUnit(symbol: "oz ")) { error in
            XCTAssertEqual(error as? UnitError, UnitError.unknownSymbol("oz "))
        }
    }
}
