import Foundation
import Testing
import NutritionDomain
@testable import NutritionProviders

private final class StubUSDATransport: OpenFoodFactsTransport, @unchecked Sendable {
    var status = 200
    var body = Data()
    var headers: [String: String] = [:]
    var error: Error?
    private(set) var requests: [URLRequest] = []

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await get(request, maxBytes: USDAFoodDataClient.maxResponseBytes)
    }

    func get(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let error { throw error }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (body, response)
    }
}

private let sampleReply = """
{
  "foods": [
    {
      "fdcId": 1105314,
      "description": "Banana, raw",
      "dataType": "Foundation",
      "foodNutrients": [
        {"nutrientNumber": "1008", "value": 89},
        {"nutrientNumber": "1003", "value": 1.09},
        {"nutrientNumber": "1093", "value": 1},
        {"nutrientNumber": "9999", "value": 5}
      ]
    },
    {
      "fdcId": 2,
      "description": "  Protein bar  ",
      "dataType": "Branded",
      "brandOwner": "Acme Foods",
      "brandName": "Acme",
      "servingSize": 40,
      "servingSizeUnit": "g",
      "householdServingFullText": "1 bar",
      "foodNutrients": [{"nutrientNumber": "1008", "value": 200}]
    },
    {"fdcId": 3, "dataType": "Branded"}
  ]
}
"""

@Test func searchSendsKeyInHeaderNotURL() async throws {
    let transport = StubUSDATransport()
    transport.body = Data(sampleReply.utf8)
    let client = USDAFoodDataClient(apiKey: "test-key-123", transport: transport)

    _ = await client.search(query: "banana")

    let request = try #require(transport.requests.first)
    #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "test-key-123")
    #expect(request.url?.absoluteString.contains("test-key-123") == false)
    #expect(request.url?.host == "api.nal.usda.gov")
    #expect(request.url?.absoluteString.contains("query=banana") == true)
}

@Test func parsesNutrientsServingsAndDropsNamelessRecords() async throws {
    let transport = StubUSDATransport()
    transport.body = Data(sampleReply.utf8)
    let client = USDAFoodDataClient(apiKey: "k", transport: transport)

    let outcome = await client.search(query: "banana")

    guard case .results(let foods) = outcome else {
        Issue.record("expected results, got \(outcome)")
        return
    }
    #expect(foods.count == 2)
    #expect(foods[0].description == "Banana, raw")
    #expect(foods[0].nutrientsPer100g["energyKcal"] == .known(89, .kcal))
    #expect(foods[0].nutrientsPer100g["protein"] == .known(Decimal(string: "1.09")!, .g))
    #expect(foods[0].nutrientsPer100g["sodium"] == .known(1, .mg))
    #expect(foods[0].nutrientsPer100g["fat"] == nil, "a nutrient FDC does not give stays absent, never zero")
    #expect(foods[0].nutrientsPer100g.count == 3, "unmapped nutrient numbers are ignored")
    #expect(foods[0].servingGrams == nil)
    #expect(foods[1].description == "Protein bar")
    #expect(foods[1].brand == "Acme")
    #expect(foods[1].servingGrams == 40)
    #expect(foods[1].servingText == "1 bar")
}

@Test func tooShortQuerySendsNothing() async {
    let transport = StubUSDATransport()
    let client = USDAFoodDataClient(apiKey: "k", transport: transport)

    #expect(await client.search(query: " a ") == .empty)
    #expect(transport.requests.isEmpty)
}

@Test func rateLimitHonoursRetryAfter() async {
    let transport = StubUSDATransport()
    transport.status = 429
    transport.headers = ["Retry-After": "30"]
    let client = USDAFoodDataClient(apiKey: "k", transport: transport)

    #expect(await client.search(query: "rice") == .rateLimited(retryAfter: 30))
}

@Test func refusedKeyIsReportedWithoutEchoingIt() async {
    let transport = StubUSDATransport()
    transport.status = 403
    let client = USDAFoodDataClient(apiKey: "secret-key", transport: transport)

    let outcome = await client.search(query: "rice")

    #expect(outcome == .transport("the USDA key was refused"))
    if case .transport(let text) = outcome {
        #expect(!text.contains("secret-key"))
    }
}

@Test func emptyReplyIsEmpty() async {
    let transport = StubUSDATransport()
    transport.body = Data(#"{"foods": []}"#.utf8)
    let client = USDAFoodDataClient(apiKey: "k", transport: transport)

    #expect(await client.search(query: "zzzzqq") == .empty)
}

@Test func malformedReplyIsATransportFailure() async {
    let transport = StubUSDATransport()
    transport.body = Data("not json".utf8)
    let client = USDAFoodDataClient(apiKey: "k", transport: transport)

    #expect(await client.search(query: "rice") == .transport("the USDA reply could not be read"))
}
