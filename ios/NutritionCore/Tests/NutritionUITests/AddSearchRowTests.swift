import XCTest
@testable import NutritionUI

final class AddSearchRowTests: XCTestCase {
    /// Guards the wording only. Whether the row renders and takes focus is not checked here.
    /// The row's visible text and its spoken label come from one constant, so a rename cannot leave
    /// the spoken label behind (the label-in-name rule).
    func testSearchRowTitleConstantHasTheShippedWording() {
        XCTAssertEqual(AddHomeView.searchRowTitle, "Search foods")
    }
}
