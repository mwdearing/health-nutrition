import NutritionDomain
import NutritionProviders
import XCTest

@testable import NutritionUI

/// The sharing review and the current shared product are read by a person, so they use words, never stored keys.
final class CustomProductSharingWordsTests: XCTestCase {
    func testABasisReadsInWordsNotItsStoredKey() {
        XCTAssertEqual(CustomProductSharingSection.basisText(.per100g), "per 100 g")
        XCTAssertEqual(CustomProductSharingSection.basisText(.per100mL), "per 100 mL")
        XCTAssertEqual(CustomProductSharingSection.basisText(.perServing), "per serving")
    }

    func testAFactWithoutAnAmountReadsInWords() {
        XCTAssertEqual(CustomProductSharingSection.factStateText(.unknown), "Unknown")
        XCTAssertEqual(CustomProductSharingSection.factStateText(.notApplicable), "Not applicable")
        XCTAssertEqual(
            CustomProductSharingSection.factStateText(.belowReportingThreshold), "Below reporting threshold")
    }

    func testAContributionStateReadsInWords() {
        XCTAssertEqual(CustomProductSharingSection.contributionText(.active), "shared")
        XCTAssertEqual(CustomProductSharingSection.contributionText(.withdrawn), "removed")
        XCTAssertEqual(CustomProductSharingSection.contributionText(.rejected), "rejected")
        XCTAssertEqual(CustomProductSharingSection.contributionText(.none), "none")
    }

    func testNoWordingShowsAStoredKey() {
        for basis in [ProductBasis.per100g, .per100mL, .perServing] {
            XCTAssertFalse(CustomProductSharingSection.basisText(basis).contains("_"), "\(basis) shows its stored key")
        }
        for state in [ProductFactState.known, .unknown, .notApplicable, .belowReportingThreshold] {
            XCTAssertFalse(CustomProductSharingSection.factStateText(state).contains("_"), "\(state) shows its stored key")
        }
    }
}
