import Foundation
import NutritionDomain
import XCTest
@testable import NutritionProviders

/// A transport that answers from memory and records what the client asked for, so no test touches the
/// network. Every response is scripted: a status, a body and headers.
final class FakeDSLDTransport: DSLDTransport, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: Data
        let headers: [String: String]

        init(status: Int = 200, body: Data = Data("{}".utf8), headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    enum Failure: Error {
        case offline
    }

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let reply: Reply
    private let failure: Failure?

    init(reply: Reply = Reply(), failure: Failure? = nil) {
        self.reply = reply
        self.failure = failure
    }

    convenience init(status: Int = 200, body: Data = Data("{}".utf8), headers: [String: String] = [:]) {
        self.init(reply: Reply(status: status, body: body, headers: headers))
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        if let failure {
            throw failure
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: reply.status,
            httpVersion: nil,
            headerFields: reply.headers
        )!
        return (reply.body, response)
    }
}

/// Reads the recorded DSLD responses that live in `contracts/providers/dsld` in the repository, found
/// relative to this file, so the client tests decode the same bytes the live API serves.
private enum RecordedDSLD {
    static func directory(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: String(describing: file))
        // .../ios/NutritionCore/Tests/NutritionProvidersTests/DSLDClientTests.swift -> repository root
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("contracts/providers/dsld")
    }

    static func data(_ name: String, file: StaticString = #filePath) throws -> Data {
        try Data(contentsOf: directory(file: file).appendingPathComponent(name))
    }

    /// The recorded label with this DSLD identifier, for example 204235.
    static func label(_ identifier: Int, file: StaticString = #filePath) throws -> Data {
        try data("fixtures/labels/\(identifier).json", file: file)
    }

    /// A trimmed search-filter response with one hit, standing in for a live `q=<term>&size=<n>` answer.
    static func searchBody(_ id: Int, fullName: String, brandName: String) -> Data {
        let json = """
        {"hits":[{"_index":"dsldnxt_labels","_type":"_doc","_id":"\(id)","_source":\
        {"fullName":"\(fullName)","brandName":"\(brandName)","offMarket":0}}],"stats":{"count":1234}}
        """
        return Data(json.utf8)
    }
}

final class DSLDClientTests: XCTestCase {
    private func dec(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    }

    private func client(_ transport: FakeDSLDTransport, environment: DSLDEnvironment = .production) -> DSLDClient {
        DSLDClient(environment: environment, transport: transport, appVersion: "1.0.0")
    }

    private func label(
        _ outcome: DSLDOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> DSLDSupplementLabel {
        guard case .found(let label) = outcome else {
            XCTFail("expected found, got \(outcome)", file: file, line: line)
            throw URLError(.cannotParseResponse)
        }
        return label
    }

    private func hits(
        _ outcome: DSLDSearchOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [DSLDSearchHit] {
        guard case .found(let found) = outcome else {
            XCTFail("expected found, got \(outcome)", file: file, line: line)
            throw URLError(.cannotParseResponse)
        }
        return found.hits
    }

    // MARK: - Found

    func testFoundLabelFromRecordedFixtureIsParsedByTheAdapter() async throws {
        let transport = FakeDSLDTransport(body: try RecordedDSLD.label(204235))
        let parsed = try label(await client(transport).label(id: 204235))
        XCTAssertEqual(parsed.id, 204235)
        XCTAssertEqual(parsed.fullName, "Magnesium Citrate")
        XCTAssertEqual(parsed.brandName, "Bluebonnet")
        XCTAssertTrue(parsed.offMarket)
        XCTAssertEqual(parsed.servingSizes.count, 1)
        XCTAssertEqual(parsed.servingSizes[0].order, 1)
        XCTAssertEqual(parsed.servingSizes[0].minimum, Quantity(value: dec("2"), unit: .serving))
        XCTAssertTrue(parsed.servingSizes[0].isFactsPanelServing)
        let magnesium = try XCTUnwrap(parsed.fact(named: "Magnesium"))
        XCTAssertEqual(magnesium.substanceIdentifier, "6520")
        XCTAssertEqual(magnesium.chemicalForm, "Magnesium Citrate")
        XCTAssertEqual(magnesium.amount, .known(dec("400"), .mg))
        XCTAssertEqual(magnesium.provenance, "NIH DSLD label 204235, ingredient row 1, serving size 1")
    }

    func testFoundLabelUsesTheSameBytesTheAdapterReads() async throws {
        // The client never interprets the label itself: it hands the response to DSLDLabelAdapter, so a
        // live label and a recorded label parse through one code path.
        let recorded = try RecordedDSLD.label(1225)
        let parsed = try label(await client(FakeDSLDTransport(body: recorded)).label(id: 1225))
        let adapter = DSLDLabelAdapter()
        let direct = try adapter.parse(recorded)
        XCTAssertEqual(parsed, direct)
    }

    // MARK: - Request shape

    func testLabelRequestCarriesTheGetUserAgentAndLabelURL() async throws {
        let transport = FakeDSLDTransport(body: try RecordedDSLD.label(204235))
        _ = await client(transport).label(id: 204235)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"),
            "HealthNutrition/1.0.0 (+\(DSLDAttribution.issueURL))"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "api.ods.od.nih.gov")
        XCTAssertEqual(url.path, "/dsld/v9/label/204235")
        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.query)
    }

    func testNonPositiveLabelIdentifierMakesNoRequest() async throws {
        for bad in [0, -1] {
            let transport = FakeDSLDTransport(body: try RecordedDSLD.label(204235))
            let outcome = await client(transport).label(id: bad)
            guard case .failed(let reason) = outcome else {
                return XCTFail("expected failed for \(bad), got \(outcome)")
            }
            XCTAssertFalse(reason.isEmpty)
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    // MARK: - Not found

    func testLabelNotFoundOn404() async throws {
        let transport = FakeDSLDTransport(status: 404, body: Data("{}".utf8))
        let outcome = await client(transport).label(id: 204235)
        XCTAssertEqual(outcome, .notFound)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testLabelNotFoundOnAnUnexpectedStatusIsFailedNotNotFound() async throws {
        let outcome = await client(FakeDSLDTransport(status: 500)).label(id: 204235)
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("500"), reason)
    }

    // MARK: - Rate limiting

    func testRateLimitedOn429UsesTheRetryAfterSeconds() async throws {
        let transport = FakeDSLDTransport(status: 429, body: Data(), headers: ["Retry-After": "30"])
        let outcome = await client(transport).label(id: 204235)
        XCTAssertEqual(outcome, .rateLimited(retryAfter: 30))
    }

    func testRateLimitedOn503WithoutRetryAfterUsesTheDefault() async throws {
        let outcome = await client(FakeDSLDTransport(status: 503)).label(id: 204235)
        XCTAssertEqual(outcome, .rateLimited(retryAfter: DSLDClient.defaultRetryAfter))
        XCTAssertEqual(DSLDClient.defaultRetryAfter, 60)
    }

    func testRateLimitedOnAnUnreadableRetryAfterUsesTheDefault() async throws {
        let transport = FakeDSLDTransport(status: 429, headers: ["Retry-After": "soon"])
        let outcome = await client(transport).label(id: 204235)
        XCTAssertEqual(outcome, .rateLimited(retryAfter: DSLDClient.defaultRetryAfter))
    }

    // MARK: - Failures

    func testMalformedLabelBodyIsFailed() async throws {
        for body in ["not json", "", "[]", "{\"id\":1}", "{}"] {
            let outcome = await client(FakeDSLDTransport(body: Data(body.utf8))).label(id: 204235)
            guard case .failed(let reason) = outcome else {
                return XCTFail("expected failed for \(body.debugDescription), got \(outcome)")
            }
            XCTAssertFalse(reason.isEmpty, body.debugDescription)
        }
    }

    func testTransportErrorIsFailedWithAReason() async throws {
        let transport = FakeDSLDTransport(failure: .offline)
        let outcome = await client(transport).label(id: 204235)
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    // MARK: - Search

    func testSearchBuildsTheFilterQueryAndDecodesHits() async throws {
        let transport = FakeDSLDTransport(body: RecordedDSLD.searchBody(204235, fullName: "Magnesium Citrate", brandName: "Bluebonnet"))
        let outcome = await client(transport).search(term: "magnesium citrate", limit: 10)
        let found = try hits(outcome)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].id, 204235)
        XCTAssertEqual(found[0].fullName, "Magnesium Citrate")
        XCTAssertEqual(found[0].brandName, "Bluebonnet")
        guard case .found(let result) = outcome else {
            return XCTFail("expected found, got \(outcome)")
        }
        XCTAssertEqual(result.total, 1234)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"),
            "HealthNutrition/1.0.0 (+https://github.com/mwdearing/health-nutrition/issues)"
        )
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/dsld/v9/search-filter")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "q" }?.value, "magnesium citrate")
        XCTAssertEqual(query.first { $0.name == "size" }?.value, "10")
    }

    func testSearchEncodesTheTermAndClampsTheLimit() async throws {
        let transport = FakeDSLDTransport(body: RecordedDSLD.searchBody(1, fullName: "A", brandName: "B"))
        _ = await client(transport).search(term: "vitamin D3 & zinc", limit: 500)
        let url = try XCTUnwrap(transport.requests.first?.url)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "q" }?.value, "vitamin D3 & zinc")
        XCTAssertEqual(query.first { $0.name == "size" }?.value, String(DSLDClient.maximumSearchSize))
    }

    func testSearchWithNoHitsIsFoundWithAnEmptyList() async throws {
        let transport = FakeDSLDTransport(body: Data("{\"hits\":[],\"stats\":{\"count\":0}}".utf8))
        let outcome = await client(transport).search(term: "nothing at all", limit: 10)
        let found = try hits(outcome)
        XCTAssertTrue(found.isEmpty)
        guard case .found(let results) = outcome else {
            return XCTFail("expected found, got \(outcome)")
        }
        XCTAssertEqual(results.total, 0)
    }

    func testSearchMalformedBodyIsFailed() async throws {
        let outcome = await client(FakeDSLDTransport(body: Data("{\"hits\":".utf8))).search(term: "magnesium", limit: 10)
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testBlankSearchTermMakesNoRequestBecauseSearchIsAnExplicitAction() async throws {
        for term in ["", "   "] {
            let transport = FakeDSLDTransport(body: RecordedDSLD.searchBody(1, fullName: "A", brandName: "B"))
            let outcome = await client(transport).search(term: term, limit: 10)
            guard case .failed(let reason) = outcome else {
                return XCTFail("expected failed for \(term.debugDescription), got \(outcome)")
            }
            XCTAssertFalse(reason.isEmpty)
            XCTAssertTrue(transport.requests.isEmpty, "no type-ahead request may be sent")
        }
    }

    func testSearchNotFoundStatusAndRateLimitCarryTheSameOutcomes() async throws {
        let missing = await client(FakeDSLDTransport(status: 404)).search(term: "magnesium", limit: 10)
        XCTAssertEqual(missing, .notFound)
        let limited = await client(FakeDSLDTransport(status: 429, headers: ["Retry-After": "45"]))
            .search(term: "magnesium", limit: 10)
        XCTAssertEqual(limited, .rateLimited(retryAfter: 45))
        let unavailable = await client(FakeDSLDTransport(status: 503)).search(term: "magnesium", limit: 10)
        XCTAssertEqual(unavailable, .rateLimited(retryAfter: DSLDClient.defaultRetryAfter))
    }

    // MARK: - Environment

    func testProductionEnvironmentNamesTheDSLDHostAndTheLicence() {
        XCTAssertEqual(
            DSLDEnvironment.production.baseURL.absoluteString,
            "https:" + "//" + "api.ods.od.nih.gov/dsld"
        )
        XCTAssertEqual(DSLDAttribution.url, "https:" + "//" + "dsld.ods.od.nih.gov/")
        XCTAssertEqual(
            DSLDAttribution.issueURL,
            "https:" + "//" + "github.com/mwdearing/health-nutrition/issues"
        )
        XCTAssertTrue(DSLDAttribution.text.contains("Dietary Supplement Label Database"))
        XCTAssertEqual(DSLDAttribution.licenseName, "CC0 1.0 Universal")
    }

    func testEnvironmentBaseURLPathIsKeptWhenRequestsAreBuilt() async throws {
        let environment = DSLDEnvironment(baseURL: URL(string: "https://example.test/dsld")!)
        let transport = FakeDSLDTransport(body: try RecordedDSLD.label(204235))
        _ = await client(transport, environment: environment).label(id: 204235)
        let url = try XCTUnwrap(transport.requests.first?.url)
        XCTAssertEqual(url.host, "example.test")
        XCTAssertEqual(url.path, "/dsld/v9/label/204235")
    }
}