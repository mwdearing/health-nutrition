import XCTest
@testable import NutritionUI

/// The shared-products sign-in line: shown only in a build with an account, to a person who is signed out.
final class SearchSignInLineTests: XCTestCase {
    func testABuildWithNoAccountShowsNoSignInLine() {
        XCTAssertEqual(SearchSignIn.signedOutLine(hasAccount: false, signedIn: false), .none)
    }

    func testASignedOutPersonInABuildWithAnAccountIsOfferedSignIn() {
        XCTAssertEqual(SearchSignIn.signedOutLine(hasAccount: true, signedIn: false), .signInMessage)
    }

    func testASignedInPersonIsNeverShownTheSignInLine() {
        XCTAssertEqual(SearchSignIn.signedOutLine(hasAccount: true, signedIn: true), .none)
        XCTAssertEqual(SearchSignIn.signedOutLine(hasAccount: false, signedIn: true), .none)
    }

    func testNoAccountSignedOutHidesTheSharedProductsSection() {
        XCTAssertFalse(SearchSignIn.showsSharedProducts(state: .signInRequired, hasAccount: false, signedIn: false))
    }

    func testAnAccountSignedOutShowsTheSharedProductsSection() {
        XCTAssertTrue(SearchSignIn.showsSharedProducts(state: .signInRequired, hasAccount: true, signedIn: false))
    }

    func testAnyOtherStateShowsTheSharedProductsSection() {
        for state in [CommunityProductSearchState.idle, .queryTooShort, .loading, .loaded, .empty, .unsupported, .unavailable] {
            XCTAssertTrue(SearchSignIn.showsSharedProducts(state: state, hasAccount: false, signedIn: false), "\(state)")
        }
    }

    func testTheSearchFieldIsNamedSearchFoods() {
        XCTAssertEqual(CommunityProductSearchView.fieldLabel, "Search foods")
    }
}
