import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The only network seam of the Open Food Facts client. Tests inject a stub.
public protocol OpenFoodFactsTransport: Sendable {
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Like `get`, but the response is refused as soon as it crosses `maxBytes` while streaming.
    func get(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse)
}

extension OpenFoodFactsTransport {
    /// Transports with no streaming of their own (test stubs) ignore the cap; the client still checks the
    /// body size it received.
    public func get(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        try await get(request)
    }
}

public struct URLSessionOpenFoodFactsTransport: OpenFoodFactsTransport {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await BoundedResponseLoader.data(
            for: request, session: session, maxBytes: BoundedResponseLimits.openFoodFacts)
    }

    public func get(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        try await BoundedResponseLoader.data(
            for: request, session: session, maxBytes: min(maxBytes, BoundedResponseLimits.openFoodFacts))
    }
}
