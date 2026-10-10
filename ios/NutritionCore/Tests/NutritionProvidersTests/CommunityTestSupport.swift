import Foundation
import XCTest
@testable import NutritionProviders

/// Fake transport for the community client. Replies are served in order and every request is recorded.
final class FakeCommunityTransport: CommunityTransport, @unchecked Sendable {
    enum Reply {
        case response(status: Int, body: String)
        case failure(URLError)
    }

    private let lock = NSLock()
    private var queued: [Reply]
    private var recorded: [URLRequest] = []

    init(_ replies: [Reply] = []) {
        queued = replies
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply? = lock.withLock {
            recorded.append(request)
            return queued.isEmpty ? nil : queued.removeFirst()
        }
        switch reply {
        case .response(let status, let body):
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), http)
        case .failure(let error):
            throw error
        case nil:
            throw URLError(.badServerResponse)
        }
    }
}

let testNow = Date(timeIntervalSince1970: 1_800_000_000)
let testUserID = "11111111-2222-3333-4444-555555555555"

let tokenBody = """
{"access_token":"test-access-token","refresh_token":"test-refresh-token","expires_in":3600,"user":{"id":"11111111-2222-3333-4444-555555555555","email":"person@example.com"}}
"""

let refreshedBody = """
{"access_token":"refreshed-access-token","refresh_token":"refreshed-refresh-token","expires_in":3600,"user":{"id":"11111111-2222-3333-4444-555555555555","email":"person@example.com"}}
"""

func testInfo(url: String = "https://example-ref.supabase.co", key: String = "test-anon-key") -> [String: Any] {
    ["SUPABASE_URL": url, "SUPABASE_ANON_KEY": key]
}

func makeConfig() throws -> CommunityConfig {
    try XCTUnwrap(CommunityConfig(infoDictionary: testInfo()))
}

func testSession(expiresAt: Date = testNow.addingTimeInterval(3600)) -> CommunitySession {
    CommunitySession(
        accessToken: "test-access-token",
        refreshToken: "test-refresh-token",
        expiresAt: expiresAt,
        userID: testUserID,
        email: "person@example.com"
    )
}

func makeAuth(
    transport: FakeCommunityTransport,
    store: CommunitySessionStore = InMemoryCommunitySessionStore(),
    now: Date = testNow
) throws -> CommunityAuth {
    CommunityAuth(config: try makeConfig(), transport: transport, store: store, now: { now })
}

/// The JSON object sent as the request body.
func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
    let data = try XCTUnwrap(request.httpBody)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// The query parameters of the request URL, first value wins.
func queryItems(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

/// Asserts that the operation throws exactly the expected community error.
func assertCommunityError<T>(
    _ expected: CommunityError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("expected \(expected), but the call succeeded", file: file, line: line)
    } catch let error as CommunityError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected a CommunityError, got \(type(of: error))", file: file, line: line)
    }
}
