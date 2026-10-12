import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import NutritionDomain
@testable import NutritionProviders

final class CommunityProductsTests: XCTestCase {
    private let owner = UUID(uuidString: testUserID)!
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("contracts/catalog-api/fixtures/shared-products-v2/\(name).json"))
    }
    private func client(_ transport: any CommunityTransport, expired: Bool = false) throws -> CommunityClient {
        CommunityClient(config: try makeConfig(), transport: transport, store: InMemoryCommunitySessionStore(testSession(expiresAt: expired ? testNow : testNow.addingTimeInterval(3600))), now: { testNow })
    }
    func testSelectedIdentityAllowsFirstOwnContributionAndServerRejectsStaleCAS() async throws {
        let request = try JSONDecoder().decode(ProductPublishRequest.self, from: fixture("selected-identity-first-contribution-valid"))
        let bytes = try request.canonicalBody()
        XCTAssertNotNil(request.productID)
        XCTAssertNil(request.expectedServerRevision)
        let transport = FakeCommunityTransport([.response(status: 400, body: #"{"code":"P0001","details":"{\"code\":\"revision_conflict\",\"current_revision\":\"7\",\"current_state\":\"active\"}"}"#)])
        await expect(.revisionConflict(currentRevision: "7", currentState: .active)) {
            try await self.client(transport).publish(request, expectedOwnerID: self.owner)
        }
        XCTAssertEqual(transport.requests.first?.httpBody, CommunityProductsAPI.wrapped(bytes))
    }
    func testBoundedPublicationMetadataAndAlternativePageAreClosed() throws {
        let product = try JSONDecoder().decode(CommunityProduct.self, from: fixture("bounded-public-product-valid"))
        XCTAssertEqual(product.alternativesTotal, String(product.alternatives.count))
        XCTAssertNil(product.alternativesCursor)
        let page = try JSONDecoder().decode(ProductAlternativesPage.self, from: fixture("alternatives-response-valid"))
        XCTAssertEqual(page.productID, product.productID)
        let cap = try JSONDecoder().decode(ProductCatalogCapabilities.self, from: fixture("capabilities-bounded-valid"))
        XCTAssertTrue(cap.supportsBoundedPublication)
        XCTAssertFalse(try JSONDecoder().decode(ProductCatalogCapabilities.self, from: fixture("capabilities-valid")).supportsBoundedPublication)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("bounded-public-product-valid")) as? [String: Any])
        object.removeValue(forKey: "alternatives_cursor")
        XCTAssertThrowsError(try JSONDecoder().decode(CommunityProduct.self, from: JSONSerialization.data(withJSONObject: object)))
        object["alternatives_cursor"] = String(repeating: "x", count: 1025)
        XCTAssertThrowsError(try JSONDecoder().decode(CommunityProduct.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    func testAlternativeTransportPreservesCursorAndRequiresClosedNullablePage() async throws {
        let pageBytes = try fixture("alternatives-response-valid")
        let page = try JSONDecoder().decode(ProductAlternativesPage.self, from: pageBytes)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        XCTAssertTrue(encoded.keys.contains("next_cursor"))
        let transport = FakeCommunityTransport([.response(status: 200, body: String(decoding: pageBytes, as: UTF8.self))])
        let result = try await client(transport).alternatives(productID: page.productID, cursor: "public-state-cursor")
        XCTAssertEqual(result, page)
        let body = try XCTUnwrap(transport.requests.first?.httpBody)
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(args["p_cursor"] as? String, "public-state-cursor")
        XCTAssertEqual(args["p_product_id"] as? String, page.productID.uuidString.lowercased())
        XCTAssertEqual(args["p_limit"] as? Int, 20)
        await expect(.invalidRequest(field: "p_cursor")) {
            try await self.client(transport).alternatives(productID: page.productID, cursor: String(repeating: "é", count: 513))
        }
        XCTAssertEqual(transport.requests.count, 1)
    }
    func testRetryAfterHTTPDatesUseServerClockAndClampPastDates() throws {
        let now = Date(timeIntervalSince1970: 0)
        let cases: [([String: String], String?)] = [
            (["Date": "Thu, 01 Jan 1970 00:01:00 GMT", "Retry-After": "Thu, 01 Jan 1970 00:01:09 GMT"], "9"),
            (["Date": "Thu, 01 Jan 1970 00:01:00 GMT", "Retry-After": "Thu, 01 Jan 1970 00:00:59 GMT"], "0"),
            (["Retry-After": "Thu, 01 Jan 1970 00:00:07 GMT"], "7"),
            (["Date": "invalid", "Retry-After": "Thu, 01 Jan 1970 00:00:07 GMT"], "7"),
            (["Retry-After": "not a date"], nil)
        ]
        for (headers, expected) in cases {
            let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 429, httpVersion: nil, headerFields: headers))
            XCTAssertEqual(CommunityProductsAPI.error(status: 429, data: Data(), response: response, capability: false, now: now), .rateLimited(retryAfterSeconds: expected))
        }
    }
    func testResolveCanceledPublishPreservesOriginalEnvelope() async throws {
        let request = try JSONDecoder().decode(ProductPublishRequest.self, from: fixture("name-only-valid"))
        var capabilities = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("capabilities-valid")) as? [String: Any])
        capabilities["publish_resolution_version"] = 1
        capabilities["enabled"] = false
        capabilities["sharing_permission"] = false
        capabilities["caller_acknowledgment"] = NSNull()
        let t = FakeCommunityTransport([
            .response(status: 200, body: String(decoding: try JSONSerialization.data(withJSONObject: capabilities), as: UTF8.self)),
            .response(status: 200, body: "{\"outcome\":\"canceled_before_commit\",\"operation_id\":\"\(request.operationID)\",\"replayed\":false}")
        ])
        let result = try await client(t).resolvePublishForWithdrawal(request, expectedOwnerID: owner)
        XCTAssertEqual(result, .canceledBeforeCommit(operationID: UUID(uuidString: request.operationID)!, replayed: false))
        XCTAssertEqual(t.requests.map { $0.url!.lastPathComponent }, ["catalog_capabilities_v2", "resolve_catalog_publish_for_withdrawal_v2"])
        XCTAssertEqual(t.requests[1].httpBody, CommunityProductsAPI.wrapped(try request.canonicalBody()))
    }
    func testResolveCapabilityAbsenceZeroAndFutureDisablePath() async throws {
        let request = try JSONDecoder().decode(ProductPublishRequest.self, from: fixture("name-only-valid"))
        for version: Int? in [nil, 0, 2, 999] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("capabilities-valid")) as? [String: Any])
            object["publish_resolution_version"] = version
            let data = try JSONSerialization.data(withJSONObject: object)
            let caps = try JSONDecoder().decode(ProductCatalogCapabilities.self, from: data)
            XCTAssertFalse(caps.supportsPublishResolution)
            let t = FakeCommunityTransport([.response(status: 200, body: String(decoding: data, as: UTF8.self))])
            await expect(.unsupportedBackend) { try await self.client(t).resolvePublishForWithdrawal(request, expectedOwnerID: self.owner) }
            XCTAssertEqual(t.requests.map { $0.url!.lastPathComponent }, ["catalog_capabilities_v2"])
        }
    }
    func testResolveCommittedReceiptKeepsAcknowledgedAndCurrentRevisionsSeparate() async throws {
        let request = try JSONDecoder().decode(ProductPublishRequest.self, from: fixture("name-only-valid"))
        var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("receipt-valid")) as? [String: Any])
        receipt["replayed"] = true
        receipt["current_revision"] = "2"
        receipt["current_state"] = "withdrawn"
        receipt["publication"] = NSNull()
        let t = FakeCommunityTransport([
            .response(status: 200, body: String(decoding: try fixture("capabilities-resolution-valid"), as: UTF8.self)),
            .response(status: 200, body: String(decoding: try JSONSerialization.data(withJSONObject: ["outcome": "committed", "receipt": receipt]), as: UTF8.self))
        ])
        let result = try await client(t).resolvePublishForWithdrawal(request, expectedOwnerID: owner)
        guard case .committed(let acknowledgment) = result else { return XCTFail("expected committed receipt") }
        XCTAssertEqual(acknowledgment.acknowledgedRevision, "1")
        XCTAssertEqual(acknowledgment.currentRevision, "2")
        XCTAssertEqual(acknowledgment.currentState, .withdrawn)
        XCTAssertTrue(acknowledgment.replayed)
        XCTAssertEqual(t.requests.count, 2)
    }
    func testMalformedResolutionNeverAcknowledgesOrFallsBack() async throws {
        let request = try JSONDecoder().decode(ProductPublishRequest.self, from: fixture("name-only-valid"))
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("resolution-canceled-valid")) as? [String: Any])
        var mutations: [[String: Any]] = [[:], ["outcome": "unknown"], ["outcome": "committed", "receipt": NSNull()]]
        for key in valid.keys { var changed = valid; changed.removeValue(forKey: key); mutations.append(changed) }
        for (key, value): (String, Any) in [("product_id", UUID().uuidString), ("receipt", NSNull()), ("operation_id", UUID().uuidString), ("replayed", "true"), ("outcome", "committed")] {
            var changed = valid; changed[key] = value; mutations.append(changed)
        }
        let ordinary = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("receipt-valid")) as? [String: Any])
        mutations.append(ordinary)
        mutations.append(["outcome": "committed", "receipt": ordinary]) // replayed=false is never resolution.
        var wrongReceipt = ordinary; wrongReceipt["replayed"] = true; wrongReceipt["operation_id"] = UUID().uuidString
        mutations.append(["outcome": "committed", "receipt": wrongReceipt])
        var replay = ordinary; replay["replayed"] = true
        mutations.append(["outcome": "committed", "receipt": replay, "replayed": true])
        for object in mutations {
            let t = FakeCommunityTransport([
                .response(status: 200, body: String(decoding: try fixture("capabilities-resolution-valid"), as: UTF8.self)),
                .response(status: 200, body: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
            ])
            await expect(.unavailable) { try await self.client(t).resolvePublishForWithdrawal(request, expectedOwnerID: self.owner) }
            XCTAssertEqual(t.requests.count, 2)
            XCTAssertFalse(t.requests.contains { $0.url!.lastPathComponent == "submit_catalog_product_v2" })
        }
        // A deployed capability with missing RPC stays pending/unavailable, with no publish fallback.
        for (status, body, error): (Int, String, ProductAPIError) in [
            (404, #"{"code":"PGRST202"}"#, .unavailable), (503, "{}", .unavailable),
            (400, #"{"code":"P0001","details":"{\"code\":\"operation_conflict\"}"}"#, .operationConflict),
            (429, "{}", .rateLimited(retryAfterSeconds: nil))
        ] {
            let t = FakeCommunityTransport([
                .response(status: 200, body: String(decoding: try fixture("capabilities-resolution-valid"), as: UTF8.self)),
                .response(status: status, body: body)
            ])
            await expect(error) { try await self.client(t).resolvePublishForWithdrawal(request, expectedOwnerID: self.owner) }
            XCTAssertEqual(t.requests.count, 2)
        }
    }
    func testResolveCommittedReceiptMustMatchKnownProduct() async throws {
        let original = try JSONDecoder().decode(ProductPublishRequest.self, from: fixture("name-only-valid"))
        let request = ProductPublishRequest(operationID: original.operationID, clientRevisionID: original.clientRevisionID,
            productID: UUID().uuidString, expectedServerRevision: "1", consentVersion: original.consentVersion,
            consentGeneration: original.consentGeneration, product: original.product)
        let t = FakeCommunityTransport([
            .response(status: 200, body: String(decoding: try fixture("capabilities-resolution-valid"), as: UTF8.self)),
            .response(status: 200, body: String(decoding: try fixture("resolution-committed-valid"), as: UTF8.self))
        ])
        await expect(.unavailable) { try await self.client(t).resolvePublishForWithdrawal(request, expectedOwnerID: self.owner) }
        XCTAssertEqual(t.requests.count, 2)
    }
    func testResolveChecksOwnerBeforeRefreshAndRejectsWrongOwnerRefresh() async throws {
        let request = try JSONDecoder().decode(ProductPublishRequest.self, from: fixture("name-only-valid"))
        let t = FakeCommunityTransport()
        await expect(.ownerMismatch) { try await self.client(t, expired: true).resolvePublishForWithdrawal(request, expectedOwnerID: UUID()) }
        XCTAssertTrue(t.requests.isEmpty)
        let original = testSession(expiresAt: testNow)
        let store = InMemoryCommunitySessionStore(original)
        let wrong = FakeCommunityTransport([.response(status: 200, body: refreshedBody.replacingOccurrences(of: testUserID, with: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))])
        let c = CommunityClient(config: try makeConfig(), transport: wrong, store: store, now: { testNow })
        await expect(.unauthorized) { try await c.resolvePublishForWithdrawal(request, expectedOwnerID: self.owner) }
        XCTAssertEqual(try store.load(), original)
        XCTAssertEqual(wrong.requests.count, 1)
        XCTAssertFalse(wrong.requests.contains { $0.url!.path.contains("/rpc/") })
    }
    func testResolutionRequestPreservesRawUnicodeDecimalAndUUIDBytes() async throws {
        let operation = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let request = ProductPublishRequest(operationID: operation, clientRevisionID: operation.lowercased(), consentVersion: 2, consentGeneration: "999",
            product: ProductContentDTO(name: "Cafe\u{301}", kind: .food, basis: .per100g,
                facts: [ProductFactDTO(key: "protein", displayName: "Protein", state: .known, amount: "1.000", unit: .g)]))
        let t = FakeCommunityTransport([
            .response(status: 200, body: String(decoding: try fixture("capabilities-resolution-valid"), as: UTF8.self)),
            .response(status: 200, body: "{\"outcome\":\"canceled_before_commit\",\"operation_id\":\"\(operation.lowercased())\",\"replayed\":true}")
        ])
        let result = try await client(t).resolvePublishForWithdrawal(request, expectedOwnerID: owner)
        XCTAssertEqual(result, .canceledBeforeCommit(operationID: UUID(uuidString: operation)!, replayed: true))
        XCTAssertEqual(t.requests[1].httpBody, CommunityProductsAPI.wrapped(try request.canonicalBody()))
    }
    func testPublishAllowlistLosslessStates() async throws {
        let request = try JSONDecoder().decode(ProductPublishRequest.self, from: fixture("fact-states-valid"))
        let transport = FakeCommunityTransport([.response(status: 200, body: String(decoding: try fixture("receipt-valid"), as: UTF8.self))])
        let result = try await client(transport).publish(request, expectedOwnerID: owner)
        XCTAssertEqual(result.acknowledgedRevision, "1")
        let sent = try bodyJSON(XCTUnwrap(transport.requests.first))
        XCTAssertEqual(Set(sent.keys), ["p_request"])
        let body = try XCTUnwrap(sent["p_request"] as? NSDictionary)
        XCTAssertEqual(body, try JSONSerialization.jsonObject(with: fixture("fact-states-valid")) as? NSDictionary)
        XCTAssertEqual(transport.requests[0].url?.path, "/rest/v1/rpc/submit_catalog_product_v2")
    }
    func testCanonicalRendererAndValidation() throws {
        XCTAssertEqual(try ProductWire.canonical(JSONSerialization.jsonObject(with: fixture("renderer-input"))), try fixture("renderer-expected"))
        for name in ["exact-16384-valid", "key-identity-valid", "unicode-120-valid", "amount-max-valid"] {
            let body = try JSONDecoder().decode(ProductPublishRequest.self, from: fixture(name)).canonicalBody()
            if name == "exact-16384-valid" { XCTAssertEqual(body.count, 16384) }
        }
        for name in ["oversize-16385-invalid", "unicode-121-invalid", "key-duplicate-invalid", "nul-text-invalid", "amount-over-max-invalid", "dimension-invalid", "unknown-standard-invalid", "threshold-amount-invalid", "nested-private-invalid", "serving-private-invalid"] {
            XCTAssertThrowsError(try JSONDecoder().decode(ProductPublishRequest.self, from: fixture(name)).canonicalBody(), name)
        }
    }
    func testReceiptCurrentRevisionSeparateFromAcknowledgment() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("receipt-valid")) as? [String: Any])
        object["operation_id"] = "00000000-0000-4000-8000-000000000004"; object["current_revision"] = "9"; object["current_state"] = "withdrawn"; object["publication"] = NSNull(); object["replayed"] = true
        let t = FakeCommunityTransport([.response(status: 200, body: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))])
        let r = try await client(t).withdraw(JSONDecoder().decode(ProductWithdrawRequest.self, from: fixture("withdraw-valid")), expectedOwnerID: owner)
        XCTAssertEqual(r.acknowledgedRevision, "1"); XCTAssertEqual(r.currentRevision, "9"); XCTAssertEqual(r.currentState, .withdrawn); XCTAssertNil(r.publication)
    }
    func testOwnerBeforeAndAfterRefresh() async throws {
        let t = FakeCommunityTransport()
        await expect(.ownerMismatch) { try await self.client(t, expired: true).acknowledgeConsent(version: 2, expectedOwnerID: UUID()) }
        XCTAssertTrue(t.requests.isEmpty)
        let changed = refreshedBody.replacingOccurrences(of: testUserID, with: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        let refresh = FakeCommunityTransport([.response(status: 200, body: changed)])
        await expect(.unauthorized) { try await self.client(refresh, expired: true).acknowledgeConsent(version: 2, expectedOwnerID: self.owner) }
        XCTAssertEqual(refresh.requests.count, 1); XCTAssertEqual(refresh.requests[0].url?.path, "/auth/v1/token")
    }
    func testLegacyUnionAndSearchCursor() async throws {
        for name in ["legacy-public-product-valid", "legacy-alternative-valid"] {
            let p = try JSONDecoder().decode(CommunityProduct.self, from: fixture(name))
            let labels = ([p.product] + p.alternatives.map(\.product)).compactMap { if case .legacyLabel(let l) = $0 { return l }; return nil }
            let l = try XCTUnwrap(labels.first)
            XCTAssertEqual(l.contentType, "legacy_label"); XCTAssertNil(l.kind); XCTAssertNil(l.serving)
            XCTAssertEqual(l.nutrients["salt"], Decimal(1)); XCTAssertNil(l.nutrients["sodium"])
            XCTAssertEqual(l.rawServingText, "one original scoop")
        }
        let t = FakeCommunityTransport([.response(status: 200, body: String(decoding: try fixture("legacy-search-response-valid"), as: UTF8.self))])
        let p = try await client(t).searchProducts(query: "  oats  ", kind: nil, cursor: "opaque%/_\\")
        XCTAssertEqual(p.products.count, 1)
        let b = try bodyJSON(XCTUnwrap(t.requests.first)); XCTAssertEqual(b["p_query"] as? String, "oats"); XCTAssertEqual(b["p_cursor"] as? String, "opaque%/_\\")
    }
    func testErrorsCancellationAndMissingDetail() async throws {
        for (status, body, expected) in [(409, "{}", ProductAPIError.revisionConflict(currentRevision: nil, currentState: nil)), (400, #"{"code":"22P05"}"#, .invalidRequest(field: nil)), (404, #"{"code":"PGRST202"}"#, .unsupportedBackend), (503, "{}", .unavailable)] {
            await expect(expected) { try await self.client(FakeCommunityTransport([.response(status: status, body: body)])).capabilities() }
        }
        await expect(.rateLimited(retryAfterSeconds: "17")) { try await self.client(ProductTestTransport(status: 429, headers: ["Retry-After": "17"])).capabilities() }
        for error: any Error in [CancellationError(), URLError(.cancelled)] {
            do { _ = try await client(ProductTestTransport(error: error)).capabilities(); XCTFail("expected cancellation") }
            catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
        }
        await expect(.notFound) { try await self.client(FakeCommunityTransport([.response(status: 200, body: #"{"product":null}"#)])).product(id: UUID()) }
        await expect(.unavailable) { try await self.client(FakeCommunityTransport([.response(status: 200, body: "[]")])).capabilities() }
    }
    func testInvalidSearchMakesNoRequest() async throws {
        let t = FakeCommunityTransport()
        for q in ["a", "ab\0cd", String(repeating: "x", count: 121)] {
            await expect(.invalidRequest(field: "p_query")) { try await self.client(t).searchProducts(query: q, kind: nil, cursor: nil) }
        }
        XCTAssertTrue(t.requests.isEmpty)
    }
    func testAllReadAndConsentDTOs() async throws {
        let t = FakeCommunityTransport([
            .response(status: 200, body: String(decoding: try fixture("capabilities-valid"), as: UTF8.self)),
            .response(status: 200, body: String(decoding: try fixture("consent-receipt-valid"), as: UTF8.self)),
            .response(status: 200, body: String(decoding: try fixture("own-state-none-valid"), as: UTF8.self)),
            .response(status: 200, body: String(decoding: try fixture("legacy-detail-response-valid"), as: UTF8.self)),
            .response(status: 200, body: String(decoding: try fixture("legacy-receipt-valid"), as: UTF8.self))
        ])
        let c: any CommunityProductServicing = try client(t)
        let caps = try await c.capabilities(); XCTAssertEqual(caps.supportedVersion, 2)
        let consent = try await c.acknowledgeConsent(version: 2, expectedOwnerID: owner); XCTAssertTrue(consent.acknowledged)
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        let own = try await c.contribution(productID: id, expectedOwnerID: owner); XCTAssertEqual(own.currentState, .none); XCTAssertNil(own.currentRevision)
        let detail = try await c.product(id: id); if case .legacyLabel = detail.product {} else { XCTFail("legacy detail lost") }
        let publish = try JSONDecoder().decode(ProductPublishRequest.self, from: fixture("name-only-valid"))
        let receipt = try await c.publish(publish, expectedOwnerID: owner); if case .legacyLabel? = receipt.publication?.alternatives.first?.product {} else { XCTFail("legacy receipt lost") }
        XCTAssertEqual(try bodyJSON(t.requests[1])["p_version"] as? Int, 2)
    }
    func testTypedApplicationErrorsKeepSafeMetadata() async throws {
        let codes: [(String, ProductAPIError)] = [
            ("invalid_request", .invalidRequest(field: "product.barcode")),
            ("revision_conflict", .revisionConflict(currentRevision: "2", currentState: .active)),
            ("operation_conflict", .operationConflict), ("rejected", .rejected),
            ("consent_required", .consentRequired(generation: "4")),
            ("rate_limited", .rateLimited(retryAfterSeconds: "12")), ("unauthorized", .unauthorized)
        ]
        for (code, expected) in codes {
            let detail = ["code": code, "field": "product.barcode", "current_revision": "2", "current_state": "active", "consent_generation": "4", "retry_after_seconds": "12"]
            let body = try JSONSerialization.data(withJSONObject: ["code": "P0001", "details": String(decoding: JSONSerialization.data(withJSONObject: detail), as: UTF8.self)])
            await expect(expected) { try await self.client(FakeCommunityTransport([.response(status: 400, body: String(decoding: body, as: UTF8.self))])).capabilities() }
        }
    }
    func testKnownIUAndDecimalUUIDSpellingSurvive() throws {
        let content = ProductContentDTO(name: "Synthetic", kind: .supplement, basis: .perServing,
            serving: ProductServingDTO(quantity: "2.000", unit: .capsule), facts: [
                ProductFactDTO(key: "ingredient:test", displayName: "Test", state: .known, amount: "400.00", unit: .iu)
            ])
        let operation = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let request = ProductPublishRequest(operationID: operation, clientRevisionID: operation.lowercased(), consentVersion: 2, consentGeneration: "42", product: content)
        let data = try request.canonicalBody()
        let decoded = try JSONDecoder().decode(ProductPublishRequest.self, from: data)
        XCTAssertEqual(decoded.operationID, operation); XCTAssertEqual(decoded.product.facts[0].amount, "400.00")
        XCTAssertEqual(decoded.product.serving?.quantity, "2.000"); XCTAssertEqual(decoded.product.facts[0].unit, .iu)
        XCTAssertEqual(try decoded.canonicalBody(), data)
    }
    func testMalformedReceiptsNeverAcknowledge() async throws {
        let request = try JSONDecoder().decode(ProductPublishRequest.self, from: fixture("name-only-valid"))
        for mutation in ["current_revision", "source", "verification", "operation_id"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("receipt-valid")) as? [String: Any])
            if mutation == "current_revision" { object.removeValue(forKey: mutation) }
            else if mutation == "operation_id" { object[mutation] = UUID().uuidString }
            else {
                var publication = object["publication"] as! [String: Any]
                var nested = publication[mutation] as! [String: Any]
                nested[mutation == "source" ? "representative_revision" : "source"] = "wrong"
                publication[mutation] = nested; object["publication"] = publication
            }
            let body = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            await expect(.unavailable) { try await self.client(FakeCommunityTransport([.response(status: 200, body: body)])).publish(request, expectedOwnerID: self.owner) }
        }
    }
    func testOptionalFactKeysAreStateSpecific() throws {
        for json in [
            #"{"key":"protein","display_name":"Protein","state":"unknown","amount":null}"#,
            #"{"key":"protein","display_name":"Protein","state":"not_applicable","unit":null}"#,
            #"{"key":"protein","display_name":"Protein","state":"below_reporting_threshold","unit":null}"#
        ] { XCTAssertThrowsError(try JSONDecoder().decode(ProductFactDTO.self, from: Data(json.utf8))) }
        XCTAssertThrowsError(try JSONDecoder().decode(ProductServingDTO.self, from: Data(#"{"quantity":"1","unit":"g","text":null}"#.utf8)))
    }

    func testAccountReplacementDuringRefreshNeverSendsRPC() async throws {
        let transport = ProductSwitchTransport()
        let c = try client(transport, expired: true)
        let owner = self.owner
        let operation = Task { try await c.acknowledgeConsent(version: 2, expectedOwnerID: owner) }
        var entered = transport.entered.makeAsyncIterator()
        _ = await entered.next()
        _ = try await c.auth.signInWithApple(idToken: "synthetic-id", nonce: "synthetic-nonce")
        transport.release()
        await expect(.unauthorized) { try await operation.value }
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertFalse(transport.requests.contains { $0.url?.path.contains("/rpc/") == true })
        await expect(.ownerMismatch) { try await c.acknowledgeConsent(version: 2, expectedOwnerID: self.owner) }
        XCTAssertEqual(transport.requests.count, 2)
    }
    func testRefreshCancellationStaysCancellation() async throws {
        do {
            _ = try await client(ProductTestTransport(error: URLError(.cancelled)), expired: true).acknowledgeConsent(version: 2, expectedOwnerID: owner)
            XCTFail("expected cancellation")
        } catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
    }
    func testPublicationPrevalidationRejectsNULAndLongNFCRunsWithoutTransport() async throws {
        let t = FakeCommunityTransport()
        for name in ["Synthetic\0name", String(repeating: "a", count: 121), String(repeating: "\u{0344}", count: 61)] {
            // Build an unchecked editor DTO to exercise validation before any transport.
            let product = ProductContentDTO(name: name, kind: .food, basis: .per100g, facts: [])
            let request = ProductPublishRequest(operationID: UUID().uuidString, clientRevisionID: UUID().uuidString, consentVersion: 2, consentGeneration: "0", product: product)
            do { _ = try await client(t).publish(request, expectedOwnerID: owner); XCTFail("invalid product sent") }
            catch let e as ProductAPIError { if case .invalidRequest = e {} else { XCTFail("unexpected \(e)") } }
        }
        let long = "a" + String(repeating: "\u{301}", count: 119)
        let dto = try ProductContentDTO(CustomProductContent(name: long, kind: .food, basis: .per100g))
        XCTAssertEqual(dto.name.unicodeScalars.count, 120)
        XCTAssertTrue(dto.name.utf8.elementsEqual(long.utf8))
        XCTAssertTrue(t.requests.isEmpty)
    }

    func testMalformedDecimalAndGenerationSpellingsRejectTerminalNewlines() throws {
        for amount in ["1\n", "1\r", "1e0", "+1", "01", "0.0000000", "NaN", "Infinity"] {
            let fact = ProductFactDTO(key: "protein", displayName: "Protein", state: .known, amount: amount, unit: .g)
            XCTAssertThrowsError(try JSONEncoder().encode(fact), amount.debugDescription)
        }
        let product = ProductContentDTO(name: "Synthetic", kind: .food, basis: .per100g, facts: [])
        let request = ProductPublishRequest(operationID: UUID().uuidString, clientRevisionID: UUID().uuidString, consentVersion: 2, consentGeneration: "0\n", product: product)
        XCTAssertThrowsError(try request.canonicalBody())
    }
    func testSemanticPublicationFlagsCannotAcknowledgeInventedVerification() async throws {
        let request = try JSONDecoder().decode(ProductPublishRequest.self, from: fixture("name-only-valid"))
        for field in ["missing_facts", "verification"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("receipt-valid")) as? [String: Any])
            var publication = object["publication"] as! [String: Any]
            if field == "missing_facts" { publication[field] = false }
            else { publication[field] = ["status": "verified", "source": "owner_reviewed"] }
            object["publication"] = publication
            let body = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            await expect(.unavailable) { try await self.client(FakeCommunityTransport([.response(status: 200, body: body)])).publish(request, expectedOwnerID: self.owner) }
        }
    }

    func testCanceledSuccessfulTransportCannotAcknowledge() async throws {
        let body = String(decoding: try fixture("capabilities-valid"), as: UTF8.self)
        let c = try client(ProductTestTransport(body: body, cancel: true))
        let call = Task { try await c.capabilities() }
        do { _ = try await call.value; XCTFail("canceled transport returned success") }
        catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
    }

    func testWrongOwnerRefreshNeverPersistsThroughLegacyOrOwnerBoundSession() async throws {
        let original = testSession(expiresAt: testNow)
        let changed = refreshedBody.replacingOccurrences(of: testUserID, with: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        for ownerBound in [false, true] {
            let store = InMemoryCommunitySessionStore(original)
            let transport = FakeCommunityTransport([.response(status: 200, body: changed)])
            let c = CommunityClient(config: try makeConfig(), transport: transport, store: store, now: { testNow })
            if ownerBound {
                do { _ = try await c.acknowledgeConsent(version: 2, expectedOwnerID: owner) } catch {}
            } else {
                do { _ = try await c.auth.validSession() } catch {}
            }
            XCTAssertEqual(try store.load(), original, "a refresh cannot change stored owner")
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testOwnerBoundCallJoiningLegacyRefreshCannotAdoptWrongAccount() async throws {
        let original = testSession(expiresAt: testNow)
        let store = ProductObservingStore(original)
        let transport = ProductSwitchTransport(refreshedUserID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        let c = CommunityClient(config: try makeConfig(), transport: transport, store: store, now: { testNow })
        let legacy = Task { try await c.auth.validSession() }
        var entered = transport.entered.makeAsyncIterator(); _ = await entered.next()
        let owner = self.owner
        let publication = Task { try await c.acknowledgeConsent(version: 2, expectedOwnerID: owner) }
        var joined = store.secondLoad.makeAsyncIterator(); _ = await joined.next()
        transport.release()
        do { _ = try await legacy.value; XCTFail("legacy refresh adopted wrong account") } catch {}
        await expect(.unauthorized) { try await publication.value }
        XCTAssertEqual(store.load(), original)
        XCTAssertFalse(transport.requests.contains { $0.url?.path.contains("/rpc/") == true })
    }

    func testRefreshOwnerIdentityAllowsUUIDCaseAndOpaqueLegacyIDs() async throws {
        for id in ["AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "synthetic-owner"] {
            let original = CommunitySession(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: testNow, userID: id, email: nil)
            let store = InMemoryCommunitySessionStore(original)
            let body = refreshedBody.replacingOccurrences(of: testUserID, with: id.lowercased())
            let t = FakeCommunityTransport([.response(status: 200, body: body)])
            let c = CommunityClient(config: try makeConfig(), transport: t, store: store, now: { testNow })
            let renewed = try await c.auth.validSession()
            XCTAssertEqual(renewed.userID, id.lowercased())
            XCTAssertEqual(try store.load(), renewed); XCTAssertEqual(t.requests.count, 1)
        }
    }

    private func expect<T>(_ expected: ProductAPIError, _ operation: () async throws -> T) async {
        do { _ = try await operation(); XCTFail("expected \(expected)") }
        catch let e as ProductAPIError { XCTAssertEqual(e, expected) }
        catch { XCTFail("unexpected \(type(of: error))") }
    }
}
private struct ProductTestTransport: CommunityTransport, @unchecked Sendable {
    var status = 200; var headers: [String: String] = [:]; var error: (any Error)?; var body = "{}"; var cancel = false
    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let error { throw error }; if cancel { withUnsafeCurrentTask { $0?.cancel() } }; return (Data(body.utf8), HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

private final class ProductSwitchTransport: CommunityTransport, @unchecked Sendable {
    let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let gate: AsyncStream<Void>
    private let gateContinuation: AsyncStream<Void>.Continuation
    private let refreshedUserID: String
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    init(refreshedUserID: String = testUserID) {
        self.refreshedUserID = refreshedUserID
        (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        (gate, gateContinuation) = AsyncStream<Void>.makeStream()
    }
    func release() { gateContinuation.yield(()) }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        let refresh = queryItems(request)["grant_type"] == "refresh_token"
        if refresh { enteredContinuation.yield(()); for await _ in gate { break } }
        let body = refresh ? refreshedBody.replacingOccurrences(of: testUserID, with: refreshedUserID) : tokenBody.replacingOccurrences(of: testUserID, with: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// Signals the owner-bound actor entry, so the shared-refresh assertion has an actual join barrier.
private final class ProductObservingStore: CommunitySessionStore, @unchecked Sendable {
    let secondLoad: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var session: CommunitySession?
    private var loads = 0
    init(_ session: CommunitySession) {
        self.session = session
        (secondLoad, continuation) = AsyncStream<Void>.makeStream()
    }
    func load() -> CommunitySession? {
        lock.withLock {
            loads += 1
            if loads == 2 { continuation.yield(()) }
            return session
        }
    }
    func save(_ value: CommunitySession) throws { lock.withLock { session = value } }
    func clear() { lock.withLock { session = nil } }
}
