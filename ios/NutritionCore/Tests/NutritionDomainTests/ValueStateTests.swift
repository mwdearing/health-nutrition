import XCTest
@testable import NutritionDomain

final class ValueStateTests: XCTestCase {
    func testNutrientAmountConvertsMgToMicrograms() throws {
        let converted = try known("515", .mg).converted(to: .mcg)
        XCTAssertEqual(converted, try known("515000", .mcg))
        let half = try known("0.5", .mg).converted(to: .mcg)
        XCTAssertEqual(half, try known("500", .mcg))
        let back = try converted.converted(to: .mg)
        XCTAssertEqual(back, try known("515", .mg))
        XCTAssertThrowsError(try known("515", .mg).converted(to: .kcal)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.dimensionMismatch(from: .mg, to: .kcal))
        }
    }

    func testDecimalStorageNoBinaryDrift() throws {
        let step = try dec("0.1")
        var sum = Decimal(0)
        for _ in 0..<10 {
            sum += step
        }
        XCTAssertEqual(sum, try dec("1"))
        XCTAssertNotEqual(sum, try dec("0.9999"))
        XCTAssertEqual(step * 3, try dec("0.3"))
        let values = Array(repeating: try known("0.1", .g), count: 10)
        let total = try NutrientTotal.sum(values)
        XCTAssertEqual(total.value, try known("1", .g))
    }

    func testRoundingOnlyAtDisplay() throws {
        let stored = try known("2.345", .g)
        let scaled = stored.scaled(by: 3)
        XCTAssertEqual(scaled, try known("7.035", .g))
        let converted = try scaled.converted(to: .mg)
        XCTAssertEqual(converted, try known("7035", .mg))
        XCTAssertEqual(scaled.rounded(fractionDigits: 2), try known("7.04", .g))
        XCTAssertEqual(scaled, try known("7.035", .g))
        let serving = ServingCalculation(
            basis: try LabelBasis(value: 3, unit: .g),
            consumed: try ConsumedAmount(value: 1, unit: .g)
        )
        let third = try serving.scale(try known("1", .g))
        XCTAssertNotEqual(third, try known("0.33", .g))
    }

    func testDisplayRoundingIsPlainAndDoesNotMutate() throws {
        XCTAssertEqual(DisplayRounding.rounded(try dec("2.5"), fractionDigits: 0), try dec("3"))
        XCTAssertEqual(DisplayRounding.rounded(try dec("2.4"), fractionDigits: 0), try dec("2"))
        XCTAssertEqual(DisplayRounding.rounded(try dec("1.005"), fractionDigits: 2), try dec("1.01"))
        XCTAssertEqual(DisplayRounding.rounded(try dec("1.004"), fractionDigits: 2), try dec("1"))
        XCTAssertEqual(DisplayRounding.rounded(try dec("0"), fractionDigits: 2), try dec("0"))
        let original = try qty("1.2345", .g)
        let display = original.rounded(fractionDigits: 1)
        XCTAssertEqual(display, try qty("1.2", .g))
        XCTAssertEqual(original, try qty("1.2345", .g))
        XCTAssertEqual(NutrientValue.unknown.rounded(fractionDigits: 1), NutrientValue.unknown)
    }

    func testKnownZeroStaysKnownZero() throws {
        let zero = try known("0", .mg)
        XCTAssertEqual(zero.scaled(by: try dec("2.5")), try known("0", .mg))
        XCTAssertNotEqual(zero, NutrientValue.unknown)
        XCTAssertEqual(try zero.converted(to: .mcg), try known("0", .mcg))
        XCTAssertEqual(zero.quantity, try qty("0", .mg))
        let serving = ServingCalculation(
            basis: try LabelBasis(value: 100, unit: .g),
            consumed: try ConsumedAmount(value: 40, unit: .g)
        )
        XCTAssertEqual(try serving.scale(zero), try known("0", .mg))
    }

    func testUnknownScaledStaysUnknown() throws {
        let unknown = NutrientValue.unknown
        XCTAssertEqual(unknown.scaled(by: 2), NutrientValue.unknown)
        XCTAssertNotEqual(unknown.scaled(by: 2), try known("0", .mg))
        XCTAssertEqual(try unknown.converted(to: .mcg), NutrientValue.unknown)
        XCTAssertNil(unknown.quantity)
        let serving = ServingCalculation(
            basis: try LabelBasis(value: 100, unit: .g),
            consumed: try ConsumedAmount(value: 40, unit: .g)
        )
        XCTAssertEqual(try serving.scale(unknown), NutrientValue.unknown)
    }

    func testNotApplicableScaledStaysNotApplicable() throws {
        let notApplicable = NutrientValue.notApplicable
        XCTAssertEqual(notApplicable.scaled(by: 3), NutrientValue.notApplicable)
        XCTAssertEqual(try notApplicable.converted(to: .g), NutrientValue.notApplicable)
        XCTAssertNotEqual(notApplicable, NutrientValue.unknown)
        let serving = ServingCalculation(
            basis: try LabelBasis(value: 1, unit: .serving),
            consumed: try ConsumedAmount(value: 2, unit: .serving)
        )
        XCTAssertEqual(try serving.scale(notApplicable), NutrientValue.notApplicable)
    }

    func testBelowReportingThresholdScaledStaysBelowThreshold() throws {
        let trace = NutrientValue.belowReportingThreshold(.mg)
        XCTAssertEqual(trace.scaled(by: 4), NutrientValue.belowReportingThreshold(.mg))
        XCTAssertEqual(try trace.converted(to: .mcg), NutrientValue.belowReportingThreshold(.mcg))
        XCTAssertNotEqual(trace, NutrientValue.unknown)
        let noUnit = NutrientValue.belowReportingThreshold(nil)
        XCTAssertEqual(try noUnit.converted(to: .mcg), NutrientValue.belowReportingThreshold(nil))
        XCTAssertThrowsError(try trace.converted(to: .kcal)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.dimensionMismatch(from: .mg, to: .kcal))
        }
        let serving = ServingCalculation(
            basis: try LabelBasis(value: 100, unit: .g),
            consumed: try ConsumedAmount(value: 40, unit: .g)
        )
        XCTAssertEqual(try serving.scale(trace), trace)
    }

    func testTotalSkipsUnknownAndReportsCoverage() throws {
        let total = try NutrientTotal.sum([try known("10", .mg), .unknown, try known("5", .mg)])
        XCTAssertEqual(total.value, try known("15", .mg))
        XCTAssertEqual(total.coverage.knownCount, 2)
        XCTAssertEqual(total.coverage.totalCount, 3)
        XCTAssertTrue(total.coverage.hasUnknown)
        XCTAssertFalse(total.coverage.hasBelowReportingThreshold)
        XCTAssertFalse(total.coverage.isComplete)
        let withNotApplicable = try NutrientTotal.sum([try known("10", .mg), .notApplicable])
        XCTAssertEqual(withNotApplicable.coverage.totalCount, 1)
        XCTAssertTrue(withNotApplicable.coverage.isComplete)
    }

    func testTotalOfAllUnknownIsUnknownNotZero() throws {
        let total = try NutrientTotal.sum([.unknown, .unknown])
        XCTAssertEqual(total.value, NutrientValue.unknown)
        XCTAssertNotEqual(total.value, try known("0", .mg))
        XCTAssertEqual(total.coverage.knownCount, 0)
        XCTAssertEqual(total.coverage.totalCount, 2)
        XCTAssertTrue(total.coverage.hasUnknown)
        let empty = try NutrientTotal.sum([])
        XCTAssertEqual(empty.value, NutrientValue.unknown)
        XCTAssertEqual(empty.coverage.totalCount, 0)
    }

    func testTotalWithBelowThresholdIsFlagged() throws {
        let total = try NutrientTotal.sum([try known("10", .mg), .belowReportingThreshold(.mg)])
        XCTAssertEqual(total.value, try known("10", .mg))
        XCTAssertTrue(total.coverage.hasBelowReportingThreshold)
        XCTAssertFalse(total.coverage.hasUnknown)
        XCTAssertEqual(total.coverage.knownCount, 1)
        XCTAssertEqual(total.coverage.totalCount, 2)
        let onlyTrace = try NutrientTotal.sum([.belowReportingThreshold(.mg), .belowReportingThreshold(nil)])
        XCTAssertEqual(onlyTrace.value, NutrientValue.belowReportingThreshold(nil))
        XCTAssertTrue(onlyTrace.coverage.hasBelowReportingThreshold)
    }

    func testTotalWithKnownZeroAndUnknownIsNotComplete() throws {
        let partial = try NutrientTotal.sum([try known("0", .mg), .unknown])
        XCTAssertEqual(partial.value, try known("0", .mg))
        XCTAssertEqual(partial.coverage.knownCount, 1)
        XCTAssertEqual(partial.coverage.totalCount, 2)
        XCTAssertFalse(partial.coverage.isComplete)
        XCTAssertTrue(partial.coverage.hasUnknown)
        let complete = try NutrientTotal.sum([try known("0", .mg), try known("2", .mg)])
        XCTAssertTrue(complete.coverage.isComplete)
        XCTAssertEqual(complete.value, try known("2", .mg))
    }

    func testTotalMixedUnitsSameDimension() throws {
        let values = [try known("1", .g), try known("500", .mg), try known("250000", .mcg)]
        let inFirstUnit = try NutrientTotal.sum(values)
        XCTAssertEqual(inFirstUnit.value, try known("1.75", .g))
        let inMilligrams = try NutrientTotal.sum(values, in: .mg)
        XCTAssertEqual(inMilligrams.value, try known("1750", .mg))
        XCTAssertTrue(inMilligrams.coverage.isComplete)
        XCTAssertEqual(inMilligrams.coverage.knownCount, 3)
    }

    /// A lone value in international units cannot be totalled for a nutrient read in grams: the value
    /// is checked against the nutrient's own unit even when nothing else is there to mismatch it.
    func testALoneValueInAnotherDimensionThanTheNutrientThrows() throws {
        XCTAssertThrowsError(try NutrientTotal.sum([try known("1000", .iu)], expecting: .g)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.dimensionMismatch(from: .iu, to: .g))
        }
    }

    /// The nutrient's unit only checks the dimension; the total is still stated in the first value's
    /// unit, so a compatible mix keeps the figure it had before the check was added.
    func testCompatibleValuesCheckedAgainstTheNutrientUnitKeepTheirOwnUnit() throws {
        let total = try NutrientTotal.sum(
            [try known("500", .mg), try known("1", .g)], expecting: .g)
        XCTAssertEqual(total.value, try known("1500", .mg))
        XCTAssertTrue(total.coverage.isComplete)
        XCTAssertEqual(try NutrientTotal.sum([try known("500", .mg)], expecting: .g).value, try known("500", .mg))
    }

    func testTotalAcrossDimensionsThrows() throws {
        XCTAssertThrowsError(try NutrientTotal.sum([try known("1", .g), try known("10", .kcal)])) { error in
            XCTAssertEqual(error as? UnitError, UnitError.dimensionMismatch(from: .kcal, to: .g))
        }
        XCTAssertThrowsError(try NutrientTotal.sum([try known("1", .g), try known("10", .mL)])) { error in
            XCTAssertEqual(error as? UnitError, UnitError.dimensionMismatch(from: .mL, to: .g))
        }
        XCTAssertThrowsError(try NutrientTotal.sum([try known("1", .g)], in: .kcal)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.dimensionMismatch(from: .g, to: .kcal))
        }
    }
}
