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
        OpenFoodFactsClient(environment: environment, transport: transport, appVersion: "1.0.0", now: { clock.now() }, monotonic: { clock.uptime() })
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
        // The unit field is ignored and canonical units apply (grams for sodium).
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.sodium], .known(dec("0.01"), .g))
        XCTAssertNil(product.servingQuantity)
    }

    func testUnitFieldIsIgnoredAndCanonicalUnitsApply() async throws {
        let json = """
        {"code":"2000000000015","result":{"id":"product_found"},
         "product":{"nutriments":{"proteins_100g":5,"proteins_unit":"stone","sodium_100g":0.4,"sodium_unit":"mg",
                                  "energy-kcal_100g":300,"energy-kcal_unit":"kJ"}}}
        """
        let product = try found(await client(StubTransport(body: Data(json.utf8))).lookup(barcode: foundCode))
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.protein], .known(dec("5"), .g))
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.sodium], .known(dec("0.4"), .g))
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.energyKcal], .known(dec("300"), .kcal))
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.fat], NutrientValue.unknown)
    }

    func testMalformedTextAmountsAreUnknown() async throws {
        for bad in ["-", "++1", "1-2", "", "1.2.3", "1e3", "12abc", ".5", "5."] {
            let json = """
            {"code":"2000000000015","result":{"id":"product_found"},
             "product":{"nutriments":{"fat_100g":"\(bad)","proteins_100g":"-2"}}}
            """
            let product = try found(await client(StubTransport(body: Data(json.utf8))).lookup(barcode: foundCode))
            XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.fat], NutrientValue.unknown, bad)
            XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.protein], NutrientValue.unknown)
        }
        let ok = """
        {"code":"2000000000015","result":{"id":"product_found"},"product":{"nutriments":{"fat_100g":"+1.5"}}}
        """
        let product = try found(await client(StubTransport(body: Data(ok.utf8))).lookup(barcode: foundCode))
        XCTAssertEqual(product.nutrients[OpenFoodFactsProduct.fat], .known(dec("1.5"), .g))
    }

    private func basis(servingSize: String?, per: String = "100g") async throws -> OpenFoodFactsBasis {
        let size = servingSize.map { "\"serving_size\":\"\($0)\"," } ?? ""
        let json = """
        {"code":"2000000000015","result":{"id":"product_found"},
         "product":{\(size)"nutrition_data_per":"\(per)","nutriments":{"fat_100g":1}}}
        """
        return try found(await client(StubTransport(body: Data(json.utf8))).lookup(barcode: foundCode)).basis
    }

    func testBasisFromServingSizeUnit() async throws {
        let drink = try await basis(servingSize: "250 ml")
        XCTAssertEqual(drink, .per100ml)
        let solid = try await basis(servingSize: "30 g")
        XCTAssertEqual(solid, .per100g)
        let fluidOunce = try await basis(servingSize: "8 fl.oz (240 ml)")
        XCTAssertEqual(fluidOunce, .per100ml)
        let litre = try await basis(servingSize: "1,5L")
        XCTAssertEqual(litre, .per100ml)
        let missing = try await basis(servingSize: nil)
        XCTAssertEqual(missing, .per100Unspecified)
        let unrecognised = try await basis(servingSize: "1 biscuit")
        XCTAssertEqual(unrecognised, .per100Unspecified)
        let noNumber = try await basis(servingSize: "ml")
        XCTAssertEqual(noNumber, .per100Unspecified)
        let perServing = try await basis(servingSize: "250 ml", per: "serving")
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

    func testRetryAfterHttpDateIsRelativeToInjectedClock() async throws {
        // The test clock starts at 2027-01-15 08:00:00 UTC (1_800_000_000).
        let transport = StubTransport(status: 429, headers: ["Retry-After": "Fri, 15 Jan 2027 08:01:30 GMT"])
        let outcome = await client(transport).lookup(barcode: foundCode)
        XCTAssertEqual(outcome, .rateLimited(retryAfter: 90))
        let past = StubTransport(status: 503, headers: ["Retry-After": "Fri, 15 Jan 2027 07:00:00 GMT"])
        let pastOutcome = await client(past).lookup(barcode: foundCode)
        XCTAssertEqual(pastOutcome, .rateLimited(retryAfter: 0))
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
        _ = await client(staging, environment: .staging(authorization: "Basic dGVzdA==")).lookup(barcode: foundCode)
        let stagingRequest = try XCTUnwrap(staging.requests.first)
        XCTAssertEqual(stagingRequest.url?.host, "world.openfoodfacts.net")
        XCTAssertEqual(stagingRequest.value(forHTTPHeaderField: "Authorization"), "Basic dGVzdA==")

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
