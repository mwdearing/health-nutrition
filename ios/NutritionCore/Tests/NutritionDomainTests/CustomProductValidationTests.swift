import Foundation
import XCTest
@testable import NutritionDomain

final class CustomProductValidationTests: XCTestCase {
    private func product(_ facts: [ProductFact] = [], basis: ProductBasis = .per100g, serving: ProductServing? = nil, name: String = "Synthetic oats") -> CustomProductContent {
        CustomProductContent(name: name, kind: .food, basis: basis, serving: serving, facts: facts)
    }
    private func fact(_ key: String = "protein", _ value: NutrientValue = .known(0, .g)) -> ProductFact {
        ProductFact(key: key, displayName: "Synthetic fact", value: value)
    }
    func testNameOnlyAndFactStates() throws {
        XCTAssertNoThrow(try CustomProductValidation.validate(product()))
        XCTAssertNotEqual(NutrientValue.known(0, .g), .unknown)
        let threshold = fact("ingredient:custom", .belowReportingThreshold(.iu))
        XCTAssertNoThrow(try CustomProductValidation.validate(product([threshold, fact("ingredient:absent", .unknown), fact("ingredient:na", .notApplicable)])))
        XCTAssertEqual(threshold.value, .belowReportingThreshold(.iu))
    }
    func testBoundsAndServing() throws {
        let facts = (0..<64).map { fact("ingredient:custom\($0)") }
        XCTAssertNoThrow(try CustomProductValidation.validate(product(facts)))
        XCTAssertThrowsError(try CustomProductValidation.validate(product(facts + [fact("ingredient:extra")])))
        XCTAssertNoThrow(try CustomProductValidation.validate(product([fact("ingredient:x", .known(1_000_000_000, .g))])))
        for amount in ["1000000000.000001", "0.0000001", "-1"] {
            XCTAssertThrowsError(try CustomProductValidation.validate(product([fact("ingredient:x", .known(Decimal(string: amount)!, .g))])))
        }
        XCTAssertNoThrow(try CustomProductValidation.validate(product([fact("ingredient:x", .known(Decimal(string: "0.123456")!, .g))])))
        XCTAssertThrowsError(try CustomProductValidation.validate(product([fact()], basis: .perServing)))
        XCTAssertNoThrow(try CustomProductValidation.validate(product([fact()], basis: .perServing, serving: .init(quantity: 2, unit: .capsule))))
        XCTAssertThrowsError(try CustomProductValidation.validate(product([fact(), fact()])))
        XCTAssertThrowsError(try CustomProductValidation.validate(product(name: " ")))
        XCTAssertNoThrow(try CustomProductValidation.validate(product(name: String(repeating: "🧪", count: 120))))
        XCTAssertThrowsError(try CustomProductValidation.validate(product(name: String(repeating: "🧪", count: 121))))
    }
    func testProductFactEqualityPreservesKeyScalars() {
        let composed = fact("ingredient:é", .unknown)
        let decomposed = fact("ingredient:e\u{0301}", .unknown)
        XCTAssertNotEqual(composed, decomposed)
        XCTAssertEqual(Set([composed, decomposed]).count, 2)
        XCTAssertNotEqual(product([composed]), product([decomposed]))
        XCTAssertEqual(Set([composed, composed]).count, 1)
    }
    func testFactKeyIdentityUsesUnnormalizedUTF8() throws {
        let composed = fact("ingredient:é", .unknown)
        let decomposed = fact("ingredient:e\u{0301}", .unknown)
        XCTAssertNoThrow(try CustomProductValidation.validate(product([composed, decomposed])))
        XCTAssertThrowsError(try CustomProductValidation.validate(product([composed, composed]))) { error in
            XCTAssertEqual(error as? CustomProductFieldError, .init(field: "facts[1].key", code: .duplicateKey))
        }
        XCTAssertNoThrow(try CustomProductValidation.validate(product([fact("ingredient:a\nb", .unknown)])))
    }
    func testNullScalarRejectedBeforeJSONBTransport() {
        let nul = "\u{0000}"
        let contents = [
            product(name: "Synthetic" + nul),
            CustomProductContent(name: "Synthetic", brand: "Brand" + nul, kind: .food, basis: .per100g),
            product(serving: .init(quantity: 1, unit: .g, text: "Serving" + nul)),
            product([fact("ingredient:synthetic" + nul, .unknown)]),
            product([ProductFact(key: "protein", displayName: "Protein" + nul, value: .unknown)]),
        ]
        for content in contents {
            XCTAssertThrowsError(try CustomProductValidation.validate(content))
        }
    }
    func testNFCDisplayBoundsKeepPublicContentValid() {
        let expanded = String(repeating: "\u{0344}", count: 61)
        XCTAssertThrowsError(try CustomProductValidation.validate(product(name: expanded)))
        XCTAssertThrowsError(try CustomProductValidation.validate(CustomProductContent(name: "Synthetic", brand: String(repeating: "\u{0344}", count: 41), kind: .food, basis: .per100g)))
        XCTAssertThrowsError(try CustomProductValidation.validate(product(serving: .init(quantity: 1, unit: .g, text: String(repeating: "\u{0344}", count: 41)))))
        XCTAssertThrowsError(try CustomProductValidation.validate(product([ProductFact(key: "protein", displayName: expanded, value: .unknown)])))
        XCTAssertNoThrow(try CustomProductValidation.validate(product([fact("ingredient:" + String(repeating: "\u{0344}", count: 53), .unknown)])))
    }
    func testBarcodeValidation() throws {
        for barcode in ["96385074", "036000291452", "0036000291452"] {
            XCTAssertNoThrow(try CustomProductValidation.validate(CustomProductContent(name: "Synthetic", barcode: barcode, kind: .food, basis: .per100g)))
        }
        for barcode in ["", "036000291453", "１２３４５６７８", "123", " 96385074"] {
            XCTAssertThrowsError(try CustomProductValidation.validate(CustomProductContent(name: "Synthetic", barcode: barcode, kind: .food, basis: .per100g)))
        }
    }
    func testUnsupportedDimensions() throws {
        XCTAssertThrowsError(try CustomProductValidation.validate(product([fact("unknownStandard")])))
        XCTAssertThrowsError(try MeasureUnit(symbol: "kJ"))
        XCTAssertThrowsError(try CustomProductValidation.validate(product([fact("protein", .known(1, .mL))])))
        XCTAssertThrowsError(try CustomProductValidation.validate(product([fact("energyKcal", .belowReportingThreshold(.g))])))
        XCTAssertNoThrow(try CustomProductValidation.validate(product([fact("ingredient:custom-IU", .known(2, .iu))])))
        XCTAssertThrowsError(try CustomProductValidation.validate(product(serving: .init(quantity: 1, unit: .kcal))))
    }
}
