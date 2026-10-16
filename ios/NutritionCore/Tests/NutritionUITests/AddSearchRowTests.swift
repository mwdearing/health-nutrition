import XCTest
@testable import NutritionUI

final class AddSearchRowTests: XCTestCase {
    /// The row's visible text and its spoken label come from one constant, so a rename cannot leave
    /// the spoken label behind (the label-in-name rule).
    func testSearchRowTitleIsTheVisibleText() {
        XCTAssertEqual(AddHomeView.searchRowTitle, "Search foods, brands, drinks")
    }
}
