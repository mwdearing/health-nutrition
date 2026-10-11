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
        let startedAt = generation
        // The sign-in service does not ask for a challenge on an identity token, so none is requested.
        let body = try CommunityAPI.encode(AppleBody(idToken: idToken, nonce: nonce, metaSecurity: nil))
        let (data, response) = try await api.send(
            "/auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "id_token")],
            body: body
        )
        return try accept(data, response, startedAt: startedAt)
    }

    /// Emails a one-time code. The address also creates the account on first use.
    public func requestEmailCode(email: String) async throws {
        let security = try await captchaSecurity()
        let body = try CommunityAPI.encode(EmailCodeBody(email: email, metaSecurity: security))
        _ = try await api.send("/auth/v1/otp", body: body)
    }

    public func verifyEmailCode(email: String, code: String) async throws -> CommunitySession {
        let startedAt = generation
        // Checking the emailed code is not challenged either; only asking for it is.
        let body = try CommunityAPI.encode(VerifyBody(email: email, token: code, metaSecurity: nil))
        let (data, response) = try await api.send("/auth/v1/verify", body: body)
        return try accept(data, response, startedAt: startedAt)
    }

    /// The stored session, renewed first when it is about to expire. A rejected renewal ends the session.
    public func validSession() async throws -> CommunitySession {
        guard let session = store.load() else {
            throw CommunityError.signedOut
        }
        guard session.expiresAt.timeIntervalSince(now()) < Self.refreshMargin else {
            return session
        }
        if let inFlight = refreshing {
            return try await inFlight.value
        }
        let started = generation
        let task = Task { try await self.refresh(session.refreshToken, startedAt: started) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    /// Clears this device first, then ends the server session on a best-effort basis.
    public func signOut() async throws {
        generation += 1
        let session = store.load()
        do { try store.clear() } catch { throw CommunityError.storage }
        guard let session else { return }
        _ = try? await api.send("/auth/v1/logout", bearer: session.accessToken)
    }

    /// Forgets the session on this device without a server call, for example after the account was deleted.
    public func discardSession() throws {
        generation += 1
        do { try store.clear() } catch { throw CommunityError.storage }
    }

    /// Clears the stored session only when a response belongs to the session still stored on this device.
    @discardableResult
    public func invalidateSession(matchingAccessToken accessToken: String) throws -> Bool {
        guard store.load()?.accessToken == accessToken else { return false }
        generation += 1
        do { try store.clear() } catch { throw CommunityError.storage }
        return true
    }

    /// POST /auth/v1/token?grant_type=refresh_token. A rejected refresh token ends the session.
    private func refresh(_ refreshToken: String, startedAt: Int) async throws -> CommunitySession {
        let body = try CommunityAPI.encode(RefreshBody(refreshToken: refreshToken))
        let (data, response) = try await api.raw(
            "/auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: body
        )
        switch response.statusCode {
        case 200..<300:
            return try accept(data, response, startedAt: startedAt)
        case 400, 401, 403:
            if startedAt == generation, store.load()?.refreshToken == refreshToken {
                generation += 1
                do { try store.clear() } catch { throw CommunityError.storage }
            }
            throw CommunityError.signedOut
        default:
            throw CommunityError.from(status: response.statusCode, body: data)
        }
    }

    private func accept(_ data: Data, _ response: HTTPURLResponse, startedAt: Int) throws -> CommunitySession {
        // A sign-in or refresh reply is usable only in the generation that started it.
        guard startedAt == generation else { throw CommunityError.signedOut }
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
