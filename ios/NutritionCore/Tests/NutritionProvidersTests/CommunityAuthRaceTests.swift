import Foundation
import XCTest
@testable import NutritionProviders

/// A transport that holds a token refresh until the test lets it go, so a sign out can land in between.
final class GatedRefreshTransport: CommunityTransport, @unchecked Sendable {
    let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let gate: AsyncStream<Void>
    private let gateContinuation: AsyncStream<Void>.Continuation

    init() {
        (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        (gate, gateContinuation) = AsyncStream<Void>.makeStream()
    }

    func release() {
        gateContinuation.yield(())
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isRefresh = request.url?.absoluteString.contains("grant_type=refresh_token") == true
        if isRefresh {
            enteredContinuation.yield(())
            for await _ in gate { break }
        }
        let body = isRefresh ? refreshedBody : "{}"
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), http)
    }
}

final class CommunityAuthRaceTests: XCTestCase {
    /// A refresh that finishes after the person signed out must not write the session back.
    func testSignOutDuringRefreshIsNotUndone() async throws {
        let store = InMemoryCommunitySessionStore()
        try store.save(testSession(expiresAt: testNow.addingTimeInterval(10)))
        let transport = GatedRefreshTransport()
        let auth = CommunityAuth(config: try makeConfig(), transport: transport, store: store, now: { testNow })

        let refresh = Task { try await auth.validSession() }
        var inFlight = transport.entered.makeAsyncIterator()
        _ = await inFlight.next()

        await auth.signOut()
        transport.release()
        let result = await refresh.result

        XCTAssertNil(store.load())
        if case .success = result {
            XCTFail("the refresh must not hand back a session after sign out")
        }
    }
}
