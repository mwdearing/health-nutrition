import XCTest
@testable import NutritionProviders

final class CommunityLabelTests: XCTestCase {
    func testLegacyInitializerCannotMarkCommunityLabelVerified() {
        let label = CommunityLabel(
            barcode: "00000000", basis: .per100g, servingText: nil,
            productName: "Synthetic", brand: nil, nutrients: [:],
            verified: true, supportingAccounts: 8)

        XCTAssertEqual(label.verificationSource, .community)
        XCTAssertFalse(label.verified)
        XCTAssertEqual(label.supportingAccounts, 8)
    }

    func testOwnerReviewedInitializerOverridesLegacyBitAndSupportCount() {
        let label = CommunityLabel(
            barcode: "00000000", basis: .per100g, servingText: nil,
            productName: "Synthetic", brand: nil, nutrients: [:],
            verified: false, supportingAccounts: 8, verificationSource: .ownerReviewed)

        XCTAssertEqual(label.verificationSource, .ownerReviewed)
        XCTAssertTrue(label.verified)
        XCTAssertEqual(label.supportingAccounts, 0)
    }
}
