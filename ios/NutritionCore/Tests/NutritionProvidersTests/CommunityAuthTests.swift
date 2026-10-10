import Foundation
import XCTest
@testable import NutritionProviders

final class CommunityAuthTests: XCTestCase {
    func testSignInWithAppleStoresSession() async throws {
        let transport = FakeCommunityTransport([.response(status: 200, body: tokenBody)])
        let store = InMemoryCommunitySessionStore()
        let auth = try makeAuth(transport: transport, store: store)

        let session = try await auth.signInWithApple(idToken: "test-apple-token", nonce: "test-nonce")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/auth/v1/token")
        XCTAssertEqual(request.url?.query, "grant_type=id_token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "test-anon-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try bodyJSON(request)
        XCTAssertEqual(body["provider"] as? String, "apple")
        XCTAssertEqual(body["id_token"] as? String, "test-apple-token")
        XCTAssertEqual(body["nonce"] as? String, "test-nonce")
        XCTAssertEqual(session.accessToken, "test-access-token")
        XCTAssertEqual(session.userID, testUserID)
        XCTAssertEqual(session.expiresAt, testNow.addingTimeInterval(3600))
        XCTAssertEqual(store.load(), session)
    }

    func testRequestEmailCodeSendsAddressAndCreatesAccount() async throws {
        let transport = FakeCommunityTransport([.response(status: 200, body: "{}")])
        let auth = try makeAuth(transport: transport)

        try await auth.requestEmailCode(email: "person@example.com")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/auth/v1/otp")
        let body = try bodyJSON(request)
        XCTAssertEqual(body["email"] as? String, "person@example.com")
        XCTAssertEqual(body["create_user"] as? Bool, true)
    }

    func testVerifyEmailCodeStoresSession() async throws {
        let transport = FakeCommunityTransport([.response(status: 200, body: tokenBody)])
        let store = InMemoryCommunitySessionStore()
        let auth = try makeAuth(transport: transport, store: store)

        let session = try await auth.verifyEmailCode(email: "person@example.com", code: "123456")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/auth/v1/verify")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "test-anon-key")
        let body = try bodyJSON(request)
        XCTAssertEqual(body["type"] as? String, "email")
        XCTAssertEqual(body["email"] as? String, "person@example.com")
        XCTAssertEqual(body["token"] as? String, "123456")
        XCTAssertEqual(session.email, "person@example.com")
        XCTAssertEqual(store.load(), session)
    }

    func testFreshSessionIsReturnedWithoutARequest() async throws {
        let transport = FakeCommunityTransport()
        let store = InMemoryCommunitySessionStore(testSession())
        let auth = try makeAuth(transport: transport, store: store)

        let session = try await auth.validSession()

        XCTAssertEqual(session, testSession())
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testSessionNearExpiryIsRefreshed() async throws {
        let transport = FakeCommunityTransport([.response(status: 200, body: refreshedBody)])
        let store = InMemoryCommunitySessionStore(testSession(expiresAt: testNow.addingTimeInterval(30)))
        let auth = try makeAuth(transport: transport, store: store)

        let session = try await auth.validSession()

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/auth/v1/token")
        XCTAssertEqual(request.url?.query, "grant_type=refresh_token")
        XCTAssertEqual(try bodyJSON(request)["refresh_token"] as? String, "test-refresh-token")
        XCTAssertEqual(session.accessToken, "refreshed-access-token")
        XCTAssertEqual(session.refreshToken, "refreshed-refresh-token")
        XCTAssertEqual(store.load(), session)
    }

    func testRejectedRefreshClearsStore() async throws {
        let transport = FakeCommunityTransport([
            .response(status: 400, body: #"{"code":400,"error_code":"invalid_grant","msg":"Invalid Refresh Token"}"#),
        ])
        let store = InMemoryCommunitySessionStore(testSession(expiresAt: testNow.addingTimeInterval(30)))
        let auth = try makeAuth(transport: transport, store: store)

        await assertCommunityError(.signedOut) { try await auth.validSession() }
        XCTAssertNil(store.load())
    }

    func testNetworkFailureDuringRefreshKeepsStore() async throws {
        let transport = FakeCommunityTransport([.failure(URLError(.notConnectedToInternet))])
        let stored = testSession(expiresAt: testNow.addingTimeInterval(30))
        let store = InMemoryCommunitySessionStore(stored)
        let auth = try makeAuth(transport: transport, store: store)

        await assertCommunityError(.network) { try await auth.validSession() }
        XCTAssertEqual(store.load(), stored)
    }

    func testMissingSessionIsSignedOutWithoutARequest() async throws {
        let transport = FakeCommunityTransport()
        let auth = try makeAuth(transport: transport)

        await assertCommunityError(.signedOut) { try await auth.validSession() }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testSignOutSendsLogoutWithBearerAndClearsStore() async throws {
        let transport = FakeCommunityTransport([.response(status: 204, body: "")])
        let store = InMemoryCommunitySessionStore(testSession())
        let auth = try makeAuth(transport: transport, store: store)

        await auth.signOut()

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/auth/v1/logout")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertNil(store.load())
    }

    func testSignOutClearsStoreEvenWhenRequestFails() async throws {
        let transport = FakeCommunityTransport([.failure(URLError(.timedOut))])
        let store = InMemoryCommunitySessionStore(testSession())
        let auth = try makeAuth(transport: transport, store: store)

        await auth.signOut()

        XCTAssertNil(store.load())
    }
}
