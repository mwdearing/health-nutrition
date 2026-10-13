import Foundation
import XCTest
@testable import NutritionProviders

final class OpenFoodFactsSearchTests: XCTestCase {
    private let twoProducts = Data("""
    {"count": 2, "page": 1, "page_size": 20, "products": [
      {"code": "2000000000015", "product_name": "Oat Biscuit", "brands": "Example Foods",
       "nutrition_data_per": "100g", "product_quantity_unit": "g",
       "nutriments": {"energy-kcal_100g": 450, "proteins_100g": "7.5"}},
      {"code": "2000000000022", "product_name": "Oat Milk", "brands": "Example Dairy",
       "nutrition_data_per": "100g", "product_quantity_unit": "ml", "nutriments": {}}
    ]}
    """.utf8)

    private func client(_ transport: StubTransport, clock: TestClock = TestClock()) -> OpenFoodFactsClient {
        OpenFoodFactsClient(
            environment: .production, transport: transport, appVersion: "1.0.0",
            now: { clock.now() }, monotonic: { clock.uptime() })
    }

    private func queryItems(of request: URLRequest) throws -> [String: String] {
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        var items: [String: String] = [:]
        for item in components.queryItems ?? [] {
            items[item.name] = item.value
        }
        return items
    }

    func testSearchParsesResults() async throws {
        let transport = StubTransport(body: twoProducts)
        let outcome = await client(transport).search(query: "oat")
        guard case .results(let products) = outcome else {
            return XCTFail("expected results, got \(outcome)")
        }
        XCTAssertEqual(products.map(\.barcode), ["2000000000015", "2000000000022"])
        XCTAssertEqual(products.first?.name, "Oat Biscuit")
        XCTAssertEqual(products.first?.brands, "Example Foods")
        XCTAssertEqual(products.first?.basis, .per100g)
    }

    func testSearchDropsProductsWithMalformedBarcodes() async throws {
        let body = Data("""
        {"count": 3, "products": [
          {"code": "not-a-code", "product_name": "Bad Code", "nutriments": {}},
          {"code": "2000000000015", "product_name": "Oat Biscuit", "nutriments": {}},
          {"code": "2000000000016", "product_name": "Wrong Check Digit", "nutriments": {}}
        ]}
        """.utf8)
        let outcome = await client(StubTransport(body: body)).search(query: "oat")
        guard case .results(let products) = outcome else {
            return XCTFail("expected results, got \(outcome)")
        }
        XCTAssertEqual(products.map(\.barcode), ["2000000000015"])
    }

    func testSearchWithNoProductsIsEmpty() async {
        let transport = StubTransport(body: Data(#"{"count": 0, "products": []}"#.utf8))
        let outcome = await client(transport).search(query: "zzqqxx")
        XCTAssertEqual(outcome, .empty)
    }

    func testSearchRateLimitedOn429() async {
        let transport = StubTransport(status: 429, headers: ["Retry-After": "30"])
        let outcome = await client(transport).search(query: "oat")
        XCTAssertEqual(outcome, .rateLimited(retryAfter: 30))
    }

    func testSearchServerErrorIsTransport() async {
        let transport = StubTransport(status: 500)
        let outcome = await client(transport).search(query: "oat")
        guard case .transport = outcome else {
            return XCTFail("expected transport, got \(outcome)")
        }
    }

    func testQueryTooShortIsNotSent() async {
        let transport = StubTransport(body: twoProducts)
        let outcome = await client(transport).search(query: "  a  ")
        XCTAssertEqual(outcome, .empty)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRequestCarriesOnlyTheTypedQuery() async throws {
        let transport = StubTransport(body: twoProducts)
        _ = await client(transport).search(query: "  c++ oat & honey  ")
        let request = try XCTUnwrap(transport.requests.first)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/cgi/search.pl")
        let items = try queryItems(of: request)
        XCTAssertEqual(Set(items.keys), ["search_terms", "search_simple", "action", "json", "page_size", "fields"])
        XCTAssertEqual(items["search_terms"], "c++ oat & honey")
        XCTAssertEqual(items["search_simple"], "1")
        XCTAssertEqual(items["action"], "process")
        XCTAssertEqual(items["json"], "1")
        XCTAssertEqual(items["page_size"], "20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("HealthNutrition/1.0.0"), true)
    }

    func testQueryIsCappedAtEightyCharacters() async throws {
        let transport = StubTransport(body: twoProducts)
        let long = String(repeating: "b", count: 120)
        _ = await client(transport).search(query: long)
        let items = try queryItems(of: try XCTUnwrap(transport.requests.first))
        XCTAssertEqual(items["search_terms"], String(repeating: "b", count: 80))
    }

    func testSixSearchesPerMinuteThenRateLimited() async {
        let transport = StubTransport(body: twoProducts)
        let model = client(transport)
        for _ in 0..<6 {
            guard case .results = await model.search(query: "oat") else {
                return XCTFail("expected results inside the limit")
            }
        }
        let outcome = await model.search(query: "oat")
        guard case .rateLimited(let retryAfter) = outcome else {
            return XCTFail("expected rate limit, got \(outcome)")
        }
        XCTAssertEqual(retryAfter, 60)
        XCTAssertEqual(transport.requests.count, 6)
    }
}
