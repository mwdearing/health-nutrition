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
}
