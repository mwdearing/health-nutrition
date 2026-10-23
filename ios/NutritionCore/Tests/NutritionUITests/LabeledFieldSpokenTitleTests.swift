import XCTest
@testable import NutritionUI

/// A LabeledField's title is its content's spoken name only where a site opts in.
final class LabeledFieldSpokenTitleTests: XCTestCase {
    func testTheTitleIsNotSpokenUnlessASiteOptsIn() {
        XCTAssertFalse(LabeledFieldSpokenTitle.applies(false))
    }

    func testAnOptedInSiteSpeaksItsTitle() {
        XCTAssertTrue(LabeledFieldSpokenTitle.applies(true))
    }
}
