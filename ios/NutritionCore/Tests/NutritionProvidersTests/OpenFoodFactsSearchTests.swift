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

    private func client(_ transport: any OpenFoodFactsTransport, clock: TestClock = TestClock()) -> OpenFoodFactsClient {
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
          {"code": "2000000000016", "product_name": "Wrong Check Digit", "nutriments": {}},
          {"code": " 2000000000022 ", "product_name": "Padded Code", "nutriments": {}}
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
        for index in 0..<6 {
            guard case .results = await model.search(query: "oat \(index)") else {
                return XCTFail("expected results inside the limit")
            }
        }
        let outcome = await model.search(query: "oat 6")
        guard case .rateLimited(let retryAfter) = outcome else {
            return XCTFail("expected rate limit, got \(outcome)")
        }
        XCTAssertEqual(retryAfter, 60)
        XCTAssertEqual(transport.requests.count, 6)
    }

    func testRepeatedSearchIsAnsweredWithoutAnotherRequest() async {
        let transport = StubTransport(body: twoProducts)
        let model = client(transport)
        let first = await model.search(query: "oat")
        for _ in 0..<8 {
            let repeated = await model.search(query: "  oat ")
            XCTAssertEqual(repeated, first)
        }
        XCTAssertEqual(transport.requests.count, 1)
        // The repeats spent nothing: five more different searches still fit in the same minute.
        for index in 0..<5 {
            guard case .results = await model.search(query: "oat \(index)") else {
                return XCTFail("a repeated search spent a rate-limit slot")
            }
        }
        XCTAssertEqual(transport.requests.count, 6)
    }

    func testRepeatedSearchIsSentAgainAfterTheWindow() async {
        let transport = StubTransport(body: twoProducts)
        let clock = TestClock()
        let model = client(transport, clock: clock)
        _ = await model.search(query: "oat")
        clock.advance(60)
        _ = await model.search(query: "oat")
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testFailedSearchIsNotRemembered() async {
        let transport = StubTransport(status: 500)
        let model = client(transport)
        _ = await model.search(query: "oat")
        _ = await model.search(query: "oat")
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testSameSearchWhileOneIsRunningSharesItsRequest() async {
        let transport = GatedTransport(body: twoProducts)
        let model = client(transport)
        async let first = model.search(query: "oat")
        await transport.waitForRequests(1)
        async let second = model.search(query: "oat")
        // Give the second call time to reach the client before the reply is released.
        for _ in 0..<50 { await Task.yield() }
        transport.release()
        let outcomes = await [first, second]
        XCTAssertEqual(outcomes[0], outcomes[1])
        guard case .results = outcomes[0] else {
            return XCTFail("expected results, got \(outcomes[0])")
        }
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testCancelledCallerStillLetsARepeatUseTheReply() async {
        let transport = GatedTransport(body: twoProducts)
        let model = client(transport)
        let abandoned = Task { await model.search(query: "oat") }
        await transport.waitForRequests(1)
        abandoned.cancel()
        transport.release()
        _ = await abandoned.value
        guard case .results = await model.search(query: "oat") else {
            return XCTFail("expected the reply to the abandoned search to be reused")
        }
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testSearch503WithoutRetryAfterIsUnavailableNotRateLimited() async {
        let outcome = await client(StubTransport(status: 503)).search(query: "oat")
        guard case .transport = outcome else {
            return XCTFail("expected transport, got \(outcome)")
        }
    }

    func testSearch503WithRetryAfterIsRateLimited() async {
        let transport = StubTransport(status: 503, headers: ["Retry-After": "30"])
        let outcome = await client(transport).search(query: "oat")
        XCTAssertEqual(outcome, .rateLimited(retryAfter: 30))
    }
}

/// Holds every request open until `release()` is called, so a test can act while a search is running.
private final class GatedTransport: OpenFoodFactsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let body: Data
    private var count = 0
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(body: Data) {
        self.body = body
    }

    var requestCount: Int {
        lock.withLock { count }
    }

    func waitForRequests(_ wanted: Int) async {
        while requestCount < wanted { await Task.yield() }
    }

    func release() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { waiting = [] }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = lock.withLock { () -> Bool in
                count += 1
                if !released { waiting.append(continuation) }
                return released
            }
            if open { continuation.resume() }
        }
        try Task.checkCancellation()
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
}
