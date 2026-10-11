import NutritionDomain
import NutritionProviders
import XCTest
@testable import NutritionUI

/// The catalog accepts only values inside fixed limits, so the app sends nothing outside them and reads
/// nothing outside them back.
@MainActor
final class CommunityLabelLimitsTests: XCTestCase {
    private func known(_ amount: Decimal, _ unit: MeasureUnit) -> NutrientValue { .known(amount, unit) }

    /// The catalog keeps at most three decimals, so a longer value is rounded before it is sent.
    func testUploadedValuesAreRoundedToThreeDecimals() throws {
        let values = CommunityLabelUpload.canonicalNutrients([
            "energyKcal": known(Decimal(string: "120.55555")!, .kcal),
            "protein": known(Decimal(string: "3.12345")!, .g),
            "fat": known(2, .g),
        ])
        XCTAssertEqual(values["energyKcal"], Decimal(string: "120.556")!)
        XCTAssertEqual(values["protein"], Decimal(string: "3.123")!)
        XCTAssertEqual(values["fat"], 2)
    }

    /// Milligrams of sodium arrive as grams from the label parser and are sent in milligrams.
    func testAValueConvertedToTheCatalogUnitIsAlsoRounded() throws {
        let values = CommunityLabelUpload.canonicalNutrients([
            "sodium": known(Decimal(string: "0.12345678")!, .g),
        ])
        XCTAssertEqual(values["sodium"], Decimal(string: "123.457")!)
    }

    /// A value outside the catalog's range would be refused whole, so it is left out of the upload.
    func testUploadedValuesOutsideTheCatalogRangeAreLeftOut() throws {
        let values = CommunityLabelUpload.canonicalNutrients([
            "energyKcal": known(9_001, .kcal),
            "protein": known(-1, .g),
            "fat": known(1_001, .g),
            "fiber": known(3, .g),
        ])
        XCTAssertEqual(values, ["fiber": 3])
    }

    func testFieldLengthsMatchTheCatalog() {
        XCTAssertTrue(CommunityLabelLimits.fits(name: String(repeating: "a", count: 120), brand: nil, serving: nil))
        XCTAssertFalse(CommunityLabelLimits.fits(name: String(repeating: "a", count: 121), brand: nil, serving: nil))
        XCTAssertFalse(CommunityLabelLimits.fits(name: "Oats", brand: String(repeating: "b", count: 81), serving: nil))
        XCTAssertFalse(CommunityLabelLimits.fits(name: "Oats", brand: nil, serving: String(repeating: "s", count: 81)))
        XCTAssertTrue(CommunityLabelLimits.fits(name: "Oats", brand: "Acme", serving: "1 cup"))
    }

    /// The catalog counts Unicode characters, not the grapheme clusters Swift's count gives, so a family emoji is
    /// several characters against the limit.
    func testLengthsAreCountedAsUnicodeScalarsLikeTheDatabase() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(family.count, 1)
        XCTAssertEqual(family.unicodeScalars.count, 5)
        // 24 families are 120 scalars, which fits; 25 are 125, which does not, though Swift counts 25 < 120.
        XCTAssertTrue(CommunityLabelLimits.fits(name: String(repeating: family, count: 24), brand: nil, serving: nil))
        XCTAssertFalse(CommunityLabelLimits.fits(name: String(repeating: family, count: 25), brand: nil, serving: nil))
    }

    /// Values read back from the catalog are held to the same range, so a bad row cannot reach the form.
    func testValuesReadBackOutsideTheRangeAreDropped() throws {
        let mapped = CommunityLabelMapping.nutrients([
            "energyKcal": 120, "protein": -5, "fat": 5_000, "sodium": 200_000, "fiber": 2,
        ])
        XCTAssertEqual(Set(mapped.keys), ["energyKcal", "fiber"])
    }

    func testLongNamesReadBackAreShortenedToTheCatalogLimit() throws {
        let label = CommunityLabel(
            barcode: "4006381333931", basis: .per100g, servingText: nil,
            productName: String(repeating: "n", count: 300), brand: String(repeating: "b", count: 300),
            nutrients: ["energyKcal": 100, "protein": 1, "fat": 1], verified: false, supportingAccounts: 2)
        let product = try XCTUnwrap(CommunityLabelMapping.product(barcode: "4006381333931", labels: [label]))
        XCTAssertEqual(product.name?.count, 120)
        XCTAssertEqual(product.brand?.count, 80)
    }
}
