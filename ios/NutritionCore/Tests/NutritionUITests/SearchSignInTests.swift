import XCTest
@testable import NutritionUI

final class SearchSignInTests: XCTestCase {
    func testABuildWithAnAccountPresentsSignInOverTheSearch() {
        XCTAssertEqual(SearchSignIn.choose(hasAccount: true), .presentOverSearch)
    }

    func testABuildWithoutAnAccountOffersNoSignIn() {
        XCTAssertEqual(SearchSignIn.choose(hasAccount: false), .unavailable)
    }
}
