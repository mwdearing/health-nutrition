import Foundation

/// How the receiver wants a request authenticated.
///
/// The contract states the scheme and the header rather than leaving the worker to guess, so these are
/// read back from the capabilities document and never assembled here: a worker that hard-coded `Bearer`
/// would keep sending after a receiver had moved to a different scheme, and every batch would come back
/// 401 with nothing to say why.
public struct IntakeContextAuthentication: Sendable, Equatable, Hashable {
    /// For example `bearer`.
    public let scheme: String
    /// The header the token goes in, for example `Authorization`.
    public let header: String
    /// What the token is, for example `intake`. Provenance, not a check this module makes.
    public let tokenType: String

    public init(scheme: String, header: String, tokenType: String) {
        self.scheme = scheme
        self.header = header
        self.tokenType = tokenType
    }
}

/// What the receiver says it accepts, read from `GET /v1/intake-context/capabilities`.
///
/// **The batch limits come from here and nowhere else.** `maxOperations` and `maxBodyBytes` are the
/// receiver's own numbers, so a batch is packed against what this receiver will take rather than against
/// a limit guessed locally and found wrong by a 413 on the first run.
///
/// The document is cached by the receiver for five minutes, so a caller may ask once per run rather than
/// once per batch. A capabilities read that fails is a failed run, not a reason to guess: the worker
/// schedules a retry and sends nothing, because a batch packed against invented limits is exactly the
/// request the receiver answers with 413.
public struct IntakeContextCapabilities: Sendable, Equatable, Hashable {
    public let schema: String
    /// The schema versions this receiver speaks, in its own spelling.
    public let supportedVersions: [String]
    /// The largest body it accepts, in bytes.
    public let maxBodyBytes: Int
    /// The most operations one batch may carry.
    public let maxOperations: Int
    public let authentication: IntakeContextAuthentication
    /// Optional behaviour flags, read as text because this module acts on none of them yet.
    public let features: [String]

    public init(
        schema: String,
        supportedVersions: [String],
        maxBodyBytes: Int,
        maxOperations: Int,
        authentication: IntakeContextAuthentication,
        features: [String] = []
    ) {
        self.schema = schema
        self.supportedVersions = supportedVersions
        self.maxBodyBytes = maxBodyBytes
        self.maxOperations = maxOperations
        self.authentication = authentication
        self.features = features
    }

    /// Whether this receiver speaks the schema version the encoder writes.
    ///
    /// Checked before anything is sent: a receiver that does not know `1.0` rejects the batch while
    /// parsing it, which would look like a permanent failure of every operation rather than of the
    /// version this build writes.
    public func supports(schemaVersion: String) -> Bool {
        supportedVersions.contains(schemaVersion)
    }
}

/// What one `POST /v1/intake-context/batches` came back with.
///
/// The body is raw `Data` rather than a parsed result, because the status decides what the body means: a
/// 200 carries per-operation results, a 400 or 403 an error code, and a 429 or 413 a header the worker
/// reads through `retryAfterSeconds`. Parsing happens once the status has been read.
public struct IntakeContextTransportResponse: Sendable, Equatable {
    /// The HTTP status code.
    public let statusCode: Int
    /// `Retry-After` in whole seconds, when the receiver sent one. Nil means it said nothing, so the
    /// backoff schedule decides the wait rather than a rate limit the receiver never stated.
    public let retryAfterSeconds: Int?
    /// The response body, exactly as it arrived.
    public let body: Data

    public init(statusCode: Int, retryAfterSeconds: Int? = nil, body: Data = Data()) {
        self.statusCode = statusCode
        self.retryAfterSeconds = retryAfterSeconds
        self.body = body
    }
}

/// How a batch reaches the receiver.
///
/// **The journal module never opens a connection.** It holds no session, no URL and no HTTP client of
/// its own: a transport is injected, which is what lets the delivery rules be tested against a fake and
/// keeps this layer free of networking entirely. The app target supplies the real transport, with the
/// intake token from the HealthRelay connection, when that connection ships.
///
/// `token` is passed per call rather than held by the transport, so rotating a token is the caller's
/// decision and two batches in one run can carry different tokens.
public protocol IntakeContextTransport: Sendable {
    /// The receiver's current capabilities, which decide how a batch is packed.
    func capabilities() async throws -> IntakeContextCapabilities

    /// Sends one canonical batch and reports what came back, including the status and `Retry-After`.
    ///
    /// A transport error — no connection, a timeout, a cancelled request — is thrown rather than returned
    /// as a status, because nothing was received and there is no status to act on. The worker treats a
    /// thrown error as transient.
    func send(batch: Data, token: String) async throws -> IntakeContextTransportResponse
}