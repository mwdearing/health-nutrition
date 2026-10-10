import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// The factor for the basis shapes a recipe writes with a total yield. A recipe's snapshot states its values
/// per one unit of the yield's own unit, so "Per kg; yield 0.8 kg" holds the value of one kilogram, and the
/// logged amount in that unit is the factor. The bases are built by `RecipeLogger.basisText`, not typed, so
/// the tests follow the text the journal really stores.
final class IntakeContextSnapshotBasisTests: XCTestCase {
    private func logged(_ amount: String, _ unit: MeasureUnit) -> IntakeComponent {
        IntakeComponent(componentID: "portion", name: "Synthetic portion", amount: dec(amount), unit: unit)
    }

    func testARecipeTotalYieldScalesByTheLoggedAmountInTheYieldsUnit() {
        let cases: [(yield: RecipeYield, logged: IntakeComponent, factor: String)] = [
            (.total(Quantity(value: dec("0.8"), unit: .kg)), logged("200", .g), "0.2"),
            (.total(Quantity(value: dec("0.8"), unit: .kg)), logged("0.2", .kg), "0.2"),
            (.total(Quantity(value: 500, unit: .g)), logged("40", .g), "40"),
            (.total(Quantity(value: 1, unit: .L)), logged("250", .mL), "0.25"),
            (.total(Quantity(value: 1, unit: .L)), logged("1", .L), "1"),
            (.total(Quantity(value: 750, unit: .mL)), logged("150", .mL), "150"),
        ]
        for item in cases {
            let basis = RecipeLogger.basisText(item.yield)
            XCTAssertEqual(
                IntakeContextSnapshotBasis.scalingFactor(labelBasis: basis, logged: [item.logged]),
                dec(item.factor), "\(basis) with \(item.logged.amount) \(item.logged.unit.symbol)")
        }
    }

    /// A basis that names one unit and a yield in another, a bare "Per g", or a yield of nothing says nothing
    /// the journal can scale by, so the factor is nil and nothing is sent or summed.
    func testAnUnresolvedRecipeBasisHasNoFactor() {
        let unresolved = [
            "Per mL; yield 1 L",
            "Per kg; yield 0.8 L",
            "Per g; yield 500 mL",
            "Per g",
            "Per g; yield 0 g",
            "Per kcal; yield 2000 kcal",
            "per glass",
        ]
        for basis in unresolved {
            XCTAssertNil(
                IntakeContextSnapshotBasis.scalingFactor(labelBasis: basis, logged: [logged("40", .g)]), basis)
        }
    }

    /// A logged amount in the other dimension cannot answer a mass or volume basis: mass is not volume without
    /// a density the journal does not record, so the factor is nil rather than a guess.
    func testALoggedAmountInAnotherDimensionDoesNotAnswerAMassBasis() {
        XCTAssertNil(IntakeContextSnapshotBasis.scalingFactor(
            labelBasis: RecipeLogger.basisText(.total(Quantity(value: 500, unit: .g))),
            logged: [logged("40", .mL)]))
    }

    /// The shapes that resolved before must not change, including the counted yield and the household serving.
    func testExistingBasesKeepTheirFactors() {
        XCTAssertEqual(
            IntakeContextSnapshotBasis.scalingFactor(labelBasis: "per 100 g", logged: [logged("40", .g)]),
            dec("0.4"))
        XCTAssertEqual(
            IntakeContextSnapshotBasis.scalingFactor(
                labelBasis: "Per serving; yield 4 servings", logged: [logged("2", .serving)]),
            dec("2"))
        XCTAssertEqual(
            IntakeContextSnapshotBasis.scalingFactor(
                labelBasis: "Per gummy; yield 25 gummy", logged: [logged("2", .gummy)]),
            dec("2"))
        XCTAssertNil(
            IntakeContextSnapshotBasis.scalingFactor(
                labelBasis: "per serving (30 g)", logged: [logged("60", .g)]),
            "a household serving is still answered by the totals builder, not the encoder")
    }
}
