import Foundation
import XCTest
@testable import NutritionProviders

/// A request transport with per-operation gates so lifecycle races are ordered by the test, not timing.
final class LifecycleTransport: CommunityTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let enteredContinuation: AsyncStream<String>.Continuation
    let entered: AsyncStream<String>
    private let refreshStatus: Int
    private let profileStatus: Int
    private var gates: [String: AsyncStream<Void>] = [:]
    private var gateContinuations: [String: AsyncStream<Void>.Continuation] = [:]
    private var recorded: [String] = []

    init(gated: Set<String>, refreshStatus: Int = 200, profileStatus: Int = 401) {
        self.profileStatus = profileStatus
        self.refreshStatus = refreshStatus
        (entered, enteredContinuation) = AsyncStream<String>.makeStream()
        for kind in gated {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            gates[kind] = stream
            gateContinuations[kind] = continuation
        }
    }

    var operations: [String] { lock.withLock { recorded } }

    func release(_ kind: String) {
        lock.withLock { gateContinuations[kind] }?.yield(())
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let kind: String
        switch request.url?.path {
        case "/auth/v1/logout": kind = "logout"
        case "/auth/v1/verify": kind = "verify"
        case "/rest/v1/profiles": kind = "profile"
        case "/rest/v1/rpc/delete_my_account": kind = "delete"
        case "/auth/v1/token":
            kind = request.url?.query?.contains("refresh_token") == true ? "refresh" : "signin"
        default: kind = "other"
        }
        let gate = lock.withLock {
            recorded.append(kind)
            return gates[kind]
        }
        if let gate {
            enteredContinuation.yield(kind)
            for await _ in gate { break }
        }

        let status: Int
        let body: String
        switch kind {
        case "signin":
            status = 200
            body = #"{"access_token":"new-access-token","refresh_token":"new-refresh-token","expires_in":3600,"user":{"id":"22222222-3333-4444-5555-666666666666","email":"new@example.com"}}"#
        case "refresh": status = refreshStatus; body = refreshStatus == 200 ? refreshedBody : "{}"
        case "delete": status = 204; body = ""
        case "profile": status = profileStatus; body = profileStatus == 403 ? #"{"code":"28000"}"# : "{}"
        default: status = 204; body = ""
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    func waitFor(_ expected: String) async {
        for await event in entered {
            if event == expected { return }
        }
        XCTFail("request did not reach its gate")
    }
}

final class FailingClearStore: CommunitySessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: CommunitySession?

    init(_ session: CommunitySession?) { self.session = session }
    func load() -> CommunitySession? { lock.withLock { session } }
    func save(_ session: CommunitySession) throws { lock.withLock { self.session = session } }
    func clear() throws { throw CommunityError.storage }
}

final class FailingLoadStore: CommunitySessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: CommunitySession?

    init(_ session: CommunitySession?) { self.session = session }
    func load() throws -> CommunitySession? { throw CommunityError.storage }
    func save(_ session: CommunitySession) throws { lock.withLock { self.session = session } }
    func clear() throws { lock.withLock { session = nil } }
    var storedSession: CommunitySession? { lock.withLock { session } }
}

final class FailingSecondReadStore: CommunitySessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: CommunitySession?
    private var readCount = 0

    init(_ session: CommunitySession?) { self.session = session }
    func load() throws -> CommunitySession? {
        try lock.withLock {
            readCount += 1
            guard readCount == 1 else { throw CommunityError.storage }
            return session
        }
    }
    func save(_ session: CommunitySession) throws { lock.withLock { self.session = session } }
    func clear() throws { lock.withLock { session = nil } }
    var storedSession: CommunitySession? { lock.withLock { session } }
}

final class FailingReadAtCountStore: CommunitySessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private let failingRead: Int
    private var session: CommunitySession?
    private var readCount = 0

    init(_ session: CommunitySession?, failingRead: Int) {
        self.session = session
        self.failingRead = failingRead
    }
    func load() throws -> CommunitySession? {
        try lock.withLock {
            readCount += 1
            guard readCount != failingRead else { throw CommunityError.storage }
            return session
        }
    }
    func save(_ session: CommunitySession) throws { lock.withLock { self.session = session } }
    func clear() throws { lock.withLock { session = nil } }
    var storedSession: CommunitySession? { lock.withLock { session } }
}

final class CommunityAuthRaceTests: XCTestCase {
    func testLogoutClearsBeforeWaitingForServerAndRefreshCannotStart() async throws {
        let store = InMemoryCommunitySessionStore(testSession())
        let transport = LifecycleTransport(gated: ["logout"])
        let auth = CommunityAuth(config: try makeConfig(), transport: transport, store: store, now: { testNow })

        let logout = Task { try await auth.signOut() }
        await transport.waitFor("logout")

        XCTAssertNil(try store.load(), "local credentials must be cleared before server logout finishes")
        await assertCommunityError(.signedOut) { try await auth.validSession() }
        XCTAssertEqual(transport.operations, ["logout"], "refresh must not run after logout begins")

        transport.release("logout")
        try await logout.value
    }

    func testRefreshInFlightThenLogoutCannotRestoreSession() async throws {
        let store = InMemoryCommunitySessionStore(testSession(expiresAt: testNow.addingTimeInterval(10)))
        let transport = LifecycleTransport(gated: ["refresh"])
        let auth = CommunityAuth(config: try makeConfig(), transport: transport, store: store, now: { testNow })

        let refresh = Task { try await auth.validSession() }
        await transport.waitFor("refresh")
        try await auth.signOut()
        XCTAssertNil(try store.load())

        transport.release("refresh")
        await assertCommunityError(.signedOut) { try await refresh.value }
        XCTAssertNil(try store.load())
    }

    func testSignInReplyAfterLocalDiscardCannotCreateSession() async throws {
        let store = InMemoryCommunitySessionStore()
        let transport = LifecycleTransport(gated: ["signin"])
        let auth = CommunityAuth(config: try makeConfig(), transport: transport, store: store, now: { testNow })

        let signIn = Task { try await auth.signInWithApple(idToken: "test-id", nonce: "test-nonce") }
        await transport.waitFor("signin")
        try await auth.discardSession()
        XCTAssertNil(try store.load())

        transport.release("signin")
        await assertCommunityError(.signedOut) { try await signIn.value }
        XCTAssertNil(try store.load())
    }

    func testSignInReplyAfterLogoutCannotCreateSession() async throws {
        let store = InMemoryCommunitySessionStore()
        let transport = LifecycleTransport(gated: ["signin"])
        let auth = CommunityAuth(config: try makeConfig(), transport: transport, store: store, now: { testNow })

        let signIn = Task { try await auth.signInWithApple(idToken: "test-id", nonce: "test-nonce") }
        await transport.waitFor("signin")
        try await auth.signOut()
        XCTAssertNil(try store.load())

        transport.release("signin")
        await assertCommunityError(.signedOut) { try await signIn.value }
        XCTAssertNil(try store.load())
    }

    func testOldUnauthorizedReplyCannotClearNewerSignIn() async throws {
        let oldSession = testSession()
        let store = InMemoryCommunitySessionStore(oldSession)
        let transport = LifecycleTransport(gated: ["profile"])
        let client = CommunityClient(
            config: try makeConfig(), transport: transport, store: store, now: { testNow }
        )

        let profile = Task { try await client.profile() }
        await transport.waitFor("profile")
        let newSession = try await client.auth.signInWithApple(idToken: "new-id", nonce: "new-nonce")
        XCTAssertNotEqual(newSession.accessToken, oldSession.accessToken)

        transport.release("profile")
        await assertCommunityError(.unauthorized) { try await profile.value }
        XCTAssertEqual(try store.load(), newSession, "an old 401 must not clear the newer stored session")
    }

    func testOldForbiddenSignedOutReplyCannotClearNewerSignIn() async throws {
        let oldSession = testSession()
        let store = InMemoryCommunitySessionStore(oldSession)
        let transport = LifecycleTransport(gated: ["profile"], profileStatus: 403)
        let client = CommunityClient(
            config: try makeConfig(), transport: transport, store: store, now: { testNow }
        )

        let profile = Task { try await client.profile() }
        await transport.waitFor("profile")
        let newSession = try await client.auth.signInWithApple(idToken: "new-id", nonce: "new-nonce")
        XCTAssertNotEqual(newSession.accessToken, oldSession.accessToken)

        transport.release("profile")
        await assertCommunityError(.unauthorized) { try await profile.value }
        XCTAssertEqual(try store.load(), newSession, "an old 403 must not clear the newer stored session")
    }

    func testDeletingOldAccountCannotClearNewerSignIn() async throws {
        let store = InMemoryCommunitySessionStore(testSession())
        let transport = LifecycleTransport(gated: ["delete"])
        let client = CommunityClient(
            config: try makeConfig(), transport: transport, store: store, now: { testNow }
        )

        let deletion = Task { try await client.deleteAccount() }
        await transport.waitFor("delete")
        let newSession = try await client.auth.signInWithApple(idToken: "new-id", nonce: "new-nonce")
        XCTAssertNotEqual(newSession.accessToken, testSession().accessToken)

        transport.release("delete")
        try await deletion.value
        XCTAssertEqual(try store.load(), newSession, "a completed delete for account A must preserve account B")
    }

    func testSuccessfulDeleteClearsRotatedSessionForSameAccount() async throws {
        let clock = MutableCommunityClock(testNow)
        let initial = testSession(expiresAt: testNow.addingTimeInterval(3600))
        let store = InMemoryCommunitySessionStore(initial)
        let transport = LifecycleTransport(gated: ["delete"])
        let client = CommunityClient(
            config: try makeConfig(), transport: transport, store: store, now: { clock.read() }
        )

        let deletion = Task { try await client.deleteAccount() }
        await transport.waitFor("delete")

        clock.advance(by: 3601)
        let refreshed = try await client.auth.validSession()
        XCTAssertEqual(refreshed.userID, initial.userID)
        XCTAssertNotEqual(refreshed.accessToken, initial.accessToken)

        transport.release("delete")
        try await deletion.value
        XCTAssertNil(try store.load(), "successful deletion must clear a rotated session for the deleted account")
    }

    func testSuccessfulDeleteStopsInFlightRefreshFromRestoringDeletedAccount() async throws {
        let clock = MutableCommunityClock(testNow)
        let initial = testSession(expiresAt: testNow.addingTimeInterval(3600))
        let store = InMemoryCommunitySessionStore(initial)
        let transport = LifecycleTransport(gated: ["delete", "refresh"])
        let client = CommunityClient(
            config: try makeConfig(), transport: transport, store: store, now: { clock.read() }
        )

        let deletion = Task { try await client.deleteAccount() }
        await transport.waitFor("delete")

        clock.advance(by: 3601)
        let refresh = Task { try await client.auth.validSession() }
        await transport.waitFor("refresh")

        transport.release("delete")
        try await deletion.value
        XCTAssertNil(try store.load())

        transport.release("refresh")
        await assertCommunityError(.signedOut) { try await refresh.value }
        XCTAssertNil(try store.load(), "an old refresh must not restore the deleted account")
    }

    func testDeleteClearFailurePropagatesAfterServerSuccess() async throws {
        let stored = testSession()
        let store = FailingClearStore(stored)
        let transport = LifecycleTransport(gated: [])
        let client = CommunityClient(
            config: try makeConfig(), transport: transport, store: store, now: { testNow }
        )

        await assertCommunityError(.storage) { try await client.deleteAccount() }
        XCTAssertEqual(transport.operations, ["delete"], "server deletion must happen before local clear")
        XCTAssertEqual(store.load(), stored)
    }

    func testClearFailureIsPropagatedAndSkipsServerLogout() async throws {
        let store = FailingClearStore(testSession())
        let transport = LifecycleTransport(gated: [])
        let auth = CommunityAuth(config: try makeConfig(), transport: transport, store: store, now: { testNow })

        await assertCommunityError(.storage) { try await auth.signOut() }
        XCTAssertEqual(store.load(), testSession())
        XCTAssertTrue(transport.operations.isEmpty, "server logout must wait until local clear succeeds")
    }

    func testMatchingUserInvalidationPropagatesReadFailureWithoutPretendingAccountDiffers() async throws {
        let store = FailingLoadStore(testSession())
        let auth = CommunityAuth(config: try makeConfig(), transport: LifecycleTransport(gated: []), store: store, now: { testNow })

        await assertCommunityError(.storage) {
            try await auth.invalidateSession(matchingUserID: testSession().userID)
        }
        XCTAssertEqual(store.storedSession, testSession(), "a failed read must not be mistaken for a different account")
    }

    func testValidSessionPropagatesStorageReadFailureInsteadOfReportingSignedOut() async throws {
        let store = FailingLoadStore(testSession())
        let transport = LifecycleTransport(gated: [])
        let auth = CommunityAuth(config: try makeConfig(), transport: transport, store: store, now: { testNow })

        await assertCommunityError(.storage) { try await auth.validSession() }
        XCTAssertTrue(transport.operations.isEmpty)
    }

    func testSuccessfulDeletePropagatesReadFailureDuringMatchingInvalidation() async throws {
        let stored = testSession()
        let store = FailingSecondReadStore(stored)
        let transport = LifecycleTransport(gated: ["delete"])
        let client = CommunityClient(config: try makeConfig(), transport: transport, store: store, now: { testNow })

        let deletion = Task { try await client.deleteAccount() }
        await transport.waitFor("delete")
        transport.release("delete")

        await assertCommunityError(.storage) { try await deletion.value }
        XCTAssertEqual(transport.operations, ["delete"], "the server deletion completed before the local session read failed")
        XCTAssertEqual(store.storedSession, stored, "a failed matching read must not silently claim the local session was invalidated")
    }

    func testDeleteInvalidationReadFailureFencesInFlightSameAccountRefresh() async throws {
        let clock = MutableCommunityClock(testNow)
        let initial = testSession(expiresAt: testNow.addingTimeInterval(3600))
        let store = FailingReadAtCountStore(initial, failingRead: 3)
        let transport = LifecycleTransport(gated: ["delete", "refresh"])
        let client = CommunityClient(
            config: try makeConfig(), transport: transport, store: store, now: { clock.read() }
        )

        let deletion = Task { try await client.deleteAccount() }
        await transport.waitFor("delete")
        clock.advance(by: 3601)
        let refresh = Task { try await client.auth.validSession() }
        await transport.waitFor("refresh")

        transport.release("delete")
        await assertCommunityError(.storage) { try await deletion.value }
        XCTAssertEqual(store.storedSession, initial, "a failed invalidation read must not clear an unknown session")

        transport.release("refresh")
        await assertCommunityError(.signedOut) { try await refresh.value }
        XCTAssertEqual(store.storedSession, initial, "the earlier refresh must not restore credentials after deletion")
    }

    func testRejectedRefreshReadFailureFencesPendingSignInResult() async throws {
        let initial = testSession(expiresAt: testNow.addingTimeInterval(10))
        let store = FailingReadAtCountStore(initial, failingRead: 2)
        let transport = LifecycleTransport(gated: ["refresh", "signin"], refreshStatus: 401)
        let auth = CommunityAuth(config: try makeConfig(), transport: transport, store: store, now: { testNow })

        let refresh = Task { try await auth.validSession() }
        await transport.waitFor("refresh")
        let signIn = Task { try await auth.signInWithApple(idToken: "new-id", nonce: "new-nonce") }
        await transport.waitFor("signin")

        transport.release("refresh")
        await assertCommunityError(.storage) { try await refresh.value }
        XCTAssertEqual(store.storedSession, initial, "an unreadable refresh session must not be cleared")

        transport.release("signin")
        await assertCommunityError(.signedOut) { try await signIn.value }
        XCTAssertEqual(store.storedSession, initial, "the in-flight sign-in cannot replace state after read failure")
    }

    func testUnauthorizedInvalidationReadFailureFencesPendingSignInResult() async throws {
        let initial = testSession()
        let store = FailingReadAtCountStore(initial, failingRead: 2)
        let transport = LifecycleTransport(gated: ["profile", "signin"])
        let client = CommunityClient(config: try makeConfig(), transport: transport, store: store, now: { testNow })

        let profile = Task { try await client.profile() }
        await transport.waitFor("profile")
        let signIn = Task { try await client.auth.signInWithApple(idToken: "new-id", nonce: "new-nonce") }
        await transport.waitFor("signin")

        transport.release("profile")
        await assertCommunityError(.storage) { try await profile.value }
        XCTAssertEqual(store.storedSession, initial, "the unreadable stored session must not be cleared")

        transport.release("signin")
        await assertCommunityError(.signedOut) { try await signIn.value }
        XCTAssertEqual(store.storedSession, initial, "the in-flight sign-in cannot replace state after read failure")
    }

    func testSignOutClearsLocallyWhenSessionReadFailsAndSkipsServerLogout() async throws {
        let store = FailingLoadStore(testSession())
        let transport = LifecycleTransport(gated: [])
        let auth = CommunityAuth(config: try makeConfig(), transport: transport, store: store, now: { testNow })

        try await auth.signOut()
        XCTAssertNil(store.storedSession, "sign-out must clear local credentials even if the optional logout bearer cannot be read")
        XCTAssertTrue(transport.operations.isEmpty, "server logout is skipped when its optional bearer cannot be read")
    }
}

private final class MutableCommunityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    func read() -> Date { lock.withLock { date } }

    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}
