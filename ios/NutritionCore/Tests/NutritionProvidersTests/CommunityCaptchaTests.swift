import Foundation
import XCTest
@testable import NutritionProviders

/// Fake challenge provider. Each call issues a new token, as a real challenge does, and counts the issued tokens.
/// A test can make the next call fail instead.
final class FakeCaptcha: CommunityCaptcha, @unchecked Sendable {
    private let lock = NSLock()
    private var issued = 0
    private var failure: Error?

    var issuedCount: Int {
        lock.withLock { issued }
    }

    func fail(with error: Error) {
        lock.withLock { failure = error }
    }

    func token() async throws -> String {
        let outcome: Result<String, Error> = lock.withLock {
            if let failure {
                return .failure(failure)
            }
            issued += 1
            return .success("captcha-token-\(issued)")
        }
        return try outcome.get()
    }
}

/// The captcha object a sign-in request sends, or nil when the body has none.
private func captchaToken(in request: URLRequest) throws -> String? {
    let body = try bodyJSON(request)
    let security = body["gotrue_meta_security"] as? [String: Any]
    return security?["captcha_token"] as? String
}

final class CommunityCaptchaTests: XCTestCase {
    private func makeCaptchaAuth(
        _ transport: FakeCommunityTransport,
        captcha: FakeCaptcha?,
        store: InMemoryCommunitySessionStore = InMemoryCommunitySessionStore()
    ) throws -> CommunityAuth {
        CommunityAuth(config: try makeConfig(), transport: transport, store: store, captcha: captcha, now: { testNow })
    }

    func testSignInWithAppleSendsAFreshCaptchaToken() async throws {
        let transport = FakeCommunityTransport([.response(status: 200, body: tokenBody)])
        let captcha = FakeCaptcha()
        let auth = try makeCaptchaAuth(transport, captcha: captcha)

        _ = try await auth.signInWithApple(idToken: "test-apple-token", nonce: "test-nonce")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(try captchaToken(in: request), "captcha-token-1")
        XCTAssertEqual(captcha.issuedCount, 1)
        let body = try bodyJSON(request)
        XCTAssertEqual(body["id_token"] as? String, "test-apple-token")
    }

    func testRequestEmailCodeSendsAFreshCaptchaToken() async throws {
        let transport = FakeCommunityTransport([.response(status: 200, body: "{}")])
        let captcha = FakeCaptcha()
        let auth = try makeCaptchaAuth(transport, captcha: captcha)

        try await auth.requestEmailCode(email: "person@example.com")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/auth/v1/otp")
        XCTAssertEqual(try captchaToken(in: request), "captcha-token-1")
        XCTAssertEqual(try bodyJSON(request)["create_user"] as? Bool, true)
    }

    func testEachSignInUsesItsOwnToken() async throws {
        let transport = FakeCommunityTransport([
            .response(status: 200, body: "{}"),
            .response(status: 200, body: tokenBody),
        ])
        let captcha = FakeCaptcha()
        let auth = try makeCaptchaAuth(transport, captcha: captcha)

        try await auth.requestEmailCode(email: "person@example.com")
        _ = try await auth.verifyEmailCode(email: "person@example.com", code: "123456")

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(try captchaToken(in: transport.requests[0]), "captcha-token-1")
        XCTAssertEqual(try captchaToken(in: transport.requests[1]), "captcha-token-2")
        XCTAssertEqual(captcha.issuedCount, 2)
    }

    func testRefreshAndLogoutCarryNoToken() async throws {
        let transport = FakeCommunityTransport([
            .response(status: 200, body: refreshedBody),
            .response(status: 204, body: ""),
        ])
        let captcha = FakeCaptcha()
        let store = InMemoryCommunitySessionStore(testSession(expiresAt: testNow.addingTimeInterval(30)))
        let auth = try makeCaptchaAuth(transport, captcha: captcha, store: store)

        _ = try await auth.validSession()
        await auth.signOut()

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].url?.query, "grant_type=refresh_token")
        let refreshToken = try captchaToken(in: transport.requests[0])
        XCTAssertNil(refreshToken)
        XCTAssertNil(transport.requests[1].httpBody)
        XCTAssertEqual(captcha.issuedCount, 0)
    }

    func testWithoutAProviderTheBodiesAreUnchanged() async throws {
        let transport = FakeCommunityTransport([.response(status: 200, body: "{}")])
        let auth = try makeCaptchaAuth(transport, captcha: nil)

        try await auth.requestEmailCode(email: "person@example.com")

        let body = try bodyJSON(try XCTUnwrap(transport.requests.first))
        XCTAssertEqual(Set(body.keys), ["email", "create_user"])
    }

    func testProviderFailureAbortsBeforeAnyRequest() async throws {
        let transport = FakeCommunityTransport()
        let captcha = FakeCaptcha()
        captcha.fail(with: URLError(.userCancelledAuthentication))
        let auth = try makeCaptchaAuth(transport, captcha: captcha)

        await assertCommunityError(.captcha) {
            try await auth.requestEmailCode(email: "person@example.com")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testServerCaptchaFailureMapsToCaptchaError() async throws {
        let transport = FakeCommunityTransport([
            .response(
                status: 400,
                body: #"{"code":400,"error_code":"captcha_failed","msg":"captcha protection: no captcha_token found"}"#
            ),
        ])
        let auth = try makeCaptchaAuth(transport, captcha: nil)

        await assertCommunityError(.captcha) {
            try await auth.requestEmailCode(email: "person@example.com")
        }
    }

    func testClientPassesTheProviderToItsSignIn() async throws {
        let transport = FakeCommunityTransport([.response(status: 200, body: tokenBody)])
        let captcha = FakeCaptcha()
        let client = CommunityClient(
            config: try makeConfig(),
            transport: transport,
            store: InMemoryCommunitySessionStore(),
            captcha: captcha,
            now: { testNow }
        )

        _ = try await client.auth.signInWithApple(idToken: "test-apple-token", nonce: "test-nonce")

        XCTAssertEqual(try captchaToken(in: try XCTUnwrap(transport.requests.first)), "captcha-token-1")
    }
}
