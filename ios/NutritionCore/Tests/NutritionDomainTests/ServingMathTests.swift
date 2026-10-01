import XCTest
@testable import NutritionDomain

final class ServingMathTests: XCTestCase {
    private func calculation(
        basis: String, _ basisUnit: MeasureUnit,
        consumed: String, _ consumedUnit: MeasureUnit,
        density: Decimal? = nil,
        portion: PortionDefinition? = nil
    ) throws -> ServingCalculation {
        ServingCalculation(
            basis: try LabelBasis(value: try dec(basis), unit: basisUnit),
            consumed: try ConsumedAmount(value: try dec(consumed), unit: consumedUnit),
            density: density,
            portion: portion
        )
    }

    func testLabelBasisKeptWithConsumedAmount() throws {
        let label = try known("240", .kcal)
        let serving = try calculation(basis: "60", .g, consumed: "45", .g)
        let scaled = try serving.scale(label)
        XCTAssertEqual(scaled, try known("180", .kcal))
        XCTAssertEqual(label, try known("240", .kcal))
        XCTAssertEqual(serving.basis.reference, try qty("60", .g))
        XCTAssertEqual(serving.consumed.quantity, try qty("45", .g))
        XCTAssertEqual(try serving.factor(), try dec("0.75"))
        let again = try serving.scale(label)
        XCTAssertEqual(again, scaled)
    }

    func testPer100gLabel() throws {
        let label = try known("36.4", .g)
        let half = try calculation(basis: "100", .g, consumed: "50", .g)
        XCTAssertEqual(try half.scale(label), try known("18.2", .g))
        let whole = try calculation(basis: "100", .g, consumed: "100", .g)
        XCTAssertEqual(try whole.scale(label), try known("36.4", .g))
        let large = try calculation(basis: "100", .g, consumed: "250", .g)
        XCTAssertEqual(try large.scale(label), try known("91", .g))
        XCTAssertEqual(try half.factor(), try dec("0.5"))
    }

    func testFractionalServing() throws {
        let energy = try calculation(basis: "1", .serving, consumed: "0.75", .serving)
        XCTAssertEqual(try energy.factor(), try dec("0.75"))
        XCTAssertEqual(try energy.scale(try known("120", .kcal)), try known("90", .kcal))
        let sodium = try calculation(basis: "1", .serving, consumed: "0.5", .serving)
        XCTAssertEqual(try sodium.scale(try known("515", .mg)), try known("257.5", .mg))
        let double = try calculation(basis: "1", .serving, consumed: "2", .serving)
        XCTAssertEqual(try double.scale(try known("515", .mg)), try known("1030", .mg))
    }

    func testCountPortionServing() throws {
        let scoopPortion = try PortionDefinition(countUnit: .scoop, quantity: try qty("5", .g))
        let byWeight = try calculation(basis: "1", .scoop, consumed: "10", .g, portion: scoopPortion)
        XCTAssertEqual(try byWeight.consumedInBasisUnit(), try qty("2", .scoop))
        XCTAssertEqual(try byWeight.scale(try known("100", .kcal)), try known("200", .kcal))
        let byScoop = try calculation(basis: "5", .g, consumed: "1.5", .scoop, portion: scoopPortion)
        XCTAssertEqual(try byScoop.consumedInBasisUnit(), try qty("7.5", .g))
        XCTAssertEqual(try byScoop.scale(try known("20", .kcal)), try known("30", .kcal))
        let withoutPortion = try calculation(basis: "5", .g, consumed: "1.5", .scoop)
        XCTAssertThrowsError(try withoutPortion.scale(try known("20", .kcal))) { error in
            XCTAssertEqual(error as? UnitError, UnitError.missingPortionDefinition(from: .scoop, to: .g))
        }
    }

    func testConsumedUnitConvertedToBasisUnit() throws {
        let serving = try calculation(basis: "100", .g, consumed: "0.05", .kg)
        XCTAssertEqual(try serving.consumedInBasisUnit(), try qty("50", .g))
        XCTAssertEqual(try serving.scale(try known("36.4", .g)), try known("18.2", .g))
        let milligrams = try calculation(basis: "1", .g, consumed: "250", .mg)
        XCTAssertEqual(try milligrams.factor(), try dec("0.25"))
        let liters = try calculation(basis: "250", .mL, consumed: "0.5", .L)
        XCTAssertEqual(try liters.factor(), try dec("2"))
        XCTAssertEqual(try liters.scale(try known("110", .kcal)), try known("220", .kcal))
    }

    func testConsumedDimensionMismatchThrows() throws {
        let energyConsumed = try calculation(basis: "60", .g, consumed: "1", .kcal)
        XCTAssertThrowsError(try energyConsumed.scale(try known("240", .kcal))) { error in
            XCTAssertEqual(error as? UnitError, UnitError.dimensionMismatch(from: .kcal, to: .g))
        }
        let volumeConsumed = try calculation(basis: "60", .g, consumed: "100", .mL)
        XCTAssertThrowsError(try volumeConsumed.factor()) { error in
            XCTAssertEqual(error as? UnitError, UnitError.missingDensity(from: .mL, to: .g))
        }
        XCTAssertThrowsError(try ConsumedAmount(value: try dec("-1"), unit: .g)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.negativeAmount(-1))
        }
        XCTAssertThrowsError(try LabelBasis(value: try dec("0"), unit: .g)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.nonPositiveAmount(0))
        }
        let withDensity = try calculation(basis: "100", .g, consumed: "100", .mL, density: try dec("0.5"))
        XCTAssertEqual(try withDensity.factor(), try dec("0.5"))
    }
}
