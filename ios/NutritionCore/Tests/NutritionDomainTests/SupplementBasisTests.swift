import XCTest
@testable import NutritionDomain

final class SupplementBasisTests: XCTestCase {
    private func creatine(_ amount: String, _ unit: MeasureUnit, basis: QuantityBasis, form: String? = nil) throws -> CompoundFact {
        try CompoundFact.compound(
            substanceIdentifier: "synthetic-creatine",
            labelName: "Synthetic creatine",
            chemicalForm: form,
            amount: try known(amount, unit),
            basis: basis
        )
    }

    private func magnesium(_ amount: String, _ unit: MeasureUnit = .mg, basis: QuantityBasis = .activeNutrientMass) throws -> CompoundFact {
        try CompoundFact.nutrient(
            substanceIdentifier: "synthetic-magnesium",
            labelName: "Synthetic magnesium",
            amount: try known(amount, unit),
            basis: basis
        )
    }

    func testCreatineMonohydrateBasisKept() throws {
        let fact = try creatine("5", .g, basis: .compoundMass, form: "monohydrate")
        XCTAssertEqual(fact.basis, .compoundMass)
        XCTAssertEqual(fact.chemicalForm, "monohydrate")
        XCTAssertEqual(fact.amountReported(as: .compoundMass), try known("5", .g))
        XCTAssertNil(fact.amountReported(as: .activeNutrientMass))
        let equivalence = try EquivalenceFactor(value: try dec("0.88"), sourceReference: "Synthetic reference sheet 1")
        let converted = try fact.activeNutrientAmount(equivalence: equivalence)
        XCTAssertEqual(converted.amount, try known("4.4", .g))
        XCTAssertEqual(converted.compoundAmount, try known("5", .g))
    }

    func testCreatineEquivalentBasisKept() throws {
        let fact = try creatine("4.4", .g, basis: .activeNutrientMass)
        XCTAssertEqual(fact.basis, .activeNutrientMass)
        XCTAssertEqual(fact.amountReported(as: .activeNutrientMass), try known("4.4", .g))
        XCTAssertNil(fact.amountReported(as: .compoundMass))
        XCTAssertThrowsError(try fact.activeNutrientAmount(equivalence: nil)) { error in
            XCTAssertEqual(error as? CompoundError, CompoundError.basisNotCompoundMass(.activeNutrientMass))
        }
    }

    func testCreatineBasisMissingIsNeverInferred() throws {
        let fact = try creatine("5", .g, basis: .unknown)
        XCTAssertNil(fact.amountReported(as: .compoundMass))
        XCTAssertNil(fact.amountReported(as: .activeNutrientMass))
        XCTAssertNil(fact.amountReported(as: .unknown))
        XCTAssertThrowsError(try fact.activeNutrientAmount(equivalence: nil)) { error in
            XCTAssertEqual(error as? CompoundError, CompoundError.basisUnknown)
        }
        let monohydrate = try SupplementTotals.total(substance: "synthetic-creatine", basis: .compoundMass, facts: [fact])
        XCTAssertEqual(monohydrate.value, NutrientValue.unknown)
        XCTAssertTrue(monohydrate.coverage.hasUnknown)
        let equivalent = try SupplementTotals.total(substance: "synthetic-creatine", basis: .activeNutrientMass, facts: [fact])
        XCTAssertEqual(equivalent.value, NutrientValue.unknown)
        XCTAssertThrowsError(try SupplementTotals.total(substance: "synthetic-creatine", basis: .unknown, facts: [fact])) { error in
            XCTAssertEqual(error as? CompoundError, CompoundError.totalNeedsDeclaredBasis)
        }
    }

    func testCreatineMonohydrateAndEquivalentNeverMixedInOneTotal() throws {
        let monohydrate = try creatine("5", .g, basis: .compoundMass)
        let equivalent = try creatine("4.4", .g, basis: .activeNutrientMass)
        let facts = [monohydrate, equivalent]
        let compoundTotal = try SupplementTotals.total(substance: "synthetic-creatine", basis: .compoundMass, facts: facts)
        XCTAssertEqual(compoundTotal.value, try known("5", .g))
        XCTAssertEqual(compoundTotal.coverage.knownCount, 1)
        let activeTotal = try SupplementTotals.total(substance: "synthetic-creatine", basis: .activeNutrientMass, facts: facts)
        XCTAssertEqual(activeTotal.value, try known("4.4", .g))
        XCTAssertNotEqual(compoundTotal.value, try known("9.4", .g))
        XCTAssertNotEqual(activeTotal.value, try known("9.4", .g))
    }

    func testSubstanceTotalSkipsUnknownBasis() throws {
        let facts = [
            try magnesium("100"),
            try magnesium("50", basis: .unknown),
            try CompoundFact.compound(
                substanceIdentifier: "synthetic-magnesium",
                labelName: "Synthetic magnesium citrate",
                amount: try known("1000", .mg),
                basis: .compoundMass
            ),
        ]
        let total = try SupplementTotals.total(substance: "synthetic-magnesium", basis: .activeNutrientMass, facts: facts)
        XCTAssertEqual(total.value, try known("100", .mg))
        XCTAssertEqual(total.coverage.knownCount, 1)
        XCTAssertEqual(total.coverage.totalCount, 2)
        XCTAssertTrue(total.coverage.hasUnknown)
        XCTAssertFalse(total.coverage.isComplete)
    }

    func testSubstanceTotalReportsCoverage() throws {
        let facts = [
            try magnesium("100"),
            try magnesium("50"),
            try CompoundFact.nutrient(
                substanceIdentifier: "synthetic-magnesium",
                labelName: "Synthetic magnesium",
                amount: .unknown
            ),
        ]
        let partial = try SupplementTotals.total(substance: "synthetic-magnesium", basis: .activeNutrientMass, facts: facts)
        XCTAssertEqual(partial.value, try known("150", .mg))
        XCTAssertEqual(partial.coverage.knownCount, 2)
        XCTAssertEqual(partial.coverage.totalCount, 3)
        XCTAssertTrue(partial.coverage.hasUnknown)
        XCTAssertFalse(partial.coverage.isComplete)
        let complete = try SupplementTotals.total(substance: "synthetic-magnesium", basis: .activeNutrientMass, facts: Array(facts.prefix(2)))
        XCTAssertTrue(complete.coverage.isComplete)
        XCTAssertFalse(complete.coverage.hasUnknown)
    }

    func testSubstanceTotalOfOnlyUnknownIsUnknownNotZero() throws {
        let facts = [
            try CompoundFact.nutrient(
                substanceIdentifier: "synthetic-magnesium",
                labelName: "Synthetic magnesium",
                amount: .unknown
            ),
        ]
        let total = try SupplementTotals.total(substance: "synthetic-magnesium", basis: .activeNutrientMass, facts: facts)
        XCTAssertEqual(total.value, NutrientValue.unknown)
        XCTAssertNotEqual(total.value, try known("0", .mg))
        XCTAssertEqual(total.coverage.knownCount, 0)
        XCTAssertTrue(total.coverage.hasUnknown)
    }

    func testMixedUnitsSameSubstanceAddedAfterConversion() throws {
        let facts = [
            try magnesium("1", .g),
            try magnesium("500", .mg),
            try magnesium("250000", .mcg),
        ]
        let inGrams = try SupplementTotals.total(substance: "synthetic-magnesium", basis: .activeNutrientMass, facts: facts)
        XCTAssertEqual(inGrams.value, try known("1.75", .g))
        let inMilligrams = try SupplementTotals.total(substance: "synthetic-magnesium", basis: .activeNutrientMass, facts: facts, in: .mg)
        XCTAssertEqual(inMilligrams.value, try known("1750", .mg))
        XCTAssertTrue(inMilligrams.coverage.isComplete)
        let mixedDimensions = [try magnesium("1000", .iu), try magnesium("5", .mg)]
        XCTAssertThrowsError(try SupplementTotals.total(substance: "synthetic-magnesium", basis: .activeNutrientMass, facts: mixedDimensions)) { error in
            XCTAssertEqual(error as? UnitError, UnitError.dimensionMismatch(from: .mg, to: .iu))
        }
    }

    func testDifferentSubstancesNeverShareATotal() throws {
        let zinc = try CompoundFact.nutrient(
            substanceIdentifier: "synthetic-zinc",
            labelName: "Synthetic zinc",
            amount: try known("5", .mg)
        )
        let facts = [try magnesium("100"), zinc]
        let magnesiumTotal = try SupplementTotals.total(substance: "synthetic-magnesium", basis: .activeNutrientMass, facts: facts)
        let zincTotal = try SupplementTotals.total(substance: "synthetic-zinc", basis: .activeNutrientMass, facts: facts)
        XCTAssertEqual(magnesiumTotal.value, try known("100", .mg))
        XCTAssertEqual(zincTotal.value, try known("5", .mg))
        XCTAssertEqual(magnesiumTotal.coverage.totalCount, 1)
        XCTAssertEqual(zincTotal.coverage.totalCount, 1)
        let none = try SupplementTotals.total(substance: "synthetic-iron", basis: .activeNutrientMass, facts: facts)
        XCTAssertEqual(none.value, NutrientValue.unknown)
    }
}
