import XCTest
@testable import NutritionDomain

/// The adult reference table. Each figure asserted here was read off the NIH Office of Dietary
/// Supplements fact sheet named in `docs/reference-intakes.md`, so a typo in the table fails a test
/// rather than reaching a screen.
final class ReferenceIntakesTests: XCTestCase {
    private func group(_ sex: ReferenceSex, _ band: ReferenceAgeBand) -> ReferenceGroup {
        ReferenceGroup(sex: sex, ageBand: band)
    }

    private func intake(_ nutrient: String, _ sex: ReferenceSex, _ band: ReferenceAgeBand) throws -> ReferenceIntake {
        try XCTUnwrap(ReferenceIntakes.intake(for: nutrient, group: group(sex, band)), "no row for \(nutrient)")
    }

    func testMagnesiumStepsUpAtThirtyOneAndItsLimitCountsOnlySupplements() throws {
        XCTAssertEqual(try intake("magnesium", .female, .years19To30).amount, 310)
        XCTAssertEqual(try intake("magnesium", .female, .years31To50).amount, 320)
        XCTAssertEqual(try intake("magnesium", .male, .years19To30).amount, 400)
        XCTAssertEqual(try intake("magnesium", .male, .years51To70).amount, 420)
        let limit = try intake("magnesium", .male, .years31To50)
        XCTAssertEqual(limit.unit, .mg)
        XCTAssertEqual(limit.kind, .recommendedDietaryAllowance)
        // Below the men's allowance, which is only coherent because it counts supplements alone.
        XCTAssertEqual(limit.upperLimit, 350)
        XCTAssertEqual(limit.upperLimitScope, .supplementsAndMedicines)
    }

    func testVitaminDRisesAtSeventyOne() throws {
        XCTAssertEqual(try intake("vitaminD", .female, .years51To70).amount, 15)
        XCTAssertEqual(try intake("vitaminD", .male, .years71Plus).amount, 20)
        XCTAssertEqual(try intake("vitaminD", .male, .years71Plus).unit, .mcg)
        XCTAssertEqual(try intake("vitaminD", .female, .years19To30).upperLimit, 100)
    }

    func testCalciumDiffersBySexBetweenFiftyOneAndSeventyAndItsLimitDropsAtFiftyOne() throws {
        XCTAssertEqual(try intake("calcium", .female, .years51To70).amount, 1200)
        XCTAssertEqual(try intake("calcium", .male, .years51To70).amount, 1000)
        XCTAssertEqual(try intake("calcium", .male, .years71Plus).amount, 1200)
        XCTAssertEqual(try intake("calcium", .female, .years31To50).upperLimit, 2500)
        XCTAssertEqual(try intake("calcium", .female, .years51To70).upperLimit, 2000)
        XCTAssertEqual(try intake("calcium", .female, .years51To70).upperLimitScope, .allSources)
    }

    func testIronDropsForWomenAtFiftyOne() throws {
        XCTAssertEqual(try intake("iron", .female, .years31To50).amount, 18)
        XCTAssertEqual(try intake("iron", .female, .years51To70).amount, 8)
        XCTAssertEqual(try intake("iron", .male, .years19To30).amount, 8)
        XCTAssertEqual(try intake("iron", .male, .years19To30).upperLimit, 45)
    }

    func testPhosphorusLimitDropsAtSeventyOne() throws {
        XCTAssertEqual(try intake("phosphorus", .female, .years51To70).upperLimit, 4000)
        XCTAssertEqual(try intake("phosphorus", .female, .years71Plus).upperLimit, 3000)
    }

    func testFractionalValuesAreExactDecimals() throws {
        XCTAssertEqual(try intake("copper", .female, .years19To30).amount, try dec("0.9"))
        XCTAssertEqual(try intake("copper", .female, .years19To30).unit, .mg)
        XCTAssertEqual(try intake("copper", .female, .years19To30).upperLimit, 10)
        XCTAssertEqual(try intake("vitaminB6", .male, .years51To70).amount, try dec("1.7"))
        XCTAssertEqual(try intake("vitaminB6", .female, .years51To70).amount, try dec("1.5"))
        XCTAssertEqual(try intake("vitaminB12", .male, .years31To50).amount, try dec("2.4"))
        XCTAssertEqual(try intake("manganese", .male, .years31To50).amount, try dec("2.3"))
    }

    func testFormSpecificLimitsCarryTheirScope() throws {
        XCTAssertEqual(try intake("vitaminA", .female, .years19To30).upperLimitScope, .preformedVitaminA)
        XCTAssertEqual(try intake("niacin", .male, .years19To30).upperLimitScope, .supplementsAndFortifiedFoods)
        XCTAssertEqual(try intake("vitaminE", .male, .years19To30).upperLimitScope, .supplementsAndFortifiedFoods)
        // 1,000 mcg of folic acid, kept on its own basis rather than restated as DFE, so a label stating
        // 1,200 mcg of plain folic acid is above it rather than below a DFE figure.
        XCTAssertEqual(try intake("folate", .male, .years19To30).upperLimitScope, .folicAcid)
        XCTAssertEqual(try intake("folate", .male, .years19To30).upperLimit, 1000)
        XCTAssertEqual(try intake("folate", .male, .years19To30).amount, 400)
        XCTAssertEqual(try intake("zinc", .male, .years19To30).upperLimitScope, .allSources)
    }

    func testAdequateIntakesAreMarkedAsSuch() throws {
        for nutrient in ["vitaminK", "biotin", "pantothenicAcid", "potassium", "chromium", "manganese"] {
            XCTAssertEqual(try intake(nutrient, .female, .years31To50).kind, .adequateIntake, nutrient)
        }
        XCTAssertEqual(try intake("potassium", .female, .years31To50).amount, 2600)
        XCTAssertEqual(try intake("potassium", .male, .years31To50).amount, 3400)
        XCTAssertEqual(try intake("chromium", .female, .years51To70).amount, 20)
    }

    func testANutrientWithNoDeterminedLimitHasNoneRatherThanZero() throws {
        for nutrient in ["vitaminB12", "vitaminK", "thiamin", "riboflavin", "biotin", "pantothenicAcid", "potassium", "chromium"] {
            let value = try intake(nutrient, .male, .years19To30)
            XCTAssertNil(value.upperLimit, nutrient)
            XCTAssertNil(value.upperLimitScope, nutrient)
        }
    }

    func testEveryGroupHasEveryNutrientWithAPositiveAmount() {
        let keys = ReferenceIntakes.nutrients
        XCTAssertEqual(Set(keys).count, keys.count, "a nutrient is listed twice")
        XCTAssertEqual(keys.count, 25)
        XCTAssertEqual(ReferenceGroup.all.count, 12)
        for group in ReferenceGroup.all {
            let intakes = ReferenceIntakes.intakes(for: group)
            XCTAssertEqual(intakes.map(\.nutrient), keys)
            for value in intakes {
                XCTAssertGreaterThan(value.amount, 0, "\(value.nutrient) for \(group.label)")
                XCTAssertEqual(value.upperLimit == nil, value.upperLimitScope == nil, value.nutrient)
                // A limit on everything eaten sits above the amount recommended; a limit on supplements
                // alone need not (magnesium), so only the all-sources ones are held to it.
                if let limit = value.upperLimit, value.upperLimitScope == .allSources {
                    XCTAssertGreaterThan(limit, value.amount, "\(value.nutrient) for \(group.label)")
                }
            }
        }
    }

    func testKeysTheTableDoesNotCoverAnswerNil() {
        let anyone = ReferenceGroup(sex: .female, ageBand: .years19To30)
        XCTAssertNil(ReferenceIntakes.intake(for: "sodium", group: anyone))
        XCTAssertNil(ReferenceIntakes.intake(for: "chloride", group: anyone))
        XCTAssertNil(ReferenceIntakes.intake(for: "protein", group: anyone))
        XCTAssertNil(ReferenceIntakes.intake(for: "vitamin-d", group: anyone))
    }

    func testAgeBandsBreakAtThirtyOneFiftyOneAndSeventyOneAndStartAtNineteen() {
        XCTAssertEqual(ReferenceAgeBand(ageYears: 18), .years14To18)
        XCTAssertNil(ReferenceAgeBand(ageYears: 13))
        XCTAssertEqual(ReferenceAgeBand(ageYears: 19), .years19To30)
        XCTAssertEqual(ReferenceAgeBand(ageYears: 30), .years19To30)
        XCTAssertEqual(ReferenceAgeBand(ageYears: 31), .years31To50)
        XCTAssertEqual(ReferenceAgeBand(ageYears: 50), .years31To50)
        XCTAssertEqual(ReferenceAgeBand(ageYears: 51), .years51To70)
        XCTAssertEqual(ReferenceAgeBand(ageYears: 70), .years51To70)
        XCTAssertEqual(ReferenceAgeBand(ageYears: 71), .years71Plus)
        XCTAssertEqual(ReferenceAgeBand(ageYears: 104), .years71Plus)
    }

    func testGroupLabelsReadAsWords() {
        XCTAssertEqual(ReferenceGroup(sex: .female, ageBand: .years19To30).label, "Women 19 to 30")
        XCTAssertEqual(ReferenceGroup(sex: .male, ageBand: .years71Plus).label, "Men 71 and over")
    }

    // MARK: Pregnancy and breastfeeding

    private func stage(_ stage: ReferenceLifeStage, _ band: ReferenceAgeBand) throws -> ReferenceGroup {
        try XCTUnwrap(ReferenceGroup(lifeStage: stage, ageBand: band))
    }

    func testPregnancyRowsCarryTheirOwnValues() throws {
        let pregnant = try stage(.pregnancy, .years19To30)
        XCTAssertEqual(ReferenceIntakes.intake(for: "iron", group: pregnant)?.amount, 27)
        XCTAssertEqual(ReferenceIntakes.intake(for: "folate", group: pregnant)?.amount, 600)
        XCTAssertEqual(ReferenceIntakes.intake(for: "iodine", group: pregnant)?.amount, 220)
        XCTAssertEqual(ReferenceIntakes.intake(for: "magnesium", group: pregnant)?.amount, 350)
        XCTAssertEqual(ReferenceIntakes.intake(for: "magnesium", group: try stage(.pregnancy, .years31To50))?.amount, 360)
        XCTAssertEqual(ReferenceIntakes.intake(for: "copper", group: pregnant)?.amount, try dec("1.0"))
        XCTAssertEqual(ReferenceIntakes.intake(for: "vitaminB6", group: pregnant)?.amount, try dec("1.9"))
        // The one limit the tables set differently in pregnancy: phosphorus, 3,500 mg instead of 4,000.
        XCTAssertEqual(ReferenceIntakes.intake(for: "phosphorus", group: pregnant)?.upperLimit, 3500)
        XCTAssertEqual(ReferenceIntakes.intake(for: "iron", group: pregnant)?.upperLimit, 45)
        XCTAssertEqual(ReferenceIntakes.intake(for: "folate", group: pregnant)?.upperLimitScope, .folicAcid)
    }

    func testBreastfeedingRowsCarryTheirOwnValues() throws {
        let nursing = try stage(.lactation, .years31To50)
        XCTAssertEqual(ReferenceIntakes.intake(for: "vitaminA", group: nursing)?.amount, 1300)
        XCTAssertEqual(ReferenceIntakes.intake(for: "iodine", group: nursing)?.amount, 290)
        XCTAssertEqual(ReferenceIntakes.intake(for: "iron", group: nursing)?.amount, 9)
        XCTAssertEqual(ReferenceIntakes.intake(for: "magnesium", group: nursing)?.amount, 320)
        XCTAssertEqual(ReferenceIntakes.intake(for: "chromium", group: nursing)?.amount, 45)
        XCTAssertEqual(ReferenceIntakes.intake(for: "phosphorus", group: nursing)?.upperLimit, 4000)
    }

    func testPregnancyAndBreastfeedingArePublishedOnlyFor19To50() {
        XCTAssertNil(ReferenceGroup(lifeStage: .pregnancy, ageBand: .years51To70))
        XCTAssertNil(ReferenceGroup(lifeStage: .lactation, ageBand: .years71Plus))
        XCTAssertNil(ReferenceGroup(lifeStage: .standard, ageBand: .years19To30))
        XCTAssertEqual(ReferenceGroup(lifeStage: .pregnancy, ageBand: .years31To50)?.sex, .female)
    }

    func testTheNewGroupsReadAsWordsAndComeLastInThePicker() {
        XCTAssertEqual(ReferenceGroup.all.suffix(4).map(\.label), [
            "Pregnancy 19 to 30", "Pregnancy 31 to 50", "Breastfeeding 19 to 30", "Breastfeeding 31 to 50",
        ])
        XCTAssertEqual(Set(ReferenceGroup.all).count, ReferenceGroup.all.count)
    }

    func testADecodedGroupCannotNameARowThatIsNotPublished() throws {
        let decoder = JSONDecoder()
        func decode(_ json: String) -> ReferenceGroup? {
            try? decoder.decode(ReferenceGroup.self, from: Data(json.utf8))
        }
        XCTAssertEqual(
            decode(#"{"sex":"female","ageBand":"years19To30","lifeStage":"pregnancy"}"#),
            ReferenceGroup(lifeStage: .pregnancy, ageBand: .years19To30))
        XCTAssertEqual(
            decode(#"{"sex":"male","ageBand":"years31To50"}"#), ReferenceGroup(sex: .male, ageBand: .years31To50))
        XCTAssertNil(decode(#"{"sex":"male","ageBand":"years19To30","lifeStage":"pregnancy"}"#))
        XCTAssertNil(decode(#"{"sex":"female","ageBand":"years51To70","lifeStage":"lactation"}"#))
        let encoded = try JSONEncoder().encode(try stage(.lactation, .years19To30))
        XCTAssertEqual(try decoder.decode(ReferenceGroup.self, from: encoded), try stage(.lactation, .years19To30))
    }
}
