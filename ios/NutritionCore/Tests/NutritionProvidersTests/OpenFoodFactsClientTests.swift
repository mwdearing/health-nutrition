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
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (body, response)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

final class OpenFoodFactsClientTests: XCTestCase {
    private let foundCode = "2000000000015"

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func dec(_ text: String) -> Decimal {
        Decimal(string: text, locale: nil)!
    }

    private func found(_ outcome: OpenFoodFactsOutcome, file: StaticString = #filePath, line: UInt = #line) throws -> OpenFoodFactsProduct {
        guard case .found(let product) = outcome else {
            XCTFail("expected found, got \(outcome)", file: file, line: line)
            throw URLError(.cannotParseResponse)
        }
        return product
    }

    private func client(_ transport: StubTransport, environment: OpenFoodFactsEnvironment = .production, clock: TestClock = TestClock()) -> OpenFoodFactsClient {
        OpenFoodFactsClient(environment: environment, transport: transport, appVersion: "1.0.0", now: { clock.now() })
    }

    func testFoundPer100g() async throws {
        let transport = StubTransport(body: try fixture("found_per_100g"))
        let product = try found(await client(transport).lookup(barcode: foundCode))
        XCTAssertEqual(product.barcode, foundCode)
        XCTAssertEqual(product.name, "Sample Oat Biscuit")
        XCTAssertEqual(product.brands, "Example Foods")
        XCTAssertEqual(product.servingSize, "30 g")
        XCTAssertEqual(product.servingQuantity, dec("30"))
        XCTAssertEqual(product.basis, .per100g)
        XCTAssertEqual(product.lastModified, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.energyKcal], .known(dec("450"), .kcal))
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.protein], .known(dec("7.5"), .g))
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.saturatedFat], .known(dec("8.4"), .g))
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.sodium], .known(dec("0.4"), .g))
    }

    func testFoundPerServingReadsServingValues() async throws {
        let json = """
        {"code":"2000000000015","status":"success","result":{"id":"product_found"},
         "product":{"code":"2000000000015","nutrition_data_per":"serving","serving_size":"1 biscuit",
          "nutriments":{"energy-kcal_100g":450,"energy-kcal_serving":135,"energy-kcal_unit":"kcal",
                        "fat_100g":18,"fat_serving":5.4,"fat_unit":"g"}}}
        """
        let transport = StubTransport(body: Data(json.utf8))
        let product = try found(await client(transport).lookup(barcode: foundCode))
        XCTAssertEqual(product.basis, .perServing)
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.energyKcal], .known(dec("135"), .kcal))
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.fat], .known(dec("5.4"), .g))
    }

    func testMissingNutrimentIsUnknownNotZero() async throws {
        let transport = StubTransport(body: try fixture("missing_nutriments"))
        let product = try found(await client(transport).lookup(barcode: "2000000001012"))
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.protein], .known(dec("3"), .g))
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.energyKcal], NutrientValue.unknown)
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.fat], NutrientValue.unknown)
        XCTAssertNotEqual(product.nutrients[OpenFoodFactsProduct.fat], .known(0, .g))
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.sugars], NutrientValue.unknown)
        // A value without a unit is not guessed.
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.sodium], NutrientValue.unknown)
        XCTAssertNil(product.servingQuantity)
    }

    func testUnknownUnitIsUnknown() async throws {
        let json = """
        {"code":"2000000000015","result":{"id":"product_found"},
         "product":{"nutriments":{"proteins_100g":5,"proteins_unit":"stone","sodium_100g":400,"sodium_unit":"mg",
                                  "fat_100g":3,"fat_unit":"kcal"}}}
        """
        let product = try found(await client(StubTransport(body: Data(json.utf8))).lookup(barcode: foundCode))
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.protein], NutrientValue.unknown)
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.sodium], .known(dec("400"), .mg))
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.fat], NutrientValue.unknown)
    }

    func testNotFoundByResultId() async throws {
        let transport = StubTransport(body: try fixture("not_found"))
        let outcome = await client(transport).lookup(barcode: "2000000000022")
        XCTAssertEqual(outcome, .notFound)
    }

    func testNotFoundByHttp404() async throws {
        let outcome = await client(StubTransport(status: 404, body: Data("{}".utf8))).lookup(barcode: foundCode)
        XCTAssertEqual(outcome, .notFound)
    }

    func testRateLimitedHttp429UsesRetryAfter() async throws {
        let transport = StubTransport(status: 429, headers: ["Retry-After": "30"])
        let outcome = await client(transport).lookup(barcode: foundCode)
        XCTAssertEqual(outcome, .rateLimited(retryAfter: 30))
    }

    func testRateLimitedHttp503WithoutRetryAfter() async throws {
        let outcome = await client(StubTransport(status: 503)).lookup(barcode: foundCode)
        XCTAssertEqual(outcome, .rateLimited(retryAfter: nil))
    }

    func testClientLimiterBlocksSixteenthLookupAndAllowsLater() async throws {
        let transport = StubTransport(body: try fixture("found_per_100g"))
        let clock = TestClock()
        let subject = client(transport, clock: clock)
        for _ in 0..<15 {
            let outcome = await subject.lookup(barcode: foundCode)
            guard case .found = outcome else {
                return XCTFail("expected found, got \(outcome)")
            }
            clock.advance(1)
        }
        XCTAssertEqual(transport.requests.count, 15)
        let blocked = await subject.lookup(barcode: foundCode)
        guard case .rateLimited(let retryAfter) = blocked else {
            return XCTFail("expected rateLimited, got \(blocked)")
        }
        XCTAssertNotNil(retryAfter)
        XCTAssertEqual(transport.requests.count, 15, "a blocked lookup must not reach the network")
        clock.advance(60)
        let later = await subject.lookup(barcode: foundCode)
        guard case .found = later else {
            return XCTFail("expected found after the window, got \(later)")
        }
        XCTAssertEqual(transport.requests.count, 16)
    }

    func testInvalidBarcodeLengthsMakeNoRequest() async throws {
        let transport = StubTransport()
        let subject = client(transport)
        for bad in ["", "2000", "200000011", "20000000000150", "abcdefgh", "2000000000O15", "\u{0662}0000011"] {
            let outcome = await subject.lookup(barcode: bad)
            XCTAssertEqual(outcome, .invalidBarcode, bad)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testWrongCheckDigitIsInvalidBarcodeWithoutRequest() async throws {
        let transport = StubTransport()
        let subject = client(transport)
        for bad in ["2000000000016", "200000000012", "20000012"] {
            let outcome = await subject.lookup(barcode: bad)
            XCTAssertEqual(outcome, .invalidBarcode, bad)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testValidCheckDigitsForEan8UpcAAndEan13() {
        XCTAssertTrue(BarcodeValidator.isValid("20000011"))
        XCTAssertTrue(BarcodeValidator.isValid("200000000011"))
        XCTAssertTrue(BarcodeValidator.isValid("2000000000015"))
        XCTAssertFalse(BarcodeValidator.isValid("2000000000014"))
    }

    func testRequestCarriesUserAgentAndFieldsQuery() async throws {
        let transport = StubTransport(body: try fixture("found_per_100g"))
        _ = await client(transport).lookup(barcode: foundCode)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"),
            "HealthNutrition/1.0.0 (https://github.com/mwdearing/health-nutrition/issues)"
        )
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "world.openfoodfacts.org")
        XCTAssertEqual(url.path, "/api/v3/product/\(foundCode)")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let fields = components.queryItems?.first { $0.name == "fields" }?.value
        XCTAssertEqual(
            fields,
            "code,product_name,brands,serving_size,serving_quantity,nutrition_data_per,nutriments,last_modified_t"
        )
        XCTAssertEqual(components.queryItems?.count, 1)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testStagingSendsBasicAuthOnlyOnStaging() async throws {
        let staging = StubTransport(body: try fixture("found_per_100g"))
        _ = await client(staging, environment: .staging).lookup(barcode: foundCode)
        let stagingRequest = try XCTUnwrap(staging.requests.first)
        XCTAssertEqual(stagingRequest.url?.host, "world.openfoodfacts.net")
        XCTAssertEqual(stagingRequest.value(forHTTPHeaderField: "Authorization"), "Basic b2ZmOm9mZg==")

        let production = StubTransport(body: try fixture("found_per_100g"))
        _ = await client(production, environment: .production).lookup(barcode: foundCode)
        XCTAssertNil(production.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testAttributionNamesSourceAndLicence() {
        XCTAssertEqual(
            OpenFoodFactsAttribution.text,
            "Nutrition facts from Open Food Facts, available under the Open Database License (ODbL)."
        )
        XCTAssertEqual(OpenFoodFactsAttribution.url, "https://world.openfoodfacts.org")
    }

    func testUnreadableResponseIsTransportOutcome() async throws {
        let outcome = await client(StubTransport(body: Data("not json".utf8))).lookup(barcode: foundCode)
        guard case .transport = outcome else {
            return XCTFail("expected transport, got \(outcome)")
        }
    }
}
