import NutritionDomain
import NutritionProviders
import XCTest
@testable import NutritionUI

/// Stands in for the community catalog. It returns the labels it is given, or fails, and counts the calls.
private final class CatalogSpy: CommunityLabelLookup, @unchecked Sendable {
    private let labels: [CommunityLabel]
    private(set) var calls = 0

    init(labels: [CommunityLabel]) {
        self.labels = labels
    }

    func lookupLabel(barcode: String) async throws -> [CommunityLabel] {
        calls += 1
        return labels
    }
}

@MainActor
final class CatalogOnlyBarcodeLookupTests: XCTestCase {
    private let barcode = "4006381333931"

    private func label() -> CommunityLabel {
        CommunityLabel(
            barcode: barcode, basis: .per100g, servingText: nil, productName: "Community bar", brand: "Acme",
            nutrients: ["energyKcal": 52], verified: true, supportingAccounts: 2)
    }

    /// Signed out, the catalog is never asked and nothing is found: Open Food Facts is not a source here.
    func testSignedOutAsksNoCatalogAndFindsNothing() async {
        let catalog = CatalogSpy(labels: [label()])
        let lookup = CatalogOnlyBarcodeLookup.make(community: catalog, isSignedIn: { false })

        let result = await lookup.lookUp(barcode: barcode)

        XCTAssertEqual(result, .notFound)
        XCTAssertEqual(catalog.calls, 0)
    }

    /// Signed in, the catalog answers the barcode.
    func testSignedInFindsTheCatalogsProduct() async {
        let catalog = CatalogSpy(labels: [label()])
        let lookup = CatalogOnlyBarcodeLookup.make(community: catalog, isSignedIn: { true })

        let result = await lookup.lookUp(barcode: barcode)

        guard case .found(let product) = result else {
            return XCTFail("the catalog's product is not found: \(result)")
        }
        XCTAssertEqual(product.name, "Community bar")
        XCTAssertEqual(catalog.calls, 1)
    }

    /// Signed in, a barcode the catalog does not hold is not found. A source other than the catalog would answer here.
    func testSignedInWithNoCatalogProductIsNotFound() async {
        let catalog = CatalogSpy(labels: [])
        let lookup = CatalogOnlyBarcodeLookup.make(community: catalog, isSignedIn: { true })

        let result = await lookup.lookUp(barcode: barcode)

        XCTAssertEqual(result, .notFound)
        XCTAssertEqual(catalog.calls, 1)
    }

    /// Without a catalog configured there is nothing to ask, so the answer is not found.
    func testNoCatalogIsNotFound() async {
        let lookup = CatalogOnlyBarcodeLookup.make(community: nil, isSignedIn: nil)

        XCTAssertEqual(await lookup.lookUp(barcode: barcode), .notFound)
    }
}
