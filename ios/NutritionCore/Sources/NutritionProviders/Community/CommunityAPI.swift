import Foundation

/// Builds the requests of the community client and maps the replies. Internal: the public surface is
/// CommunityAuth and CommunityClient.
struct CommunityAPI: Sendable {
    let config: CommunityConfig
    let transport: CommunityTransport

    /// Sends one request and returns the reply without checking its status.
    func raw(
        _ path: String,
        method: String = "POST",
        query: [URLQueryItem] = [],
        bearer: String? = nil,
        body: Data? = nil,
        prefer: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw CommunityError.notConfigured
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw CommunityError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let prefer {
            request.setValue(prefer, forHTTPHeaderField: "Prefer")
        }
        do {
            return try await transport.send(request)
        } catch {
            // The transport error is dropped on purpose: its text could contain the request URL.
            throw CommunityError.network
        }
    }

    /// Sends one request and throws the mapped error unless the reply is 2xx.
    func send(
        _ path: String,
        method: String = "POST",
        query: [URLQueryItem] = [],
        bearer: String? = nil,
        body: Data? = nil,
        prefer: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await raw(path, method: method, query: query, bearer: bearer, body: body, prefer: prefer)
        guard (200..<300).contains(response.statusCode) else {
            throw CommunityError.from(status: response.statusCode, body: data)
        }
        return (data, response)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, status: Int) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw CommunityError.server(status)
        }
    }
}
