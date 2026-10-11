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
    public func signInWithApple(idToken: String, nonce: String) async throws -> CommunitySession {
        // The sign-in service does not ask for a challenge on an identity token, so none is requested.
        let body = try CommunityAPI.encode(AppleBody(idToken: idToken, nonce: nonce, metaSecurity: nil))
        authenticationIntent += 1
        let startedAtIntent = authenticationIntent
        let (data, response) = try await api.send(
            "/auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "id_token")],
            body: body
        )
        return try acceptAuthentication(data, response, startedAtIntent: startedAtIntent)
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
        let startedAtIntent = authenticationIntent
        let (data, response) = try await api.send("/auth/v1/verify", body: body)
        return try acceptAuthentication(data, response, startedAtIntent: startedAtIntent)
    }

    /// The stored session, renewed first when it is about to expire. A rejected renewal ends the session.
    public func validSession() async throws -> CommunitySession {
        let session: CommunitySession?
        do {
            session = try store.load()
        } catch {
            generation += 1
            authenticationIntent += 1
            throw CommunityError.storage
        }
        guard let session else {
            throw CommunityError.signedOut
        }
        guard session.expiresAt.timeIntervalSince(now()) < Self.refreshMargin else {
            return session
        }
        if let inFlight = refreshing {
            return try await inFlight.value
        }
        let started = generation
        let startedIntent = authenticationIntent
        let task = Task {
            try await self.refresh(
                session.refreshToken,
                startedAt: started,
                startedAtIntent: startedIntent
            )
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    /// Clears this device first, then ends the server session on a best-effort basis.
    public func signOut() async throws {
        generation += 1
        authenticationIntent += 1
        // Reading the bearer is only for best-effort server logout. A read failure must not prevent
        // clearing credentials from this device.
        let session = try? store.load()
        do { try store.clear() } catch { throw CommunityError.storage }
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
        do { try store.clear() } catch { throw CommunityError.storage }
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

    /// Clears a deleted account's current session, including tokens rotated while deletion was in flight.
    @discardableResult
    public func invalidateSession(matchingUserID userID: String) throws -> Bool {
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
        guard session?.userID == userID else { return false }
        generation += 1
        do { try store.clear() } catch { throw CommunityError.storage }
        return true
    }

    /// POST /auth/v1/token?grant_type=refresh_token. A rejected refresh token ends the session.
    private func refresh(
        _ refreshToken: String,
        startedAt: Int,
        startedAtIntent: Int
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
                data, response, startedAt: startedAt, startedAtIntent: startedAtIntent
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
        return try save(data, response)
    }

    private func acceptRefresh(
        _ data: Data,
        _ response: HTTPURLResponse,
        startedAt: Int,
        startedAtIntent: Int
    ) throws -> CommunitySession {
        // Refreshes must still own both the stored-session generation and auth intent.
        guard startedAt == generation, startedAtIntent == authenticationIntent else {
            throw CommunityError.signedOut
        }
        return try save(data, response)
    }

    private func save(_ data: Data, _ response: HTTPURLResponse) throws -> CommunitySession {
        let reply = try CommunityAPI.decode(TokenReply.self, from: data, status: response.statusCode)
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
