import XCTest
@testable import NutritionUI

/// The Trends row detail for vitamins and minerals does not repeat the row title (#537).
final class TrendsRowWordingTests: XCTestCase {
    func testVitaminsAndMineralsDetailDoesNotRepeatTheTitle() {
        XCTAssertEqual(TrendsView.vitaminsDetail, "Compared with published reference values")
    }
}
