import Foundation

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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
