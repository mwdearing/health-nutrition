import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The only network seam of the community client. Tests inject a fake.
public protocol CommunityTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionCommunityTransport: CommunityTransport {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await BoundedResponseLoader.data(
            for: request, session: session, maxBytes: BoundedResponseLimits.community)
    }
}
