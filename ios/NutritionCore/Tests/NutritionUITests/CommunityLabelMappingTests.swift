import NutritionDomain
import NutritionProviders
import XCTest
@testable import NutritionUI

@MainActor
final class CommunityLabelMappingTests: XCTestCase {
    private let barcode = "4006381333931"
    private let nutrients: [String: Decimal] = [
        "energyKcal": 120, "protein": 2, "carbohydrates": 15, "sugars": 6, "fat": 3,
        "saturatedFat": 1.5, "fiber": 1, "sodium": 0.2, "salt": 0.5,
    ]

    private func label(
        _ basis: CommunityBasis, servingText: String? = nil, verified: Bool = true, accounts: Int = 2,
        nutrients: [String: Decimal]? = nil
    ) -> CommunityLabel {
        CommunityLabel(
            barcode: barcode, basis: basis, servingText: servingText, productName: "Community bar",
            brand: "Acme", nutrients: nutrients ?? self.nutrients, verified: verified, supportingAccounts: accounts)
    }

    func testPerHundredGramLabelMapsToPer100gBasisAndName() throws {
        let product = try XCTUnwrap(CommunityLabelMapping.product(barcode: barcode, labels: [label(.per100g)]))

        XCTAssertEqual(product.basis, .per100g)
        XCTAssertEqual(product.name, "Community bar")
        XCTAssertEqual(product.brand, "Acme")
        XCTAssertEqual(product.barcode, barcode)
        XCTAssertNil(product.serving)
    }

    func testEnergyIsKcalSodiumIsMilligramsAndTheRestAreGrams() throws {
        let product = try XCTUnwrap(CommunityLabelMapping.product(barcode: barcode, labels: [label(.per100g)]))

        XCTAssertEqual(product.value(for: LookedUpProduct.energyKcal), .known(120, .kcal))
        XCTAssertEqual(product.value(for: LookedUpProduct.sodium), .known(0.2, .mg))
        XCTAssertEqual(product.value(for: LookedUpProduct.protein), .known(2, .g))
        XCTAssertEqual(product.value(for: LookedUpProduct.salt), .known(0.5, .g))
    }

    func testPrefersPer100gThenPer100mlThenPerServing() throws {
        let serving = label(.perServing, servingText: "1 bar")
        let milliliters = label(.per100ml)
        let grams = label(.per100g)

        let all = try XCTUnwrap(CommunityLabelMapping.product(barcode: barcode, labels: [serving, milliliters, grams]))
        let noGrams = try XCTUnwrap(CommunityLabelMapping.product(barcode: barcode, labels: [serving, milliliters]))

        XCTAssertEqual(all.basis, .per100g)
        XCTAssertEqual(noGrams.basis, .per100ml)
    }

    func testPerServingLabelCarriesItsServingText() throws {
        let product = try XCTUnwrap(
            CommunityLabelMapping.product(barcode: barcode, labels: [label(.perServing, servingText: "1 bar")]))

        XCTAssertEqual(product.basis, .perServing)
        XCTAssertEqual(product.serving?.label, "1 bar")
    }

    func testUnknownNutrientKeysAreDropped() throws {
        var given = nutrients
        given["cholesterol"] = 10
        given["vitaminD"] = 3
        let product = try XCTUnwrap(
            CommunityLabelMapping.product(barcode: barcode, labels: [label(.per100g, nutrients: given)]))

        XCTAssertTrue(Set(product.nutrients.keys).isSubset(of: Set(LookedUpProduct.standardKeys)))
        XCTAssertNil(product.nutrients["cholesterol"])
    }

    func testANutrientTheLabelLacksIsUnknownNotZero() throws {
        var given = nutrients
        given["salt"] = nil
        let product = try XCTUnwrap(
            CommunityLabelMapping.product(barcode: barcode, labels: [label(.per100g, nutrients: given)]))

        XCTAssertEqual(product.value(for: LookedUpProduct.salt), .unknown)
    }

    func testVerifiedAttributionSaysHowManyPeopleAgree() throws {
        let product = try XCTUnwrap(
            CommunityLabelMapping.product(barcode: barcode, labels: [label(.per100g, verified: true, accounts: 5)]))

        XCTAssertEqual(
            product.attribution?.text, "Verified by the community: 5 people agree on these values.")
    }

    func testUnverifiedAttributionSaysTheValuesAreNotYetVerified() throws {
        let product = try XCTUnwrap(
            CommunityLabelMapping.product(barcode: barcode, labels: [label(.per100g, verified: false, accounts: 2)]))

        XCTAssertEqual(product.attribution?.text, "Shared by the community, not yet verified: 2 people agree.")
    }

    func testASingleAgreementReadsAsOnePerson() {
        let attribution = CommunityLabelMapping.attribution(verified: false, supportingAccounts: 1)

        XCTAssertEqual(attribution.text, "Shared by the community, not yet verified: 1 person agrees.")
    }

    func testAttributionNamesTheCommunitySourceAndHasNoLink() throws {
        let product = try XCTUnwrap(CommunityLabelMapping.product(barcode: barcode, labels: [label(.per100g)]))

        XCTAssertEqual(product.attribution?.source, "community")
        XCTAssertEqual(product.attribution?.url, "")
    }

    func testNoLabelsMapsToNothing() {
        XCTAssertNil(CommunityLabelMapping.product(barcode: barcode, labels: []))
    }
}
