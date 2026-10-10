import Foundation

/// Sign-in and session upkeep. Logged-out use of the app never reaches this type.
public actor CommunityAuth {
    /// The access token is renewed when it has less than this many seconds left.
    static let refreshMargin: TimeInterval = 60

    private let api: CommunityAPI
    private let store: CommunitySessionStore
    private let now: @Sendable () -> Date
    /// One renewal at a time: the refresh token rotates, so a second concurrent refresh would be rejected.
    private var refreshing: Task<CommunitySession, Error>?

    public init(
        config: CommunityConfig,
        transport: CommunityTransport,
        store: CommunitySessionStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = CommunityAPI(config: config, transport: transport)
        self.store = store
        self.now = now
    }

    /// Signs in with the identity token from Sign in with Apple: POST /auth/v1/token?grant_type=id_token.
    /// The nonce is the raw nonce whose hash was sent to Apple.
    public func signInWithApple(idToken: String, nonce: String) async throws -> CommunitySession {
        let body = try CommunityAPI.encode(AppleBody(idToken: idToken, nonce: nonce))
        let (data, response) = try await api.send(
            "/auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "id_token")],
            body: body
        )
        return try accept(data, response)
    }

    /// Emails a one-time code. The address also creates the account on first use.
    public func requestEmailCode(email: String) async throws {
        let body = try CommunityAPI.encode(EmailCodeBody(email: email))
        _ = try await api.send("/auth/v1/otp", body: body)
    }

    public func verifyEmailCode(email: String, code: String) async throws -> CommunitySession {
        let body = try CommunityAPI.encode(VerifyBody(email: email, token: code))
        let (data, response) = try await api.send("/auth/v1/verify", body: body)
        return try accept(data, response)
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
        let task = Task { try await self.refresh(session.refreshToken) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    /// Ends the session on the server, best effort, and always forgets it on this device.
    public func signOut() async {
        if let session = store.load() {
            _ = try? await api.send("/auth/v1/logout", bearer: session.accessToken)
        }
        store.clear()
    }

    /// Forgets the session on this device without a server call, for example after the account was deleted.
    public func discardSession() {
        store.clear()
    }

    /// POST /auth/v1/token?grant_type=refresh_token. A rejected refresh token ends the session.
    private func refresh(_ refreshToken: String) async throws -> CommunitySession {
        let body = try CommunityAPI.encode(RefreshBody(refreshToken: refreshToken))
        let (data, response) = try await api.raw(
            "/auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: body
        )
        switch response.statusCode {
        case 200..<300:
            return try accept(data, response)
        case 400, 401, 403:
            store.clear()
            throw CommunityError.signedOut
        default:
            throw CommunityError.from(status: response.statusCode, body: data)
        }
    }

    private func accept(_ data: Data, _ response: HTTPURLResponse) throws -> CommunitySession {
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
        return session
    }
}

private struct AppleBody: Encodable {
    let provider = "apple"
    let idToken: String
    let nonce: String

    enum CodingKeys: String, CodingKey {
        case provider
        case idToken = "id_token"
        case nonce
    }
}

private struct EmailCodeBody: Encodable {
    let email: String
    let createUser = true

    enum CodingKeys: String, CodingKey {
        case email
        case createUser = "create_user"
    }
}

private struct VerifyBody: Encodable {
    let type = "email"
    let email: String
    let token: String
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
