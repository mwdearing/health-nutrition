import NutritionDomain
import NutritionProviders
import XCTest
@testable import NutritionUI

/// Answers one fixed result and counts the calls, so a test can tell whether the catalog was asked at all.
private final class CountingBarcodeLookup: BarcodeProductLookup, @unchecked Sendable {
    private let result: BarcodeLookupResult
    private(set) var calls = 0

    init(result: BarcodeLookupResult) {
        self.result = result
    }

    func lookUp(barcode: String) async -> BarcodeLookupResult {
        calls += 1
        return result
    }
}

/// Stands in for the community catalog. It returns the labels it is given, or fails, and counts the calls.
private final class FakeCommunityLookup: CommunityLabelLookup, @unchecked Sendable {
    private let labels: [CommunityLabel]?
    private(set) var calls = 0

    /// Nil labels means the catalog call fails.
    init(labels: [CommunityLabel]?) {
        self.labels = labels
    }

    func lookupLabel(barcode: String) async throws -> [CommunityLabel] {
        calls += 1
        guard let labels else { throw CommunityError.network }
        return labels
    }
}

@MainActor
final class CommunityFallbackLookupTests: XCTestCase {
    private let barcode = "4006381333931"

    private func label(
        _ basis: CommunityBasis = .per100g, verified: Bool = true, accounts: Int = 2,
        nutrients: [String: Decimal] = ["energyKcal": 52, "fat": 0.2, "carbohydrates": 14, "sodium": 0.04]
    ) -> CommunityLabel {
        CommunityLabel(
            barcode: barcode, basis: basis, servingText: basis == .perServing ? "1 bar" : nil,
            productName: "Community bar", brand: "Acme", nutrients: nutrients,
            verified: verified, supportingAccounts: accounts)
    }

    private func notFound() -> BarcodeLookupResult { .notFound }

    func testPrimaryFoundPassesThroughWithoutAskingTheCatalog() async {
        let primary = CountingBarcodeLookup(result: .found(LookedUpProduct(
            barcode: barcode, name: "Primary", brand: nil, basis: .per100g, nutrients: [:])))
        let community = FakeCommunityLookup(labels: [label()])
        let lookup = CommunityFallbackLookup(primary: primary, community: community, isSignedIn: { true })

        let result = await lookup.lookUp(barcode: barcode)

        guard case .found(let product) = result else {
            return XCTFail("expected the primary product")
        }
        XCTAssertEqual(product.name, "Primary")
        XCTAssertEqual(community.calls, 0)
    }

    func testPrimaryNotFoundAsksTheCatalogWhenSignedIn() async {
        let primary = CountingBarcodeLookup(result: notFound())
        let community = FakeCommunityLookup(labels: [label()])
        let lookup = CommunityFallbackLookup(primary: primary, community: community, isSignedIn: { true })

        let result = await lookup.lookUp(barcode: barcode)

        XCTAssertEqual(community.calls, 1)
        guard case .found(let product) = result else {
            return XCTFail("expected a community product")
        }
        XCTAssertEqual(product.name, "Community bar")
    }

    func testSignedOutNeverAsksTheCatalog() async {
        let primary = CountingBarcodeLookup(result: notFound())
        let community = FakeCommunityLookup(labels: [label()])
        let lookup = CommunityFallbackLookup(primary: primary, community: community, isSignedIn: { false })

        let result = await lookup.lookUp(barcode: barcode)

        XCTAssertEqual(community.calls, 0)
        XCTAssertEqual(result, .notFound)
    }

    func testCatalogErrorBecomesNotFoundNotAFailure() async {
        let primary = CountingBarcodeLookup(result: notFound())
        let community = FakeCommunityLookup(labels: nil)
        let lookup = CommunityFallbackLookup(primary: primary, community: community, isSignedIn: { true })

        let result = await lookup.lookUp(barcode: barcode)

        XCTAssertEqual(community.calls, 1)
        XCTAssertEqual(result, .notFound)
    }

    func testEmptyCatalogAnswerIsNotFound() async {
        let primary = CountingBarcodeLookup(result: notFound())
        let community = FakeCommunityLookup(labels: [])
        let lookup = CommunityFallbackLookup(primary: primary, community: community, isSignedIn: { true })

        let result = await lookup.lookUp(barcode: barcode)

        XCTAssertEqual(result, .notFound)
    }

    func testRateLimitedPassesThroughWithoutAskingTheCatalog() async {
        let primary = CountingBarcodeLookup(result: .rateLimited(retryAfterSeconds: 30))
        let community = FakeCommunityLookup(labels: [label()])
        let lookup = CommunityFallbackLookup(primary: primary, community: community, isSignedIn: { true })

        let result = await lookup.lookUp(barcode: barcode)

        XCTAssertEqual(result, .rateLimited(retryAfterSeconds: 30))
        XCTAssertEqual(community.calls, 0)
    }

    func testFailedPassesThroughWithoutAskingTheCatalog() async {
        let primary = CountingBarcodeLookup(result: .failed("offline"))
        let community = FakeCommunityLookup(labels: [label()])
        let lookup = CommunityFallbackLookup(primary: primary, community: community, isSignedIn: { true })

        let result = await lookup.lookUp(barcode: barcode)

        XCTAssertEqual(result, .failed("offline"))
        XCTAssertEqual(community.calls, 0)
    }

    func testCatalogLabelWithNoStandardNutrientsIsNotFound() async {
        let primary = CountingBarcodeLookup(result: notFound())
        let community = FakeCommunityLookup(labels: [label(nutrients: ["cholesterol": 5])])
        let lookup = CommunityFallbackLookup(primary: primary, community: community, isSignedIn: { true })

        let result = await lookup.lookUp(barcode: barcode)

        XCTAssertEqual(result, .notFound)
    }
}
