import XCTest
@testable import NutritionDomain

final class CompoundFactTests: XCTestCase {
    private func citrate(_ amount: String, basis: QuantityBasis = .compoundMass) throws -> CompoundFact {
        try CompoundFact.compound(
            substanceIdentifier: "synthetic-magnesium-citrate",
            labelName: "Synthetic magnesium citrate",
            chemicalForm: "citrate",
            amount: try known(amount, .mg),
            basis: basis
        )
    }

    private func factor(_ text: String) throws -> EquivalenceFactor {
        try EquivalenceFactor(value: try dec(text), sourceReference: "Synthetic reference sheet 1")
    }

    func testCompoundMassIsNotActiveNutrientMass() throws {
        let fact = try citrate("1000")
        XCTAssertEqual(fact.basis, .compoundMass)
        XCTAssertEqual(fact.amountReported(as: .compoundMass), try known("1000", .mg))
        XCTAssertNil(fact.amountReported(as: .activeNutrientMass))
        XCTAssertNil(fact.amountReported(as: .unknown))
        let activeTotal = try SupplementTotals.total(
            substance: "synthetic-magnesium-citrate",
            basis: .activeNutrientMass,
            facts: [fact]
        )
        XCTAssertEqual(activeTotal.value, NutrientValue.unknown)
    }

    func testMagnesiumCitrateIsNotElementalMagnesium() throws {
        let fact = try citrate("1000")
        XCTAssertEqual(fact.labelName, "Synthetic magnesium citrate")
        XCTAssertEqual(fact.substanceIdentifier, "synthetic-magnesium-citrate")
        let magnesium = try SupplementTotals.total(
            substance: "synthetic-magnesium",
            basis: .activeNutrientMass,
            facts: [fact]
        )
        XCTAssertEqual(magnesium.value, NutrientValue.unknown)
        XCTAssertNotEqual(magnesium.value, try known("1000", .mg))
        let own = try SupplementTotals.total(
            substance: "synthetic-magnesium-citrate",
            basis: .compoundMass,
            facts: [fact]
        )
        XCTAssertEqual(own.value, try known("1000", .mg))
    }

    func testActiveMassWithoutEquivalenceThrows() throws {
        let fact = try citrate("1000")
        XCTAssertThrowsError(try fact.activeNutrientAmount(equivalence: nil)) { error in
            XCTAssertEqual(error as? CompoundError, CompoundError.missingEquivalenceFactor)
        }
        let active = try citrate("100", basis: .activeNutrientMass)
        XCTAssertThrowsError(try active.activeNutrientAmount(equivalence: try factor("0.1"))) { error in
            XCTAssertEqual(error as? CompoundError, CompoundError.basisNotCompoundMass(.activeNutrientMass))
        }
    }

    func testActiveMassWithExplicitEquivalenceFactor() throws {
        let fact = try citrate("1000")
        let result = try fact.activeNutrientAmount(equivalence: try factor("0.1"))
        XCTAssertEqual(result.amount, try known("100", .mg))
        XCTAssertEqual(result.compoundAmount, try known("1000", .mg))
        XCTAssertEqual(result.compoundSubstanceIdentifier, "synthetic-magnesium-citrate")
        XCTAssertEqual(fact.amount, try known("1000", .mg))
    }

    func testEquivalenceFactorKeepsItsSourceReference() throws {
        let fact = try citrate("1000")
        let result = try fact.activeNutrientAmount(equivalence: try factor("0.1"))
        XCTAssertEqual(result.equivalence.sourceReference, "Synthetic reference sheet 1")
        XCTAssertEqual(result.equivalence.value, try dec("0.1"))
        let padded = try EquivalenceFactor(value: try dec("0.5"), sourceReference: "  Synthetic reference sheet 2  ")
        XCTAssertEqual(padded.sourceReference, "Synthetic reference sheet 2")
    }

    func testEquivalenceFactorOutOfRangeRejected() throws {
        for text in ["0", "1", "1.5", "-0.1"] {
            let value = try dec(text)
            XCTAssertThrowsError(try EquivalenceFactor(value: value, sourceReference: "Synthetic reference sheet 1")) { error in
                XCTAssertEqual(error as? CompoundError, CompoundError.equivalenceFactorOutOfRange(value))
            }
        }
        XCTAssertThrowsError(try EquivalenceFactor(value: try dec("0.5"), sourceReference: "   ")) { error in
            XCTAssertEqual(error as? CompoundError, CompoundError.missingSourceReference)
        }
        XCTAssertNoThrow(try EquivalenceFactor(value: try dec("0.999"), sourceReference: "Synthetic reference sheet 1"))
    }

    func testVitaminFormKept() throws {
        let fact = try CompoundFact.nutrient(
            substanceIdentifier: "synthetic-vitamin-b12",
            labelName: "Synthetic vitamin B12",
            chemicalForm: "Synthetic methylcobalamin",
            amount: try known("500", .mcg),
            basis: .activeNutrientMass,
            provenance: "Synthetic label"
        )
        XCTAssertEqual(fact.chemicalForm, "Synthetic methylcobalamin")
        XCTAssertEqual(fact.labelName, "Synthetic vitamin B12")
        XCTAssertEqual(fact.provenance, "Synthetic label")
        XCTAssertEqual(fact.amount, try known("500", .mcg))
        XCTAssertEqual(fact.role, .contextOnly)
        XCTAssertEqual(fact.kind, .nutrient)
    }

    func testInternationalUnitStaysInternationalUnit() throws {
        let fact = try CompoundFact.nutrient(
            substanceIdentifier: "synthetic-vitamin-d",
            labelName: "Synthetic vitamin D",
            chemicalForm: "Synthetic D3",
            amount: try known("1000", .iu),
            basis: .unknown
        )
        XCTAssertEqual(fact.amount, try known("1000", .iu))
        XCTAssertEqual(fact.amount.quantity?.unit.dimension, UnitDimension.internationalUnit)
        let total = try SupplementTotals.total(substance: "synthetic-vitamin-d", basis: .activeNutrientMass, facts: [fact])
        XCTAssertEqual(total.value, NutrientValue.unknown)
        XCTAssertThrowsError(try fact.amount.converted(to: .mcg)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.internationalUnitNotConvertible(from: .iu, to: .mcg))
        }
    }

    func testInternationalUnitNeedsNoMassInference() throws {
        let fact = try CompoundFact.compound(
            substanceIdentifier: "synthetic-vitamin-d",
            labelName: "Synthetic vitamin D",
            amount: try known("1000", .iu),
            basis: .compoundMass
        )
        XCTAssertThrowsError(try fact.activeNutrientAmount(equivalence: try factor("0.1"))) { error in
            XCTAssertEqual(error as? CompoundError, CompoundError.notMassAmount(.iu))
        }
        XCTAssertEqual(fact.amount, try known("1000", .iu))
    }

    func testCompoundMeasurementRoleOnlyForCompounds() throws {
        let fact = try citrate("1000")
        XCTAssertEqual(fact.role, .compoundMeasurement)
        XCTAssertEqual(fact.kind, .compound)
        XCTAssertThrowsError(try CompoundFact(
            kind: .nutrient, substanceIdentifier: "synthetic-zinc", labelName: "Synthetic zinc",
            amount: try known("5", .mg), basis: .activeNutrientMass, role: .compoundMeasurement
        )) { error in
            XCTAssertEqual(error as? CompoundError, CompoundError.invalidRole(kind: .nutrient, role: .compoundMeasurement))
        }
        XCTAssertThrowsError(try CompoundFact(
            kind: .compound, substanceIdentifier: "synthetic-zinc-oxide", labelName: "Synthetic zinc oxide",
            amount: try known("5", .mg), basis: .compoundMass, role: .contextOnly
        )) { error in
            XCTAssertEqual(error as? CompoundError, CompoundError.invalidRole(kind: .compound, role: .contextOnly))
        }
        XCTAssertThrowsError(try CompoundFact(
            kind: .blend, substanceIdentifier: "synthetic-blend", labelName: "Synthetic blend",
            amount: try known("2000", .mg), basis: .compoundMass, role: .compoundMeasurement
        )) { error in
            XCTAssertEqual(error as? CompoundError, CompoundError.invalidRole(kind: .blend, role: .compoundMeasurement))
        }
    }

    func testNutrientFactCannotBeBlendTotalOnly() throws {
        XCTAssertThrowsError(try CompoundFact(
            kind: .nutrient, substanceIdentifier: "synthetic-zinc", labelName: "Synthetic zinc",
            amount: try known("5", .mg), basis: .activeNutrientMass, role: .blendTotalOnly
        )) { error in
            XCTAssertEqual(error as? CompoundError, CompoundError.invalidRole(kind: .nutrient, role: .blendTotalOnly))
        }
        XCTAssertThrowsError(try CompoundFact(
            kind: .compound, substanceIdentifier: "synthetic-zinc-oxide", labelName: "Synthetic zinc oxide",
            amount: try known("5", .mg), basis: .compoundMass, role: .blendTotalOnly
        )) { error in
            XCTAssertEqual(error as? CompoundError, CompoundError.invalidRole(kind: .compound, role: .blendTotalOnly))
        }
        XCTAssertThrowsError(try CompoundFact.nutrient(
            substanceIdentifier: "synthetic-zinc", labelName: "Synthetic zinc",
            amount: try known("5", .mg), basis: .compoundMass
        )) { error in
            XCTAssertEqual(error as? CompoundError, CompoundError.invalidBasis(kind: .nutrient, basis: .compoundMass))
        }
        XCTAssertThrowsError(try CompoundFact.nutrient(
            substanceIdentifier: " ", labelName: "Synthetic zinc", amount: try known("5", .mg)
        )) { error in
            XCTAssertEqual(error as? CompoundError, CompoundError.emptyField("substanceIdentifier"))
        }
    }

    func testUnknownAmountStaysUnknownThroughConversion() throws {
        let fact = try CompoundFact.compound(
            substanceIdentifier: "synthetic-magnesium-citrate",
            labelName: "Synthetic magnesium citrate",
            amount: .unknown,
            basis: .compoundMass
        )
        let result = try fact.activeNutrientAmount(equivalence: try factor("0.1"))
        XCTAssertEqual(result.amount, NutrientValue.unknown)
        XCTAssertNotEqual(result.amount, try known("0", .mg))
        XCTAssertEqual(result.compoundAmount, NutrientValue.unknown)
        XCTAssertThrowsError(try fact.activeNutrientAmount(equivalence: nil)) { error in
            XCTAssertEqual(error as? CompoundError, CompoundError.missingEquivalenceFactor)
        }
    }

    func testKnownZeroCompoundStaysKnownZero() throws {
        let fact = try citrate("0")
        let result = try fact.activeNutrientAmount(equivalence: try factor("0.1"))
        XCTAssertEqual(result.amount, try known("0", .mg))
        XCTAssertNotEqual(result.amount, NutrientValue.unknown)
        let total = try SupplementTotals.total(
            substance: "synthetic-magnesium-citrate",
            basis: .compoundMass,
            facts: [fact]
        )
        XCTAssertEqual(total.value, try known("0", .mg))
        XCTAssertTrue(total.coverage.isComplete)
        XCTAssertFalse(total.coverage.hasUnknown)
    }

    func testDecimalExactnessOfEquivalenceFactor() throws {
        let direct = Decimal(string: "0.88", locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(direct, try dec("0.88"))
        let creatine = try CompoundFact.compound(
            substanceIdentifier: "synthetic-creatine",
            labelName: "Synthetic creatine monohydrate",
            amount: try known("5", .g),
            basis: .compoundMass
        )
        let result = try creatine.activeNutrientAmount(equivalence: try factor("0.88"))
        XCTAssertEqual(result.amount, try known("4.4", .g))
        XCTAssertEqual(result.equivalence.value, try dec("0.88"))
        let tenth = try citrate("1000").activeNutrientAmount(equivalence: try factor("0.1"))
        XCTAssertEqual(tenth.amount, try known("100", .mg))
        XCTAssertNotEqual(tenth.amount, try known("100.0001", .mg))
    }
}
