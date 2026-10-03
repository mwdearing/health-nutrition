import Foundation
import NutritionDomain
import XCTest
@testable import NutritionProviders

/// Reads the recorded DSLD fixtures that live in `contracts/providers/dsld` in the repository, found
/// relative to this file so the tests need no bundled resources and no network.
private enum DSLDFixtures {
    struct Recorded {
        let file: String
        let labelIdentifier: Int?
        let offMarket: Bool?
        let searchTerm: String?
    }

    static func directory(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: String(describing: file))
        // .../ios/NutritionCore/Tests/NutritionProvidersTests/DSLDLabelAdapterTests.swift -> repository root
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("contracts/providers/dsld")
    }

    /// Every label file listed in MANIFEST.json, in manifest order.
    static func recordedLabels(file: StaticString = #filePath) throws -> [Recorded] {
        let manifestURL = directory(file: file).appendingPathComponent("MANIFEST.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        let entries = manifest?["files"] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let name = entry["file"] as? String, name.contains("labels/") else { return nil }
            return Recorded(
                file: name,
                labelIdentifier: entry["label_id"] as? Int,
                offMarket: (entry["off_market"] as? Int).map { $0 != 0 },
                searchTerm: entry["search_term"] as? String
            )
        }
    }

    static func data(_ name: String, file: StaticString = #filePath) throws -> Data {
        try Data(contentsOf: directory(file: file).appendingPathComponent(name))
    }

    /// A label by its DSLD identifier, for example 204235.
    static func label(_ identifier: Int, file: StaticString = #filePath) throws -> Data {
        try data("fixtures/labels/\(identifier).json", file: file)
    }
}

final class DSLDLabelAdapterTests: XCTestCase {
    private let adapter = DSLDLabelAdapter()

    private func dec(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    }

    private func parseInline(_ text: String) throws -> DSLDSupplementLabel {
        try adapter.parse(Data(text.utf8))
    }

    // MARK: - Every recorded label

    func testEveryRecordedLabelInTheManifestParses() throws {
        let recorded = try DSLDFixtures.recordedLabels()
        XCTAssertGreaterThanOrEqual(recorded.count, 10, "the manifest should list every recorded label")
        for entry in recorded {
            let label = try adapter.parse(DSLDFixtures.data(entry.file))
            XCTAssertEqual(label.id, entry.labelIdentifier ?? -1, "wrong identifier for \(entry.file)")
            if let offMarket = entry.offMarket {
                XCTAssertEqual(label.offMarket, offMarket, "wrong off-market flag for \(entry.file)")
            }
            XCTAssertFalse(label.fullName.isEmpty, "\(entry.file) has no name")
            XCTAssertFalse(
                label.facts.isEmpty && label.blends.isEmpty,
                "\(entry.file) produced neither facts nor blends"
            )
            for fact in label.facts {
                XCTAssertTrue(
                    fact.provenance?.hasPrefix("NIH DSLD label") == true,
                    "\(entry.file) lost the provenance of \(fact.labelName)"
                )
                if case .known(let value, _) = fact.amount {
                    XCTAssertGreaterThan(value, 0, "a stated zero is never a known amount")
                }
            }
        }
    }

    func testManifestCoverageItemsArePresent() throws {
        let recorded = try DSLDFixtures.recordedLabels()
        let terms = recorded.compactMap(\.searchTerm)
        XCTAssertTrue(recorded.contains { ($0.offMarket ?? false) }, "an off-market label is recorded")
        for term in ["vitamin D3", "magnesium citrate", "proprietary blend", "creatine monohydrate"] {
            XCTAssertTrue(terms.contains(term), "\(term) is recorded")
        }
    }

    // MARK: - Units

    func testInternationalUnitRowsStayInternationalUnits() throws {
        let label = try adapter.parse(DSLDFixtures.label(29011))
        let vitaminA = try XCTUnwrap(label.fact(named: "Vitamin A"))
        XCTAssertEqual(vitaminA.amount, .known(dec("6000"), .iu))
        let vitaminD = try XCTUnwrap(label.fact(named: "Vitamin D3"))
        XCTAssertEqual(vitaminD.amount, .known(dec("800"), .iu))
        // IU is never converted to a mass.
        guard case .known(let value, let unit) = vitaminA.amount else {
            return XCTFail("Vitamin A should carry an amount")
        }
        XCTAssertEqual(unit.dimension, .internationalUnit)
        XCTAssertThrowsError(try Quantity(value: value, unit: unit).converted(to: .mcg)) { error in
            guard case UnitError.internationalUnitNotConvertible = error else {
                return XCTFail("expected an international unit refusal, got \(error)")
            }
        }
    }

    func testMicrogramsAreReadAsMicrograms() throws {
        let label = try adapter.parse(DSLDFixtures.label(240278))
        let b12 = try XCTUnwrap(label.fact(named: "Vitamin B12"))
        XCTAssertEqual(b12.amount, .known(dec("5000"), .mcg))
    }

    func testCitrateFormRowKeepsItsChemicalForm() throws {
        let label = try adapter.parse(DSLDFixtures.label(204235))
        let magnesium = try XCTUnwrap(label.fact(named: "Magnesium"))
        XCTAssertEqual(magnesium.chemicalForm, "Magnesium Citrate")
        XCTAssertEqual(magnesium.amount, .known(dec("400"), .mg))
        XCTAssertEqual(magnesium.kind, .compound)
        XCTAssertEqual(magnesium.basis, .compoundMass)
        XCTAssertEqual(magnesium.role, .compoundMeasurement)
    }

    // MARK: - Proprietary blends

    func testProprietaryBlendRowBecomesABlendWithUnknownMembers() throws {
        let label = try adapter.parse(DSLDFixtures.label(216782))
        let blend = try XCTUnwrap(label.blends.first)
        XCTAssertEqual(blend.labelName, "Proprietary Blend")
        XCTAssertEqual(blend.total, .known(dec("1000"), .mg))
        XCTAssertEqual(blend.members.count, 6)
        XCTAssertEqual(blend.members.map(\.labelName).first, "Valerian")
        XCTAssertEqual(blend.undisclosedMembers.count, 6, "the amounts of the members are not disclosed")
        XCTAssertNil(label.fact(named: "Proprietary Blend"), "a blend total is not repeated as a fact")
        XCTAssertNotNil(label.fact(named: "Melatonin"))
    }

    func testNestedRowsBecomeBlendMembersWithTheirOwnAmounts() throws {
        let label = try adapter.parse(DSLDFixtures.label(202695))
        let blend = try XCTUnwrap(label.blends.first { $0.labelName == "Folate" })
        let member = try XCTUnwrap(blend.members.first)
        XCTAssertEqual(member.labelName, "Folic Acid")
        XCTAssertEqual(member.amount, .known(dec("360"), .mcg))
        let probiotic = try XCTUnwrap(label.blends.first { $0.labelName == "Probiotic" })
        XCTAssertEqual(probiotic.total, .unknown, "a stated zero of an unlisted unit is unknown, not zero")
    }

    // MARK: - Flags and serving sizes

    func testOffMarketLabelsAreFlagged() throws {
        let offMarket = try adapter.parse(DSLDFixtures.label(1225))
        XCTAssertTrue(offMarket.offMarket)
        XCTAssertEqual(offMarket.fullName, "Calcium With Vitamin D3")
        XCTAssertEqual(offMarket.brandName, "Vitamin World")

        let onMarket = try adapter.parse(DSLDFixtures.label(29011))
        XCTAssertFalse(onMarket.offMarket)
    }

    func testServingSizesBecomeQuantities() throws {
        let countServing = try adapter.parse(DSLDFixtures.label(204235))
        let caplet = try XCTUnwrap(countServing.servingSizes.first)
        XCTAssertEqual(caplet.minimum, Quantity(value: dec("2"), unit: .serving))
        XCTAssertEqual(caplet.maximum, Quantity(value: dec("2"), unit: .serving))
        XCTAssertEqual(caplet.unitText, "Caplet(s)")
        XCTAssertTrue(caplet.isFactsPanelServing)

        let massServing = try adapter.parse(DSLDFixtures.label(254073))
        let milligramServing = try XCTUnwrap(massServing.servingSizes.first)
        XCTAssertEqual(milligramServing.minimum.unit, .mg)
        XCTAssertEqual(milligramServing.minimum.value, dec("285"))
    }

    // MARK: - Unknown is never zero

    func testMissingOrUnlistedQuantityIsUnknownAndNeverZero() throws {
        let label = try adapter.parse(DSLDFixtures.label(64567))
        let totalFat = try XCTUnwrap(label.fact(named: "Total Fat"))
        XCTAssertEqual(totalFat.amount, .unknown, "an amount in an unlisted unit stays unknown")
        XCTAssertNotEqual(totalFat.amount, .known(0, .g))
        let epa = try XCTUnwrap(label.fact(named: "Eicosapentaenoic Acid"))
        XCTAssertEqual(epa.amount, .known(dec("425"), .mg))
        XCTAssertEqual(epa.chemicalForm, "Fish Oil")
    }

    func testAZeroQuantityIsUnknownRatherThanZero() throws {
        let label = try parseInline(
            """
            {"id":1,"fullName":"Zero","brandName":"Test","offMarket":0,
             "ingredientRows":[{"order":1,"name":"Vitamin C","forms":[],"nestedRows":[],
              "quantity":[{"servingSizeOrder":1,"operator":"=","quantity":0,"unit":"mg"}]}]}
            """
        )
        XCTAssertEqual(label.facts.first?.amount, .unknown)
    }

    func testAMissingQuantityIsUnknown() throws {
        let label = try parseInline(
            """
            {"id":2,"fullName":"No quantity","brandName":"Test","offMarket":0,
             "ingredientRows":[{"order":1,"name":"Vitamin C","forms":[],"nestedRows":[]}]}
            """
        )
        XCTAssertEqual(label.facts.first?.amount, .unknown)
    }

    // MARK: - Operators

    func testANonEqualityOperatorIsNeverAKnownExactAmount() throws {
        let label = try parseInline(
            """
            {"id":3,"fullName":"Bounds","brandName":"Test","offMarket":0,
             "ingredientRows":[
              {"order":1,"name":"Vitamin C","forms":[],"nestedRows":[],
               "quantity":[{"servingSizeOrder":1,"operator":"<","quantity":5,"unit":"mg"}]},
              {"order":2,"name":"Vitamin E","forms":[],"nestedRows":[],
               "quantity":[{"servingSizeOrder":1,"operator":">","quantity":30,"unit":"IU"}]},
              {"order":3,"name":"Zinc","forms":[],"nestedRows":[],
               "quantity":[{"servingSizeOrder":1,"operator":"=","quantity":15,"unit":"mg"}]}]}
            """
        )
        XCTAssertEqual(label.facts.count, 3)
        guard case .belowReportingThreshold(let thresholdUnit) = label.facts[0].amount else {
            return XCTFail("a less-than row is below the reporting threshold, not an exact amount")
        }
        XCTAssertEqual(thresholdUnit, MeasureUnit.mg)
        XCTAssertNotEqual(label.facts[0].amount, .known(dec("5"), .mg))
        XCTAssertEqual(label.facts[1].amount, .unknown, "a greater-than row is unknown")
        XCTAssertEqual(label.facts[2].amount, .known(dec("15"), .mg))
    }

    func testAMissingOperatorIsNotTreatedAsExact() throws {
        let label = try parseInline(
            """
            {"id":4,"fullName":"No operator","brandName":"Test","offMarket":0,
             "ingredientRows":[{"order":1,"name":"Iron","forms":[],"nestedRows":[],
              "quantity":[{"servingSizeOrder":1,"quantity":18,"unit":"mg"}]}]}
            """
        )
        XCTAssertEqual(label.facts.first?.amount, .unknown)
    }

    // MARK: - Decimal exactness

    func testDecimalAmountsAreParsedExactlyFromTheirJsonText() throws {
        let label = try parseInline(
            """
            {"id":5,"fullName":"Exact","brandName":"Test","offMarket":0,
             "ingredientRows":[
              {"order":1,"name":"Thiamine","forms":[],"nestedRows":[],
               "quantity":[{"servingSizeOrder":1,"operator":"=","quantity":0.1,"unit":"mg"}]},
              {"order":2,"name":"Vitamin B6","forms":[],"nestedRows":[],
               "quantity":[{"servingSizeOrder":1,"operator":"=","quantity":2.5,"unit":"mg"}]},
              {"order":3,"name":"Niacin","forms":[],"nestedRows":[],
               "quantity":[{"servingSizeOrder":1,"operator":"=","quantity":1200,"unit":"mcg"}]}]}
            """
        )
        XCTAssertEqual(label.facts[0].amount, .known(Decimal(string: "0.1")!, .mg))
        XCTAssertEqual(label.facts[1].amount, .known(Decimal(string: "2.5")!, .mg))
        XCTAssertEqual(label.facts[2].amount, .known(Decimal(string: "1200")!, .mcg))
        guard case .known(let small, _) = label.facts[0].amount else {
            return XCTFail("0.1 mg should be a known amount")
        }
        guard case .known(let large, _) = label.facts[1].amount else {
            return XCTFail("2.5 mg should be a known amount")
        }
        XCTAssertEqual(small * large, Decimal(string: "0.25")!, "the amounts stay exact when combined")
    }

    // MARK: - Malformed input

    func testMalformedInputThrowsATypedError() {
        XCTAssertThrowsError(try adapter.parse(Data("this is not json".utf8))) { error in
            XCTAssertTrue(error is DSLDAdapterError, "expected a DSLDAdapterError, got \(error)")
        }
        XCTAssertThrowsError(try adapter.parse(Data("{\"id\":".utf8))) { error in
            XCTAssertTrue(error is DSLDAdapterError)
        }
        XCTAssertThrowsError(try adapter.parse(Data("[1,2,3]".utf8))) { error in
            XCTAssertEqual(error as? DSLDAdapterError, .notAnObject)
        }
        XCTAssertThrowsError(try parseInline("{\"fullName\":\"No id\"}")) { error in
            XCTAssertEqual(error as? DSLDAdapterError, .missingIdentifier)
        }
        XCTAssertThrowsError(try parseInline("{\"id\":6,\"fullName\":\"No rows\"}")) { error in
            XCTAssertEqual(error as? DSLDAdapterError, .missingIngredientRows)
        }
    }
}