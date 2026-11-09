import Foundation
import XCTest
@testable import NutritionProviders

/// A transport that holds its reply until released, so a test can cancel the caller while the request is in flight.
private final class GatedCommunityTransport: CommunityTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var started = false
    private var recorded: [URLRequest] = []

    var paths: [String] { lock.withLock { recorded.compactMap { $0.url?.path } } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { started = true; recorded.append(request) }
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

    /// The canceled caller returns at once with CancellationError; the work it started carries on by itself.
    private func expectCanceled(_ task: Task<some Any, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("a canceled caller should return CancellationError", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError", file: file, line: line)
        }
    }

    private func waitUntil(_ condition: () throws -> Bool) async throws {
        for _ in 0..<500 where try !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testAppleSignInCanceledMidRequestStillKeepsTheSession() async throws {
        let transport = GatedCommunityTransport()
        let store = InMemoryCommunitySessionStore()
        let auth = try makeGatedAuth(transport, store: store)

        let task = Task { try await auth.signInWithApple(idToken: "test-apple-token", nonce: "test-nonce") }
        try await waitUntilStarted(transport)
        task.cancel()
        transport.release()

        await expectCanceled(task)
        try await waitUntil { try store.load() != nil }
        XCTAssertEqual(try store.load()?.userID, testUserID, "a sign-in the server accepted was dropped on cancellation")
    }

    func testCanceledAppleSignInStillHandsTheAuthorizationCodeToTheServer() async throws {
        let transport = GatedCommunityTransport()
        let store = InMemoryCommunitySessionStore()
        let auth = try makeGatedAuth(transport, store: store)

        let task = Task {
            try await auth.signInWithApple(idToken: "test-apple-token", nonce: "test-nonce", authorizationCode: "test-auth-code")
        }
        try await waitUntilStarted(transport)
        task.cancel()
        transport.release()

        await expectCanceled(task)
        try await waitUntil { transport.paths.count >= 2 }
        XCTAssertEqual(transport.paths, ["/auth/v1/token", "/functions/v1/apple-grant"], "the single-use code was never handed off")
    }

    func testACanceledCallerReturnsWithoutWaitingForTheReply() async throws {
        let transport = GatedCommunityTransport()
        let store = InMemoryCommunitySessionStore()
        let auth = try makeGatedAuth(transport, store: store)

        let task = Task { try await auth.signInWithApple(idToken: "test-apple-token", nonce: "test-nonce") }
        try await waitUntilStarted(transport)
        task.cancel()

        // The transport is still holding its reply, so the caller must finish on its own.
        do {
            _ = try await task.value
            XCTFail("a canceled caller should not wait for the reply")
        } catch is CancellationError {
        }
        XCTAssertNil(try store.load(), "the reply had not arrived yet")

        transport.release()
        for _ in 0..<500 where try store.load() == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(try store.load()?.userID, testUserID, "the reply that arrived later was not saved")
    }

    func testEmailCodeVerifyCanceledMidRequestStillKeepsTheSession() async throws {
        let transport = GatedCommunityTransport()
        let store = InMemoryCommunitySessionStore()
        let auth = try makeGatedAuth(transport, store: store)

        let task = Task { try await auth.verifyEmailCode(email: "person@example.com", code: "123456") }
        try await waitUntilStarted(transport)
        task.cancel()
        transport.release()

        await expectCanceled(task)
        try await waitUntil { try store.load() != nil }
        XCTAssertEqual(try store.load()?.userID, testUserID, "a verified code was dropped on cancellation")
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
