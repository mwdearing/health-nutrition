import Foundation
import NutritionDomain
import XCTest
@testable import NutritionProviders

final class StubTransport: OpenFoodFactsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let status: Int
    private let body: Data
    private let headers: [String: String]

    init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (body, response)
    }
}

private struct OversizedOpenFoodFactsTransport: OpenFoodFactsTransport {
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw BoundedResponseError.responseTooLarge
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date {
        lock.withLock { current }
    }

    func uptime() -> TimeInterval {
        lock.withLock { current.timeIntervalSince1970 - 1_800_000_000 + 5_000 }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

final class OpenFoodFactsClientTests: XCTestCase {
    private let foundCode = "2000000000015"

    private func dec(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    }

    /// The basis decision the product mapping uses, from the data-per and quantity-unit fields it is given.
    private func basis(quantityUnit: String?, per: String = "100g") throws -> OpenFoodFactsBasis {
        return OpenFoodFactsBasis.decide(dataPer: per, quantityUnit: quantityUnit)
    }

    func testBasisFromProductQuantityUnitOnly() throws {
        let powder = try basis(quantityUnit: "g")
        XCTAssertEqual(powder, .per100g)
        XCTAssertNotEqual(powder, .per100ml)
        let powderNoUnit = try basis(quantityUnit: nil)
        XCTAssertEqual(powderNoUnit, .per100Unspecified)
        XCTAssertNotEqual(powderNoUnit, .per100ml)
        let drink = try basis(quantityUnit: "ml")
        XCTAssertEqual(drink, .per100ml)
        let solid = try basis(quantityUnit: "g")
        XCTAssertEqual(solid, .per100g)
        let missing = try basis(quantityUnit: nil)
        XCTAssertEqual(missing, .per100Unspecified)
        let upper = try basis(quantityUnit: " ML ")
        XCTAssertEqual(upper, .per100ml)
        let other = try basis(quantityUnit: "oz")
        XCTAssertEqual(other, .per100Unspecified)
        let perServing = try basis(quantityUnit: "ml", per: "serving")
        XCTAssertEqual(perServing, .perServing)
    }

    func testInitializerFillsMissingStandardKeysWithUnknown() {
        let product = OpenFoodFactsProduct(
            barcode: foundCode, name: nil, brands: nil, servingSize: nil, servingQuantity: nil,
            basis: .per100Unspecified, lastModified: nil,
            nutrients: [OpenFoodFactsProduct.fat: .known(dec("2"), .g)]
        )
        XCTAssertEqual(product.nutrients.count, 9)
        for key in OpenFoodFactsProduct.standardKeys where key != OpenFoodFactsProduct.fat {
            XCTAssertEqual(product.nutrients[key], NutrientValue.unknown, key)
        }
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.fat], .known(dec("2"), .g))
    }

    func testValidCheckDigitsForEan8UpcAAndEan13() {
        XCTAssertTrue(BarcodeValidator.isValid("20000011"))
        XCTAssertTrue(BarcodeValidator.isValid("200000000011"))
        XCTAssertTrue(BarcodeValidator.isValid("2000000000015"))
        XCTAssertFalse(BarcodeValidator.isValid("2000000000014"))
    }

    func testAttributionNamesSourceAndLicense() {
        XCTAssertEqual(
            OpenFoodFactsAttribution.text,
            "Nutrition facts from Open Food Facts, available under the Open Database License (ODbL)."
        )
        XCTAssertEqual(OpenFoodFactsAttribution.url, "https://world.openfoodfacts.org")
    }

}

private struct ThrowingOpenFoodFactsTransport: OpenFoodFactsTransport {
    let error: URLError
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw error }
}
