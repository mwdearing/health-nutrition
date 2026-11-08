import Foundation
import XCTest
@testable import NutritionProviders

/// A transport that holds its reply until released, so a test can cancel the caller while the request is in flight.
private final class GatedCommunityTransport: CommunityTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var started = false

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { started = true }
        await withCheckedContinuation { (next: CheckedContinuation<Void, Never>) in
            let resume = lock.withLock { () -> Bool in
                if released { return true }
                continuation = next
                return false
            }
            if resume { next.resume() }
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(tokenBody.utf8), http)
    }

    var hasStarted: Bool { lock.withLock { started } }

    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume()
    }
}

/// A sign-in the server has accepted must not be lost because the view that asked for it went away.
final class CommunityAuthCancellationTests: XCTestCase {
    private func makeGatedAuth(
        _ transport: GatedCommunityTransport,
        store: CommunitySessionStore = InMemoryCommunitySessionStore()
    ) throws -> CommunityAuth {
        CommunityAuth(config: try makeConfig(), transport: transport, store: store, now: { testNow })
    }

    private func waitUntilStarted(_ transport: GatedCommunityTransport) async throws {
        for _ in 0..<500 where !transport.hasStarted { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(transport.hasStarted, "the request never reached the transport")
    }

    func testAppleSignInCanceledMidRequestStillKeepsTheSession() async throws {
        let transport = GatedCommunityTransport()
        let store = InMemoryCommunitySessionStore()
        let auth = try makeGatedAuth(transport, store: store)

        let task = Task { try await auth.signInWithApple(idToken: "test-apple-token", nonce: "test-nonce") }
        try await waitUntilStarted(transport)
        task.cancel()
        transport.release()

        let session = try await task.value
        XCTAssertEqual(session.userID, testUserID)
        XCTAssertEqual(try store.load(), session, "a sign-in the server accepted was dropped on cancellation")
    }

    func testEmailCodeVerifyCanceledMidRequestStillKeepsTheSession() async throws {
        let transport = GatedCommunityTransport()
        let store = InMemoryCommunitySessionStore()
        let auth = try makeGatedAuth(transport, store: store)

        let task = Task { try await auth.verifyEmailCode(email: "person@example.com", code: "123456") }
        try await waitUntilStarted(transport)
        task.cancel()
        transport.release()

        let session = try await task.value
        XCTAssertEqual(try store.load(), session, "a verified code was dropped on cancellation")
    }

    func testEmailCodeRequestStillStopsWhenCanceled() async throws {
        let transport = GatedCommunityTransport()
        let auth = try makeGatedAuth(transport)

        let task = Task { try await auth.requestEmailCode(email: "person@example.com") }
        try await waitUntilStarted(transport)
        task.cancel()
        transport.release()

        do {
            try await task.value
            XCTFail("a canceled code request should not complete")
        } catch is CancellationError {
        }
    }
}
