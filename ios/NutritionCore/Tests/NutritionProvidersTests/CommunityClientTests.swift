import Foundation
import XCTest
@testable import NutritionProviders

final class CommunityClientTests: XCTestCase {
    private let barcode = "0123456070004"

    private func submission() -> CommunityLabelSubmission {
        CommunityLabelSubmission(
            barcode: barcode,
            basis: .per100g,
            servingText: nil,
            productName: "Oat Bar",
            brand: "Acme",
            nutrients: ["energyKcal": Decimal(400), "protein": Decimal(string: "10.1")!]
        )
    }

    /// A client over a fake transport, with a signed-in session unless the store is passed in.
    private func client(
        _ transport: FakeCommunityTransport,
        store: InMemoryCommunitySessionStore = InMemoryCommunitySessionStore(testSession())
    ) throws -> CommunityClient {
        CommunityClient(config: try makeConfig(), transport: transport, store: store, now: { testNow })
    }

    func testProfileReadsOwnRowWithBearer() async throws {
        let transport = FakeCommunityTransport([.response(status: 200, body: #"[{"display_name":"Sam","share_labels":false}]"#)])
        let profile = try await client(transport).profile()

        XCTAssertEqual(profile, CommunityProfile(displayName: "Sam", shareLabels: false))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/rest/v1/profiles")
        XCTAssertEqual(queryItems(request)["select"], "display_name,share_labels")
        XCTAssertEqual(queryItems(request)["id"], "eq.\(testUserID)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "test-anon-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
    }

    func testProfileWithoutRowReturnsDefaults() async throws {
        let transport = FakeCommunityTransport([.response(status: 200, body: "[]")])
        let profile = try await client(transport).profile()

        XCTAssertEqual(profile, CommunityProfile(displayName: nil, shareLabels: true))
    }

    func testUpdateProfilePatchesWithRepresentation() async throws {
        let transport = FakeCommunityTransport([.response(status: 200, body: #"[{"display_name":"Sam","share_labels":true}]"#)])
        let profile = try await client(transport).updateProfile(displayName: "Sam", shareLabels: true)

        XCTAssertEqual(profile, CommunityProfile(displayName: "Sam", shareLabels: true))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/rest/v1/profiles")
        XCTAssertEqual(queryItems(request)["id"], "eq.\(testUserID)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "return=representation")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        let body = try bodyJSON(request)
        XCTAssertEqual(body["display_name"] as? String, "Sam")
        XCTAssertEqual(body["share_labels"] as? Bool, true)
    }

    func testUpdateProfileSendsNullNameWhenCleared() async throws {
        let transport = FakeCommunityTransport([.response(status: 200, body: #"[{"display_name":null,"share_labels":true}]"#)])
        _ = try await client(transport).updateProfile(displayName: nil, shareLabels: true)

        let body = try bodyJSON(try XCTUnwrap(transport.requests.first))
        XCTAssertTrue(body.keys.contains("display_name"))
        XCTAssertTrue(body["display_name"] is NSNull)
    }

    func testDeleteAccountCallsRPCAndClearsSession() async throws {
        let transport = FakeCommunityTransport([.response(status: 204, body: "")])
        let store = InMemoryCommunitySessionStore(testSession())
        try await client(transport, store: store).deleteAccount()

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/delete_my_account")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertNil(store.load())
    }

    func testFailedDeleteKeepsSession() async throws {
        let transport = FakeCommunityTransport([.response(status: 500, body: "")])
        let stored = testSession()
        let store = InMemoryCommunitySessionStore(stored)

        await assertCommunityError(.server(500)) { try await client(transport, store: store).deleteAccount() }
        XCTAssertEqual(store.load(), stored)
    }

    func testSubmitLabelSendsParameters() async throws {
        let transport = FakeCommunityTransport([.response(status: 200, body: #""received""#)])
        let result = try await client(transport).submitLabel(submission())

        XCTAssertEqual(result, .received)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/submit_label")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "test-anon-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        let body = try bodyJSON(request)
        XCTAssertEqual(body["p_barcode"] as? String, barcode)
        XCTAssertEqual(body["p_basis"] as? String, "per_100g")
        XCTAssertTrue(body["p_serving_text"] is NSNull)
        XCTAssertEqual(body["p_product_name"] as? String, "Oat Bar")
        XCTAssertEqual(body["p_brand"] as? String, "Acme")
        let nutrients = try XCTUnwrap(body["p_nutrients"] as? [String: Any])
        XCTAssertEqual((nutrients["energyKcal"] as? NSNumber)?.doubleValue, 400)
        XCTAssertEqual((nutrients["protein"] as? NSNumber)?.doubleValue, 10.1)
    }

    func testSubmitLabelReturnsEachStatus() async throws {
        let transport = FakeCommunityTransport([
            .response(status: 200, body: #""received""#),
            .response(status: 200, body: #""shared""#),
            .response(status: 200, body: #""verified""#),
        ])
        let community = try client(transport)

        let first = try await community.submitLabel(submission())
        let second = try await community.submitLabel(submission())
        let third = try await community.submitLabel(submission())

        XCTAssertEqual([first, second, third], [.received, .shared, .verified])
    }

    func testLookupLabelDecodesVerifiedAndUnverifiedLabels() async throws {
        let body = """
        [{"basis":"per_100g","serving_text":null,"product_name":"Oat Bar","brand":"Acme","nutrients":{"energyKcal":400,"protein":10},"supporting_devices":5,"verified":true},\
        {"basis":"per_serving","serving_text":"1 bar (40 g)","product_name":"Oat Bar","brand":null,"nutrients":{"energyKcal":160},"supporting_devices":2,"verified":false}]
        """
        let transport = FakeCommunityTransport([.response(status: 200, body: body)])
        let labels = try await client(transport).lookupLabel(barcode: barcode)

        XCTAssertEqual(labels.count, 2)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/lookup_label")
        XCTAssertEqual(try bodyJSON(request)["p_barcode"] as? String, barcode)
        XCTAssertEqual(labels[0].barcode, barcode)
        XCTAssertEqual(labels[0].basis, .per100g)
        XCTAssertNil(labels[0].servingText)
        XCTAssertEqual(labels[0].productName, "Oat Bar")
        XCTAssertEqual(labels[0].brand, "Acme")
        XCTAssertEqual(labels[0].nutrients["energyKcal"], Decimal(400))
        XCTAssertEqual(labels[0].supportingAccounts, 5)
        XCTAssertTrue(labels[0].verified)
        XCTAssertEqual(labels[1].basis, .perServing)
        XCTAssertEqual(labels[1].servingText, "1 bar (40 g)")
        XCTAssertNil(labels[1].brand)
        XCTAssertEqual(labels[1].supportingAccounts, 2)
        XCTAssertFalse(labels[1].verified)
    }

    func testLookupWithoutSessionIsSignedOutWithoutARequest() async throws {
        let transport = FakeCommunityTransport()
        let community = try client(transport, store: InMemoryCommunitySessionStore())

        await assertCommunityError(.signedOut) { try await community.lookupLabel(barcode: barcode) }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testSubmitWithoutSessionSendsNothing() async throws {
        let transport = FakeCommunityTransport()
        let community = try client(transport, store: InMemoryCommunitySessionStore())

        await assertCommunityError(.signedOut) { try await community.submitLabel(submission()) }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testSQLStateErrorsAreMapped() async throws {
        let cases: [(code: String, expected: CommunityError)] = [
            ("28000", .signedOut),
            ("42501", .sharingOff),
            ("22023", .invalid),
            ("53400", .rateLimited),
        ]
        for testCase in cases {
            let transport = FakeCommunityTransport([
                .response(status: 400, body: #"{"code":"\#(testCase.code)","message":"test message"}"#),
            ])
            let community = try client(transport)
            await assertCommunityError(testCase.expected) { try await community.submitLabel(submission()) }
        }
    }

    func testStatusErrorsAreMapped() async throws {
        let cases: [(status: Int, expected: CommunityError)] = [
            (400, .invalid),
            (401, .unauthorized),
            (403, .unauthorized),
            (429, .rateLimited),
            (500, .server(500)),
        ]
        for testCase in cases {
            let transport = FakeCommunityTransport([.response(status: testCase.status, body: "")])
            let community = try client(transport)
            await assertCommunityError(testCase.expected) { try await community.submitLabel(submission()) }
        }
    }

    func testTransportFailureIsNetwork() async throws {
        let transport = FakeCommunityTransport([.failure(URLError(.notConnectedToInternet))])
        let community = try client(transport)

        await assertCommunityError(.network) { try await community.lookupLabel(barcode: barcode) }
    }

    func testMakeReportsMissingConfigAsNotConfigured() {
        XCTAssertThrowsError(try CommunityClient.make(
            infoDictionary: nil,
            transport: FakeCommunityTransport(),
            store: InMemoryCommunitySessionStore()
        )) { error in
            XCTAssertEqual(error as? CommunityError, .notConfigured)
        }
        XCTAssertNoThrow(try CommunityClient.make(
            infoDictionary: testInfo(),
            transport: FakeCommunityTransport(),
            store: InMemoryCommunitySessionStore()
        ))
    }
}
