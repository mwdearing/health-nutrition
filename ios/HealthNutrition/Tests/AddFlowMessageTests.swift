import XCTest
@testable import HealthNutrition

final class AddFlowMessageTests: XCTestCase {
    /// The Library's product path reports this message on Add home. It must keep showing, so the
    /// picker's clear-on-leave must never remove it. This pins the wording the user sees.
    func testProductDetailsFailureKeepsItsWording() {
        XCTAssertEqual(AddFlowMessage.productDetailsFailed, "Could not open product details.")
    }
}
