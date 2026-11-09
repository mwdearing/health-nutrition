import Foundation

/// Sign-in and session upkeep. Logged-out use of the app never reaches this type.
public actor CommunityAuth {
    /// The access token is renewed when it has less than this many seconds left.
    static let refreshMargin: TimeInterval = 60

    private let api: CommunityAPI
    private let store: CommunitySessionStore
    /// Supplies a challenge token for each sign-in request the service protects. Nil in a build without one.
    private let captcha: (any CommunityCaptcha)?
    private let now: @Sendable () -> Date
    /// One renewal at a time: the refresh token rotates, so a second concurrent refresh would be rejected.
    private var refreshing: Task<CommunitySession, Error>?
    /// Bumped whenever the session is replaced or ended, so a refresh that was already in flight cannot write
    /// its result back over a newer state, for example a session the person just signed out of.
    private var generation = 0
    /// Explicit authentication attempts supersede refreshes, but an old session's rejected request
    /// must not cancel a sign-in or verification already in progress.
    private var authenticationIntent = 0
    /// Successful deletion fences this owner's late replies even if token rejection emptied storage.
    /// A deliberate new authentication intent retires these fences; other owners remain eligible.
    private var deletedOwners: Set<AccountIdentity> = []
    /// Set before a local erase, so a failed clear cannot leave the stored session usable by later calls.
    /// A new accepted authentication clears it again.
    private var localCredentialsRevoked = false

    private enum AccountIdentity: Hashable {
        case uuid(UUID)
        case opaque(Data)

        init(_ userID: String) {
            if let uuid = UUID(uuidString: userID) {
                self = .uuid(uuid)
            } else {
                self = .opaque(Data(userID.utf8))
            }
        }
    }

    public init(
        config: CommunityConfig,
        transport: CommunityTransport,
        store: CommunitySessionStore,
        captcha: (any CommunityCaptcha)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = CommunityAPI(config: config, transport: transport)
        self.store = store
        self.captcha = captcha
        self.now = now
    }

    /// A fresh challenge token for the one request the sign-in service protects, the emailed code request, or nil when no provider is set. A failed challenge ends the
    /// request before it is sent.
    private func captchaSecurity() async throws -> GoTrueSecurity? {
        guard let captcha else { return nil }
        let token: String
        do {
            token = try await captcha.token()
        } catch {
            throw CommunityError.captcha
        }
        return GoTrueSecurity(captchaToken: token)
    }

    /// Signs in with the identity token from Sign in with Apple: POST /auth/v1/token?grant_type=id_token.
    /// The nonce is the raw nonce whose hash was sent to Apple.
    /// When Apple supplied an authorization code it is handed to the server once the session is accepted, so the
    /// server can keep the Sign in with Apple grant and revoke it when the account is deleted. That handoff is
    /// best effort: a failure never fails the sign-in.
    public func signInWithApple(
        idToken: String,
        nonce: String,
        authorizationCode: String? = nil
    ) async throws -> CommunitySession {
        // The sign-in service does not ask for a challenge on an identity token, so none is requested.
        let body = try CommunityAPI.encode(AppleBody(idToken: idToken, nonce: nonce, metaSecurity: nil))
        authenticationIntent += 1
        deletedOwners.removeAll()
        let startedAtIntent = authenticationIntent
        return try await finishingEvenIfCanceled { auth in
            let (data, response) = try await auth.api.send(
                "/auth/v1/token",
                query: [URLQueryItem(name: "grant_type", value: "id_token")],
                body: body
            )
            let session = try await auth.acceptAuthentication(data, response, startedAtIntent: startedAtIntent)
            if let authorizationCode, !authorizationCode.isEmpty {
                await auth.handOffAppleAuthorizationCode(authorizationCode, bearer: session.accessToken)
            }
            return session
        }
    }

    /// Runs a sign-in request, its save and any follow-up on a task of its own, so a reply the server already issued
    /// (a session, a spent one-time code) is kept even when the caller goes away. A canceled caller returns at once
    /// with CancellationError and does not wait for the reply.
    private func finishingEvenIfCanceled(
        _ work: @escaping @Sendable (CommunityAuth) async throws -> CommunitySession
    ) async throws -> CommunitySession {
        let race = CancellationRace()
        let task = Task { [self] in
            do { race.finish(.success(try await work(self))) } catch { race.finish(.failure(error)) }
        }
        _ = task
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { race.attach($0) }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    /// POST /functions/v1/apple-grant {action: store}. The Apple key never leaves the server.
    private func handOffAppleAuthorizationCode(_ code: String, bearer: String) async {
        guard let body = try? CommunityAPI.encode(AppleGrantBody(action: "store", authorizationCode: code)) else { return }
        // Each attempt is bounded by the client's 15 s request timeout, so sign-in waits at most about 30 s here.
        // A second try only helps when the first failed before Apple's exchange: the code is single-use.
        for _ in 0..<2 {
                if (try? await api.send("/functions/v1/apple-grant", bearer: bearer, body: body, sendEvenIfCanceled: true)) != nil { return }
        }
    }

    /// Emails a one-time code. The address also creates the account on first use.
    public func requestEmailCode(email: String) async throws {
        let security = try await captchaSecurity()
        let body = try CommunityAPI.encode(EmailCodeBody(email: email, metaSecurity: security))
        _ = try await api.send("/auth/v1/otp", body: body)
    }

    public func verifyEmailCode(email: String, code: String) async throws -> CommunitySession {
        // Checking the emailed code is not challenged either; only asking for it is.
        let body = try CommunityAPI.encode(VerifyBody(email: email, token: code, metaSecurity: nil))
        authenticationIntent += 1
        deletedOwners.removeAll()
        let startedAtIntent = authenticationIntent
        return try await finishingEvenIfCanceled { auth in
            let (data, response) = try await auth.api.send("/auth/v1/verify", body: body)
            return try await auth.acceptAuthentication(data, response, startedAtIntent: startedAtIntent)
        }
    }

    /// The stored session, renewed first when it is about to expire. A rejected renewal ends the session.
    public func validSession(expectedOwnerID: UUID? = nil) async throws -> CommunitySession {
        try Task.checkCancellation()
        let session = try loadSession()
        guard let session else { throw CommunityError.signedOut }
        try requireOwner(session, expected: expectedOwnerID)
        guard session.expiresAt.timeIntervalSince(now()) < Self.refreshMargin else { return session }
        let renewed: CommunitySession
        if let inFlight = refreshing {
            renewed = try await inFlight.value
        } else {
            let started = generation
            let startedIntent = authenticationIntent
            let task = Task {
                try await self.refresh(session.refreshToken, startedAt: started,
                                       startedAtIntent: startedIntent, owner: session.userID)
            }
            refreshing = task
            defer { refreshing = nil }
            renewed = try await task.value
        }
        try Task.checkCancellation()
        try requireOwner(renewed, expected: expectedOwnerID)
        if let expectedOwnerID {
            guard let current = try loadSession() else { throw CommunityError.signedOut }
            try requireOwner(current, expected: expectedOwnerID)
        }
        return renewed
    }

    private func loadSession() throws -> CommunitySession? {
        guard !localCredentialsRevoked else { return nil }
        do { return try store.load() }
        catch {
            generation += 1
            authenticationIntent += 1
            throw CommunityError.storage
        }
    }

    private func requireOwner(_ session: CommunitySession, expected: UUID?) throws {
        if let expected, UUID(uuidString: session.userID) != expected { throw ProductAPIError.ownerMismatch }
    }

    /// Clears this device first, then ends the server session on a best-effort basis.
    public func signOut() async throws {
        generation += 1
        authenticationIntent += 1
        // Reading the bearer is only for best-effort server logout. A read failure must not prevent
        // clearing credentials from this device.
        let session = try? store.load()
        localCredentialsRevoked = true
        do { try store.clear() } catch { throw CommunityError.storage }
        localCredentialsRevoked = false
        guard let session else { return }
        _ = try? await api.send(
            "/auth/v1/logout",
            query: [URLQueryItem(name: "scope", value: "local")],
            bearer: session.accessToken
        )
    }

    /// Forgets the session on this device without a server call, for example after the account was deleted.
    public func discardSession() throws {
        generation += 1
        authenticationIntent += 1
        localCredentialsRevoked = true
        do { try store.clear() } catch { throw CommunityError.storage }
        localCredentialsRevoked = false
    }

    /// Clears the stored session only when a response belongs to the session still stored on this device.
    @discardableResult
    public func invalidateSession(matchingAccessToken accessToken: String) throws -> Bool {
        let session: CommunitySession?
        do {
            session = try store.load()
        } catch {
            // The matching session is unknown, so do not clear storage. Fence operations already in
            // flight so none can write credentials after the invalidation could not be verified.
            generation += 1
            authenticationIntent += 1
            throw CommunityError.storage
        }
        guard session?.accessToken == accessToken else { return false }
        generation += 1
        do { try store.clear() } catch { throw CommunityError.storage }
        return true
    }

    /// Fences a deleted account's pending replies and clears its current session, including rotated tokens.
    /// Returns whether stored credentials were cleared; the owner fence applies even when storage is empty.
    @discardableResult
    public func invalidateSession(matchingUserID userID: String) throws -> Bool {
        let deletedOwner = AccountIdentity(userID)
        deletedOwners.insert(deletedOwner)
        let session: CommunitySession?
        do {
            session = try store.load()
        } catch {
            // The matching session is unknown, so do not clear storage. Fence operations already in
            // flight so none can write credentials after the invalidation could not be verified.
            generation += 1
            authenticationIntent += 1
            throw CommunityError.storage
        }
        guard let session, AccountIdentity(session.userID) == deletedOwner else { return false }
        generation += 1
        do { try store.clear() } catch { throw CommunityError.storage }
        return true
    }

    /// POST /auth/v1/token?grant_type=refresh_token. A rejected refresh token ends the session.
    private func refresh(
        _ refreshToken: String,
        startedAt: Int,
        startedAtIntent: Int,
        owner: String
    ) async throws -> CommunitySession {
        let body = try CommunityAPI.encode(RefreshBody(refreshToken: refreshToken))
        let (data, response) = try await api.raw(
            "/auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: body
        )
        switch response.statusCode {
        case 200..<300:
            return try acceptRefresh(
                data, response, startedAt: startedAt, startedAtIntent: startedAtIntent, owner: owner
            )
        case 400, 401, 403:
            let session: CommunitySession?
            do {
                // Load the session even if an explicit auth attempt has started since this refresh.
                // An unreadable store still has to fence that pending attempt, while a readable
                // stale refresh must not clear or replace it.
                session = startedAt == generation ? try store.load() : nil
            } catch {
                if startedAt == generation {
                    // This rejected refresh cannot establish which session is stored. Keep it intact,
                    // but prevent an older in-flight sign-in or refresh from writing afterward.
                    generation += 1
                    authenticationIntent += 1
                }
                throw CommunityError.storage
            }
            if startedAtIntent == authenticationIntent, session?.refreshToken == refreshToken {
                generation += 1
                do { try store.clear() } catch { throw CommunityError.storage }
            }
            throw CommunityError.signedOut
        default:
            throw CommunityError.from(status: response.statusCode, body: data)
        }
    }

    private func acceptAuthentication(
        _ data: Data,
        _ response: HTTPURLResponse,
        startedAtIntent: Int
    ) throws -> CommunitySession {
        // A session-replacement request remains valid across failures to invalidate an older token,
        // but a later auth attempt, logout, or unknown storage state fences it.
        guard startedAtIntent == authenticationIntent else { throw CommunityError.signedOut }
        // The server has issued this session, so a cancellation after the reply does not drop it.
        let session = try save(data, response, honorCancellation: false)
        localCredentialsRevoked = false
        return session
    }

    private func acceptRefresh(
        _ data: Data,
        _ response: HTTPURLResponse,
        startedAt: Int,
        startedAtIntent: Int,
        owner: String
    ) throws -> CommunitySession {
        // Refreshes must still own both the stored-session generation and auth intent.
        guard startedAt == generation, startedAtIntent == authenticationIntent else {
            throw CommunityError.signedOut
        }
        return try save(data, response, expectedUserID: owner)
    }

    private func save(
        _ data: Data,
        _ response: HTTPURLResponse,
        expectedUserID: String? = nil,
        honorCancellation: Bool = true
    ) throws -> CommunitySession {
        if honorCancellation { try Task.checkCancellation() }
        let reply = try CommunityAPI.decode(TokenReply.self, from: data, status: response.statusCode)
        let owner = AccountIdentity(reply.user.id)
        guard !deletedOwners.contains(owner) else { throw CommunityError.signedOut }
        if let expectedUserID {
            guard AccountIdentity(expectedUserID) == owner else { throw CommunityError.signedOut }
        }
        let session = CommunitySession(
            accessToken: reply.accessToken,
            refreshToken: reply.refreshToken,
            expiresAt: now().addingTimeInterval(reply.expiresIn),
            userID: reply.user.id,
            email: reply.user.email
        )
        do {
            try store.save(session)
        } catch {
            throw CommunityError.storage
        }
        generation += 1
        return session
    }
}

private struct AppleBody: Encodable {
    let provider = "apple"
    let idToken: String
    let nonce: String
    var metaSecurity: GoTrueSecurity? = nil

    enum CodingKeys: String, CodingKey {
        case provider
        case idToken = "id_token"
        case nonce
        case metaSecurity = "gotrue_meta_security"
    }
}

struct AppleGrantBody: Encodable {
    let action: String
    var authorizationCode: String? = nil

    enum CodingKeys: String, CodingKey {
        case action
        case authorizationCode = "authorization_code"
    }
}

private struct EmailCodeBody: Encodable {
    let email: String
    let createUser = true
    var metaSecurity: GoTrueSecurity? = nil

    enum CodingKeys: String, CodingKey {
        case email
        case createUser = "create_user"
        case metaSecurity = "gotrue_meta_security"
    }
}

private struct VerifyBody: Encodable {
    let type = "email"
    let email: String
    let token: String
    var metaSecurity: GoTrueSecurity? = nil

    enum CodingKeys: String, CodingKey {
        case type, email, token
        case metaSecurity = "gotrue_meta_security"
    }
}

/// The GoTrue security object that carries the challenge token of a protected request.
struct GoTrueSecurity: Encodable, Equatable {
    let captchaToken: String

    enum CodingKeys: String, CodingKey {
        case captchaToken = "captcha_token"
    }
}

private struct RefreshBody: Encodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

private struct TokenReply: Decodable {
    struct User: Decodable {
        let id: String
        let email: String?
    }

    let accessToken: String
    let refreshToken: String
    let expiresIn: TimeInterval
    let user: User
}

/// Hands one result to whichever comes first: the work finishing or its caller being canceled.
private final class CancellationRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommunitySession, Error>?
    private var early: Result<CommunitySession, Error>?
    private var done = false

    func attach(_ next: CheckedContinuation<CommunitySession, Error>) {
        let ready = lock.withLock { () -> Result<CommunitySession, Error>? in
            if let early { return early }
            continuation = next
            return nil
        }
        if let ready { next.resume(with: ready) }
    }

    func finish(_ result: Result<CommunitySession, Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<CommunitySession, Error>? in
            if done { return nil }
            done = true
            guard let continuation else { early = result; return nil }
            self.continuation = nil
            return continuation
        }
        waiting?.resume(with: result)
    }
}
