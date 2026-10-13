import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The only network seam of the Open Food Facts client. Tests inject a stub.
public protocol OpenFoodFactsTransport: Sendable {
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
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
}
