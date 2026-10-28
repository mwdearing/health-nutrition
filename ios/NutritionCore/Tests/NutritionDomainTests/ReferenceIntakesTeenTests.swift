import Foundation
import XCTest
@testable import NutritionDomain

/// The published 14 to 18 rows. Goal setup accepts 18, so an 18-year-old needs a row; the values are the
/// NIH ODS fact sheet tables' 14 to 18 rows, checked here by hand against those tables.
final class ReferenceIntakesTeenTests: XCTestCase {
    private let women = ReferenceGroup(sex: .female, ageBand: .years14To18)
    private let men = ReferenceGroup(sex: .male, ageBand: .years14To18)

    func testAges14Through18FallInTheTeenBandAndYoungerInNone() {
        XCTAssertNil(ReferenceAgeBand(ageYears: 13))
        XCTAssertEqual(ReferenceAgeBand(ageYears: 14), .years14To18)
        XCTAssertEqual(ReferenceAgeBand(ageYears: 18), .years14To18)
        XCTAssertEqual(ReferenceAgeBand(ageYears: 19), .years19To30)
    }

    /// Iron is the clearest split: women 15 mg, men 11 mg, pregnancy 27 mg, lactation 10 mg, UL 45 mg.
    func testIronFollowsTheTeenRows() throws {
        XCTAssertEqual(ReferenceIntakes.intake(for: "iron", group: women)?.amount, 15)
        XCTAssertEqual(ReferenceIntakes.intake(for: "iron", group: men)?.amount, 11)
        XCTAssertEqual(ReferenceIntakes.intake(for: "iron", group: women)?.upperLimit, 45)
        let pregnancy = try XCTUnwrap(ReferenceGroup(lifeStage: .pregnancy, ageBand: .years14To18))
        let lactation = try XCTUnwrap(ReferenceGroup(lifeStage: .lactation, ageBand: .years14To18))
        XCTAssertEqual(ReferenceIntakes.intake(for: "iron", group: pregnancy)?.amount, 27)
        XCTAssertEqual(ReferenceIntakes.intake(for: "iron", group: lactation)?.amount, 10)
    }

    /// Values that differ from the adult rows, so a teen group can't be reading an adult column.
    func testTeenValuesDifferFromTheAdultOnes() {
        XCTAssertEqual(ReferenceIntakes.intake(for: "vitaminC", group: women)?.amount, 65)
        XCTAssertEqual(ReferenceIntakes.intake(for: "vitaminC", group: men)?.amount, 75)
        XCTAssertEqual(ReferenceIntakes.intake(for: "vitaminC", group: men)?.upperLimit, 1800)
        XCTAssertEqual(ReferenceIntakes.intake(for: "zinc", group: women)?.amount, 9)
        XCTAssertEqual(ReferenceIntakes.intake(for: "zinc", group: men)?.upperLimit, 34)
        XCTAssertEqual(ReferenceIntakes.intake(for: "magnesium", group: men)?.amount, 410)
        XCTAssertEqual(ReferenceIntakes.intake(for: "phosphorus", group: women)?.amount, 1250)
        XCTAssertEqual(ReferenceIntakes.intake(for: "calcium", group: men)?.amount, 1300)
        XCTAssertEqual(ReferenceIntakes.intake(for: "calcium", group: men)?.upperLimit, 3000)
    }

    /// Copper is restated in mg like the adult rows: 890 mcg is 0.89 mg, and the 8,000 mcg UL is 8 mg.
    func testCopperIsHeldInMilligrams() {
        let copper = ReferenceIntakes.intake(for: "copper", group: women)
        XCTAssertEqual(copper?.amount, Decimal(string: "0.89", locale: Locale(identifier: "en_US_POSIX")))
        XCTAssertEqual(copper?.unit, .mg)
        XCTAssertEqual(copper?.upperLimit, 8)
    }

    /// The limits keep their adult scopes, and phosphorus keeps its lower pregnancy limit.
    func testLimitsKeepTheirScopes() throws {
        XCTAssertEqual(ReferenceIntakes.intake(for: "magnesium", group: men)?.upperLimit, 350)
        XCTAssertEqual(ReferenceIntakes.intake(for: "magnesium", group: men)?.upperLimitScope, .supplementsAndMedicines)
        XCTAssertEqual(ReferenceIntakes.intake(for: "folate", group: women)?.upperLimit, 800)
        XCTAssertEqual(ReferenceIntakes.intake(for: "folate", group: women)?.upperLimitScope, .folicAcid)
        let pregnancy = try XCTUnwrap(ReferenceGroup(lifeStage: .pregnancy, ageBand: .years14To18))
        XCTAssertEqual(ReferenceIntakes.intake(for: "phosphorus", group: pregnancy)?.upperLimit, 3500)
        XCTAssertEqual(ReferenceIntakes.intake(for: "phosphorus", group: men)?.upperLimit, 4000)
        XCTAssertNil(ReferenceIntakes.intake(for: "vitaminK", group: men)?.upperLimit)
    }

    /// Every nutrient in the table has a 14 to 18 value for every 14 to 18 group.
    func testEveryNutrientHasATeenValueForEveryTeenGroup() throws {
        let groups = [
            women, men,
            try XCTUnwrap(ReferenceGroup(lifeStage: .pregnancy, ageBand: .years14To18)),
            try XCTUnwrap(ReferenceGroup(lifeStage: .lactation, ageBand: .years14To18)),
        ]
        for group in groups {
            XCTAssertEqual(ReferenceIntakes.intakes(for: group).count, ReferenceIntakes.nutrients.count, group.label)
            for intake in ReferenceIntakes.intakes(for: group) {
                XCTAssertGreaterThan(intake.amount, 0, "\(intake.nutrient) for \(group.label)")
            }
        }
    }

    /// The picker lists the adult groups only until the 14 to 18 wording is approved; the band is reached by
    /// age.
    func testThePickerListStaysAdultOnly() {
        XCTAssertEqual(ReferenceGroup.all.count, 12)
        XCTAssertFalse(ReferenceGroup.all.contains { $0.ageBand == .years14To18 })
    }
}
