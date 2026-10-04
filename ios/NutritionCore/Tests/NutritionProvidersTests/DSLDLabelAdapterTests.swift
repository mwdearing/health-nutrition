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

    func testCitrateFormRowKeepsItsChemicalFormAndItsActiveBasis() throws {
        let label = try adapter.parse(DSLDFixtures.label(204235))
        let magnesium = try XCTUnwrap(label.fact(named: "Magnesium"))
        XCTAssertEqual(magnesium.chemicalForm, "Magnesium Citrate")
        XCTAssertEqual(magnesium.amount, .known(dec("400"), .mg))
        // A listed form records where the nutrient comes from; the amount stays on the active nutrient
        // basis and is never read as the mass of the whole salt.
        XCTAssertEqual(magnesium.kind, .nutrient)
        XCTAssertEqual(magnesium.basis, .activeNutrientMass)
        XCTAssertEqual(magnesium.role, .contextOnly)
        XCTAssertNil(magnesium.amountReported(as: .compoundMass))

        // Calcium 1200 mg "as Calcium Carbonate" in the recorded vitamin label behaves the same way.
        let calcium = try adapter.parse(DSLDFixtures.label(1225))
        let calciumFact = try XCTUnwrap(calcium.fact(named: "Calcium"))
        XCTAssertEqual(calciumFact.chemicalForm, "Calcium Carbonate")
        XCTAssertEqual(calciumFact.basis, .activeNutrientMass)
        let total = try SupplementTotals.total(
            substance: "292683",
            basis: .activeNutrientMass,
            facts: calcium.facts
        )
        XCTAssertEqual(total.value, .known(dec("1200"), .mg), "an active-nutrient total counts this row")
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

    func testTwoBlendRowsWithTheSameIngredientIdStayTwoBlends() throws {
        // Both blend rows carry the same numeric ingredientId, which is what DSLD does when a label
        // lists the same blend under two presentations.
        let label = try parseInline(
            """
            {"id":18,"fullName":"Two blends","brandName":"Test","offMarket":0,
             "ingredientSizes":[],
             "ingredientRows":[
              {"order":1,"ingredientId":900,"name":"Proprietary Blend","category":"blend","forms":[],
               "nestedRows":[{"order":2,"ingredientId":901,"name":"Valerian","quantity":[{"servingSizeOrder":1,"operator":"=","quantity":0,"unit":"NP"}]}],
               "quantity":[{"servingSizeOrder":1,"operator":"=","quantity":500,"unit":"mg"}]},
              {"order":3,"ingredientId":900,"name":"Proprietary Blend","category":"blend","forms":[],
               "nestedRows":[{"order":4,"ingredientId":902,"name":"Hops","quantity":[{"servingSizeOrder":1,"operator":"=","quantity":0,"unit":"NP"}]}],
               "quantity":[{"servingSizeOrder":1,"operator":"=","quantity":250,"unit":"mg"}]}]}
            """
        )
        XCTAssertEqual(label.blends.count, 2)
        let identifiers = label.blends.map(\.identifier)
        XCTAssertEqual(Set(identifiers).count, 2, "two blend rows must not share one identifier")
        XCTAssertEqual(identifiers, ["dsld-18-1-900", "dsld-18-3-900"])
        XCTAssertEqual(label.blends.map(\.total), [.known(dec("500"), .mg), .known(dec("250"), .mg)])
        XCTAssertEqual(label.blends[1].members.map(\.labelName), ["Hops"])

        // Both blends reach a total: SupplementTotals drops a blend whose identifier it has already seen.
        let total = try SupplementTotals.total(
            substance: "dsld-18-1-900",
            basis: .compoundMass,
            facts: label.facts,
            blends: label.blends
        )
        XCTAssertEqual(total.value, .known(dec("500"), .mg))
        let other = try SupplementTotals.total(
            substance: "dsld-18-3-900",
            basis: .compoundMass,
            facts: label.facts,
            blends: label.blends
        )
        XCTAssertEqual(other.value, .known(dec("250"), .mg))
    }

    func testNestedRowsUnderAnOrdinaryNutrientStayFacts() throws {
        // Folate carries a nested row for presentation; it is not a proprietary blend.
        let prenatal = try adapter.parse(DSLDFixtures.label(202695))
        let folate = try XCTUnwrap(prenatal.fact(named: "Folate"))
        XCTAssertEqual(folate.amount, .unknown, "\"mcg DFE\" is not a unit the adapter reads")
        XCTAssertNil(prenatal.blends.first { $0.labelName == "Folate" })
        let folicAcid = try XCTUnwrap(prenatal.fact(named: "Folic Acid"))
        XCTAssertEqual(folicAcid.amount, .known(dec("360"), .mcg))
        XCTAssertEqual(folicAcid.kind, .nutrient)
        XCTAssertEqual(folicAcid.basis, .activeNutrientMass)

        // Calories -> Calories from Fat in the fish oil label behaves the same way.
        let fishOil = try adapter.parse(DSLDFixtures.label(64567))
        XCTAssertNil(fishOil.blends.first { $0.labelName == "Calories" })
        XCTAssertNotNil(fishOil.fact(named: "Calories"))
        XCTAssertNotNil(fishOil.fact(named: "Calories from Fat"))

        // DSLD marks the probiotic row itself as a blend, and it stays a blend.
        let probiotic = try XCTUnwrap(prenatal.blends.first { $0.labelName == "Probiotic" })
        XCTAssertEqual(probiotic.total, .unknown, "a stated zero of an unlisted unit is unknown, not zero")
        XCTAssertEqual(probiotic.members.map(\.labelName), ["Lactobacillus plantarum 299v"])
    }

    func testNestedFactKeepsItsOwnIdentifierAndOrder() throws {
        let prenatal = try adapter.parse(DSLDFixtures.label(202695))
        let folicAcid = try XCTUnwrap(prenatal.fact(named: "Folic Acid"))
        XCTAssertEqual(folicAcid.substanceIdentifier, "279040", "a numeric DSLD identifier is kept as its text")
        XCTAssertEqual(prenatal.fact(named: "Folate")?.substanceIdentifier, "278757")
    }

    func testNumericIdentifiersAndRowOrderAreKept() throws {
        let label = try adapter.parse(DSLDFixtures.label(204235))
        let magnesium = try XCTUnwrap(label.fact(named: "Magnesium"))
        XCTAssertEqual(magnesium.substanceIdentifier, "6520", "the identifier is the DSLD id, not the display name")
        XCTAssertEqual(magnesium.provenance, "NIH DSLD label 204235, ingredient row 1, serving size 1")

        let blend = try adapter.parse(DSLDFixtures.label(216782))
            .blends.first { $0.labelName == "Proprietary Blend" }
        let proprietaryBlend = try XCTUnwrap(blend)
        XCTAssertEqual(proprietaryBlend.identifier, "dsld-216782-1-284535")
        XCTAssertEqual(proprietaryBlend.members.first?.substanceIdentifier, "231239", "a nested member keeps its numeric id")
        XCTAssertEqual(
            proprietaryBlend.totalFact.provenance,
            "NIH DSLD label 216782, proprietary blend row 1, serving size 1"
        )
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

    func testALessThanQuantityWithAnUnsupportedUnitIsUnknown() throws {
        let label = try parseInline(
            """
            {"id":7,"fullName":"Unlisted bound","brandName":"Test","offMarket":0,
             "ingredientRows":[
              {"order":1,"name":"Folate","forms":[],"nestedRows":[],
               "quantity":[{"servingSizeOrder":1,"operator":"<","quantity":400,"unit":"mcg DFE"}]},
              {"order":2,"name":"Vitamin C","forms":[],"nestedRows":[],
               "quantity":[{"servingSizeOrder":1,"operator":"<","quantity":40,"unit":"mg"}]}]}
            """
        )
        XCTAssertEqual(label.facts[0].amount, .unknown, "a bound in an unlisted unit carries no usable dimension")
        XCTAssertEqual(label.facts[1].amount, .belowReportingThreshold(MeasureUnit.mg))
    }

    func testFactsAreKeptForEveryServingSizeTheLabelLists() throws {
        let label = try parseInline(
            """
            {"id":13,"fullName":"Two servings","brandName":"Test","offMarket":0,
             "servingSizes":[
              {"order":1,"minQuantity":1,"maxQuantity":1,"unit":"Tablet(s)","inSFB":true},
              {"order":2,"minQuantity":2,"maxQuantity":2,"unit":"Tablet(s)","inSFB":false}],
             "ingredientRows":[
              {"order":1,"name":"Vitamin C","forms":[],"nestedRows":[],
               "quantity":[{"servingSizeOrder":1,"operator":"=","quantity":60,"unit":"mg"},
                           {"servingSizeOrder":2,"operator":"=","quantity":120,"unit":"mg"}]},
              {"order":2,"name":"Zinc","forms":[],"nestedRows":[],
               "quantity":[{"servingSizeOrder":1,"operator":"=","quantity":5,"unit":"mg"}]}]}
            """
        )
        XCTAssertEqual(label.servingSizes.count, 2)
        XCTAssertEqual(label.servings.count, 2, "every serving size the label lists keeps its own facts")

        let first = label.servings[0]
        XCTAssertEqual(first.order, 1)
        XCTAssertEqual(first.servingSize?.minimum, Quantity(value: dec("1"), unit: .serving))
        XCTAssertEqual(first.facts.map(\.labelName), ["Vitamin C", "Zinc"])
        XCTAssertEqual(first.facts[0].amount, .known(dec("60"), .mg))

        let second = label.servings[1]
        XCTAssertEqual(second.order, 2)
        XCTAssertEqual(second.servingSize?.minimum, Quantity(value: dec("2"), unit: .serving))
        XCTAssertEqual(second.facts[0].amount, .known(dec("120"), .mg), "the second serving keeps its own amount")
        XCTAssertEqual(
            second.facts[1].amount, .unknown,
            "a row that states no amount for the second serving is unknown there, not the first amount"
        )

        // The plain facts and blends are the first serving size.
        XCTAssertEqual(label.facts, first.facts)
        XCTAssertEqual(label.fact(named: "Vitamin C")?.amount, .known(dec("60"), .mg))
    }

    func testEveryRecordedLabelKeepsItsServingSizesAssociated() throws {
        for entry in try DSLDFixtures.recordedLabels() {
            let label = try adapter.parse(DSLDFixtures.data(entry.file))
            XCTAssertEqual(
                label.servings.count, label.servingSizes.count,
                "\(entry.file) does not associate its facts with every serving size"
            )
            for serving in label.servings {
                XCTAssertNotNil(serving.servingSize, "\(entry.file) has no serving size for order \(serving.order)")
            }
        }
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

    func testLeadingZeroNumbersAreRejected() {
        XCTAssertThrowsError(try parseInline("{\"id\":01,\"fullName\":\"Zero\",\"ingredientRows\":[]}")) { error in
            guard case DSLDAdapterError.malformedJSON = error else {
                return XCTFail("expected malformedJSON for a leading zero, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try parseInline("{\"id\":8,\"ingredientRows\":[{\"order\":01,\"name\":\"X\"}]}")
        ) { error in
            guard case DSLDAdapterError.malformedJSON = error else {
                return XCTFail("expected malformedJSON for a leading zero, got \(error)")
            }
        }
        // A plain zero and a zero after a decimal point stay valid.
        XCTAssertNoThrow(try parseInline("{\"id\":9,\"fullName\":\"Zero\",\"ingredientRows\":[{\"order\":1,\"name\":\"X\",\"forms\":[],\"nestedRows\":[],\"quantity\":[{\"operator\":\"=\",\"quantity\":0.10,\"unit\":\"mg\"}]}]}"))
    }

    func testOverPreciseOrOutOfRangeDecimalLiteralsAreRejected() {
        // 41 significant digits: more than a Decimal holds, so it must not be rounded silently.
        let overPrecise = """
        {"id":14,"fullName":"Precise","ingredientRows":[{"order":1,"name":"Vitamin C","forms":[],
         "nestedRows":[],"quantity":[{"operator":"=","quantity":1.23456789012345678901234567890123456789012,"unit":"mg"}]}]}
        """
        XCTAssertThrowsError(try parseInline(overPrecise)) { error in
            guard case DSLDAdapterError.malformedJSON = error else {
                return XCTFail("expected malformedJSON for an over-precise literal, got \(error)")
            }
        }
        // An exponent far outside what a Decimal can hold.
        XCTAssertThrowsError(try parseInline(
            "{\"id\":15,\"ingredientRows\":[{\"order\":1,\"name\":\"X\",\"quantity\":[{\"operator\":\"=\",\"quantity\":1e400,\"unit\":\"mg\"}]}]}"
        )) { error in
            guard case DSLDAdapterError.malformedJSON = error else {
                return XCTFail("expected malformedJSON for an out-of-range exponent, got \(error)")
            }
        }
        // 38 significant digits still round-trips exactly.
        XCTAssertNoThrow(try parseInline(
            "{\"id\":16,\"ingredientRows\":[{\"order\":1,\"name\":\"X\",\"forms\":[],\"nestedRows\":[],\"quantity\":[{\"operator\":\"=\",\"quantity\":1.2345678901234567890123456789012345678,\"unit\":\"mg\"}]}]}"
        ))
    }

    func testStringErrorsCarryAbsoluteDocumentOffsets() {
        // A prefix long enough that a run-relative offset could not be mistaken for the real position.
        let prefix = "{\"id\":17,\"fullName\":\"A rather long product name that pushes the string well past byte zero\",\"x\":\""
        let broken = Data((prefix + "\u{0C}" + "\",\"ingredientRows\":[]}").utf8)
        XCTAssertThrowsError(try adapter.parse(broken)) { error in
            guard case DSLDAdapterError.malformedJSON(_, let offset) = error else {
                return XCTFail("expected malformedJSON, got \(error)")
            }
            XCTAssertEqual(offset, prefix.utf8.count, "the offset must point at the offending byte in the document")
        }

        // Invalid UTF-8 reports the same way.
        var brokenUTF8: [UInt8] = Array(prefix.utf8)
        brokenUTF8.append(0xF5)
        brokenUTF8.append(contentsOf: Array("\",\"ingredientRows\":[]}".utf8))
        XCTAssertThrowsError(try adapter.parse(Data(brokenUTF8))) { error in
            guard case DSLDAdapterError.malformedJSON(_, let offset) = error else {
                return XCTFail("expected malformedJSON, got \(error)")
            }
            XCTAssertEqual(offset, prefix.utf8.count)
        }
    }

    func testInvalidBytesAndControlCharactersInStringsAreRejected() {
        // A literal newline inside a quoted name has to be escaped.
        let withNewline = Data("{\"id\":10,\"fullName\":\"Two\nLines\",\"ingredientRows\":[]}".utf8)
        XCTAssertThrowsError(try adapter.parse(withNewline)) { error in
            guard case DSLDAdapterError.malformedJSON = error else {
                return XCTFail("expected malformedJSON for an unescaped control character, got \(error)")
            }
        }

        // An invalid UTF-8 byte inside a quoted name.
        var broken: [UInt8] = Array("{\"id\":11,\"fullName\":\"".utf8)
        broken.append(0xC3)  // a lead byte with no continuation
        broken.append(contentsOf: Array("\",\"ingredientRows\":[]}".utf8))
        XCTAssertThrowsError(try adapter.parse(Data(broken))) { error in
            guard case DSLDAdapterError.malformedJSON = error else {
                return XCTFail("expected malformedJSON for invalid UTF-8, got \(error)")
            }
        }

        // A well-formed label with an escaped newline still parses.
        XCTAssertNoThrow(try parseInline("{\"id\":12,\"fullName\":\"Two\\nLines\",\"ingredientRows\":[]}"))
    }
}