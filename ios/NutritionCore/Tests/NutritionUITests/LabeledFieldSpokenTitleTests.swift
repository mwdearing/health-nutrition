import XCTest
@testable import NutritionUI

/// The opt-in rule only: `LabeledFieldSpokenTitle.applies` says whether a site's title becomes its content's spoken
/// name. These tests stay green if `LabeledField` stopped applying the label; that mechanism is covered by
/// QuickAddLabelUITests, which finds the Amounts only name field by its visible title (#686).
final class LabeledFieldSpokenTitleTests: XCTestCase {
    func testTheRuleLeavesTheTitleUnspokenUnlessASiteOptsIn() {
        XCTAssertFalse(LabeledFieldSpokenTitle.applies(false))
    }

    func testTheRuleSpeaksTheTitleOfAnOptedInSite() {
        XCTAssertTrue(LabeledFieldSpokenTitle.applies(true))
    }
}
