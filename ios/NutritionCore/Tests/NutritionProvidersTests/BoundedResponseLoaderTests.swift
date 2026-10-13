import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import NutritionProviders

final class BoundedResponseLoaderTests: XCTestCase {
    func testBodyAtLimitIsReturned() async throws {
        let session = makeSession(script: .init(chunks: [Data("1234".utf8)]))
        defer { session.invalidateAndCancel() }

        let (body, response) = try await BoundedResponseLoader.data(
            for: request(), session: session, maxBytes: 4)

        XCTAssertEqual(body, Data("1234".utf8))
        XCTAssertEqual(response.statusCode, 200)
    }

    func testBodyOverLimitIsRejectedAndUnderlyingRequestIsCanceled() async throws {
        let stopped = expectation(description: "oversized request canceled")
        let session = makeSession(script: .init(
            chunks: [Data(repeating: 0x31, count: 64 * 1_024)], holdOpen: true,
            onStop: { stopped.fulfill() }))
        defer { session.invalidateAndCancel() }

        do {
            _ = try await BoundedResponseLoader.data(for: request(), session: session, maxBytes: 4)
            XCTFail("expected an over-limit refusal")
        } catch {
            XCTAssertEqual(error as? BoundedResponseError, .responseTooLarge)
            XCTAssertFalse(String(describing: error).contains("provider.invalid"))
            XCTAssertFalse(String(describing: error).contains("test-secret"))
        }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testLyingLowContentLengthDoesNotLetChunksExceedTheCap() async throws {
        let stopped = expectation(description: "chunked overflow canceled")
        let session = makeSession(script: .init(
            chunks: [Data("123".utf8), Data(repeating: 0x34, count: 64 * 1_024)], contentLength: 1,
            holdOpen: true, onStop: { stopped.fulfill() }))
        defer { session.invalidateAndCancel() }

        do {
            _ = try await BoundedResponseLoader.data(for: request(), session: session, maxBytes: 4)
            XCTFail("expected an over-limit refusal despite the false header")
        } catch {
            XCTAssertEqual(error as? BoundedResponseError, .responseTooLarge)
        }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testAdvertisedOversizeIsRejectedBeforeBodyArrives() async throws {
        let session = makeSession(script: .init(
            chunks: [], contentLength: 100))
        defer { session.invalidateAndCancel() }

        do {
            _ = try await BoundedResponseLoader.data(for: request(), session: session, maxBytes: 4)
            XCTFail("expected the advertised over-limit response to be refused")
        } catch {
            XCTAssertEqual(error as? BoundedResponseError, .responseTooLarge)
        }
    }

    func testCancellationStopsTheUnderlyingRequest() async throws {
        let chunkDelivered = expectation(description: "initial chunk delivered")
        let stopped = expectation(description: "canceled request stopped")
        let session = makeSession(script: .init(
            chunks: [Data("1".utf8)], holdOpen: true,
            onChunk: { chunkDelivered.fulfill() }, onStop: { stopped.fulfill() }))
        defer { session.invalidateAndCancel() }

        let request = request()
        let task = Task {
            try await BoundedResponseLoader.data(for: request, session: session, maxBytes: 4)
        }
        await fulfillment(of: [chunkDelivered], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTAssertTrue(error is URLError)
        }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testCommunityRawCancellationDuringStreamingRemainsCancellation() async throws {
        let chunk = expectation(description: "stream started")
        let stopped = expectation(description: "stream stopped")
        let session = makeSession(script: .init(chunks: [Data("{".utf8)], holdOpen: true,
            onChunk: { chunk.fulfill() }, onStop: { stopped.fulfill() }))
        defer { session.invalidateAndCancel() }
        let api = CommunityAPI(config: try makeConfig(), transport: URLSessionCommunityTransport(session: session))
        let task = Task { try await api.raw("/rest/v1/rpc/catalog_capabilities_v2") }
        await fulfillment(of: [chunk], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch is CancellationError {} catch { XCTFail("cancellation was remapped") }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testInjectedTaskDelegateCanRefuseRedirects() async throws {
#if canImport(FoundationNetworking)
        throw XCTSkip("swift-corelibs FoundationNetworking does not support URLProtocol redirects")
#else
        let redirected = expectation(description: "injected task delegate receives redirect")
        let redirectURL = URL(string: "https://provider.invalid/final")!
        let delegate = RedirectRefusingDelegate(onRedirect: { redirected.fulfill() })
        let delegateQueue = OperationQueue()
        delegateQueue.name = "bounded-loader-injected-delegate-queue"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledURLProtocol.self]
        ControlledURLProtocol.install(script: .init(chunks: [], redirectTo: redirectURL))
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await BoundedResponseLoader.data(for: request(), session: session, maxBytes: 4)
            XCTFail("the injected delegate refused the redirect")
        } catch {
            XCTAssertTrue(error is URLError || error is CancellationError)
        }
        await fulfillment(of: [redirected], timeout: 2)
        XCTAssertEqual(delegate.redirectCount, 1)
        XCTAssertTrue(delegate.observedSession === session)
        XCTAssertEqual(delegate.observedQueueName, delegateQueue.name)
        XCTAssertEqual(ControlledURLProtocol.requestCount(), 1)
#endif
    }

    func testInjectedRequestTimeoutIsPreserved() async throws {
#if canImport(FoundationNetworking)
        throw XCTSkip("swift-corelibs FoundationNetworking does not enforce request timeouts for URLProtocol")
#else
        let stopped = expectation(description: "request stopped by injected timeout")
        ControlledURLProtocol.install(.init(chunks: [], holdOpen: true, onStop: { stopped.fulfill() }))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledURLProtocol.self]
        configuration.timeoutIntervalForRequest = 0.1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await BoundedResponseLoader.data(for: request(), session: session, maxBytes: 4)
            XCTFail("expected the injected request timeout")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        await fulfillment(of: [stopped], timeout: 2)
#endif
    }

#if canImport(FoundationNetworking)
    func testLinuxDelegateForwardingRoutesRedirectDecisionOnce() {
        let delegate = RedirectRefusingDelegate(onRedirect: {})
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let operation = BoundedResponseOperation(
            originalSession: session, configuration: configuration, forwardingDelegate: delegate,
            delegateQueue: session.delegateQueue, maxBytes: 4)
        let task = session.dataTask(with: request())
        let response = HTTPURLResponse(
            url: request().url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!
        let completed = expectation(description: "redirect policy completed")
        operation.urlSession(session, task: task, willPerformHTTPRedirection: response,
                             newRequest: URLRequest(url: URL(string: "https://provider.invalid/final")!)) { request in
            XCTAssertNil(request)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(delegate.redirectCount, 1)
        XCTAssertTrue(delegate.observedSession === session)
        session.invalidateAndCancel()
    }
#endif

#if canImport(ObjectiveC)
    func testAppleOptionalDelegateSelectorsForwardToInjectedDelegate() {
        let delegate = RedirectRefusingDelegate(onRedirect: {})
        let delegateQueue = OperationQueue()
        let operation = BoundedResponseOperation(
            originalSession: URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: delegateQueue),
            configuration: URLSessionConfiguration.ephemeral,
            forwardingDelegate: delegate,
            delegateQueue: delegateQueue,
            maxBytes: 4)
        let selectors = [
            NSSelectorFromString("URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:"),
            NSSelectorFromString("URLSession:task:didReceiveChallenge:completionHandler:"),
            NSSelectorFromString("URLSession:didReceiveChallenge:completionHandler:"),
        ]
        for selector in selectors {
            XCTAssertTrue(operation.responds(to: selector))
        }
    }
#endif

    func testNonHTTPResponseIsRejected() async throws {
        let session = makeSession(script: .init(chunks: [], nonHTTP: true))
        defer { session.invalidateAndCancel() }

        do {
            _ = try await BoundedResponseLoader.data(for: request(), session: session, maxBytes: 4)
            XCTFail("expected a non-HTTP response refusal")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        }
    }

    func testOversizedErrorBodyIsRejectedBeforeStatusMapping() async throws {
        let session = makeSession(script: .init(
            status: 503, chunks: [Data(repeating: 0x31, count: 64 * 1_024)], holdOpen: true))
        defer { session.invalidateAndCancel() }

        do {
            _ = try await BoundedResponseLoader.data(for: request(), session: session, maxBytes: 4)
            XCTFail("expected an oversized non-2xx response refusal")
        } catch {
            XCTAssertEqual(error as? BoundedResponseError, .responseTooLarge)
        }
    }

    func testCommunityTransportEnforcesItsOwnCap() async throws {
        try await assertOversizedResponseIsCanceled(limit: BoundedResponseLimits.community) { session, request in
            try await URLSessionCommunityTransport(session: session).send(request)
        }
    }


    func testOpenFoodFactsTransportEnforcesItsOwnCap() async throws {
        try await assertOversizedResponseIsCanceled(limit: BoundedResponseLimits.openFoodFacts) { session, request in
            try await URLSessionOpenFoodFactsTransport(session: session).get(request)
        }
    }

    func testDSLDTransportEnforcesItsOwnCap() async throws {
        try await assertOversizedResponseIsCanceled(limit: BoundedResponseLimits.dsld) { session, request in
            try await URLSessionDSLDTransport(session: session).get(request)
        }
    }

    func testCommunityAPIMapsOversizedResponseToGenericNetworkError() async throws {
        let config = try XCTUnwrap(CommunityConfig(infoDictionary: [
            "SUPABASE_URL": "https://example.supabase.co", "SUPABASE_ANON_KEY": "synthetic-key",
        ]))
        let api = CommunityAPI(config: config, transport: OversizedCommunityTransport())
        do {
            _ = try await api.raw("/rpc/lookup_label_v2", method: "POST")
            XCTFail("expected an oversized-response refusal")
        } catch {
            XCTAssertEqual(error as? CommunityError, .network)
            XCTAssertFalse(String(describing: error).contains("synthetic-key"))
            XCTAssertFalse(String(describing: error).contains("example.supabase.co"))
        }
    }


    private func assertOversizedResponseIsCanceled(
        limit: Int,
        operation: (URLSession, URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws {
        let stopped = expectation(description: "provider transport cancels oversized body")
        let session = makeSession(script: .init(
            chunks: [Data(repeating: 0x78, count: limit + 1)], holdOpen: true,
            onStop: { stopped.fulfill() }))
        defer { session.invalidateAndCancel() }

        do {
            _ = try await operation(session, request())
            XCTFail("expected an over-limit refusal")
        } catch {
            XCTAssertEqual(error as? BoundedResponseError, .responseTooLarge)
        }
        await fulfillment(of: [stopped], timeout: 2)
    }

    private func request() -> URLRequest {
        URLRequest(url: URL(string: "https://provider.invalid/response?key=test-secret")!)
    }

    private func makeSession(script: ControlledURLProtocol.Script) -> URLSession {
        ControlledURLProtocol.install(script)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private struct OversizedCommunityTransport: CommunityTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw BoundedResponseError.responseTooLarge
    }
}


private final class ControlledURLProtocol: URLProtocol {
    struct Script {
        var status = 200
        var chunks: [Data]
        var contentLength: Int?
        var redirectTo: URL?
        var holdOpen = false
        var nonHTTP = false
        var onChunk: (() -> Void)?
        var onStop: (() -> Void)?
    }

    /// URLProtocol instances share one fixture, so all mutable state stays inside this lock-backed holder.
    private final class LockedState: @unchecked Sendable {
        private let lock = NSLock()
        private var script = Script(chunks: [])
        private var requestCount = 0

        func install(_ value: Script) {
            lock.withLock {
                script = value
                requestCount = 0
            }
        }

        func beginRequest() -> Script {
            lock.withLock {
                requestCount += 1
                return script
            }
        }

        func currentRequestCount() -> Int {
            lock.withLock { requestCount }
        }

        func stopCallback() -> (() -> Void)? {
            lock.withLock { script.onStop }
        }
    }

    private static let state = LockedState()
    private let lifecycleLock = NSLock()
    private let deliveryQueue = DispatchQueue(label: "bounded-response-test.protocol")
    private var stopped = false

    static func requestCount() -> Int { state.currentRequestCount() }

    static func install(script value: Script) {
        state.install(value)
    }

    static func install(_ value: Script) { install(script: value) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let current = Self.state.beginRequest()
        // URLSession may buffer protocol callbacks that all arrive synchronously from
        // startLoading. Deliver asynchronously so these fixtures exercise real streaming behavior.
        deliveryQueue.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in
            guard isActive else { return }
            if let redirectTo = current.redirectTo, request.url != redirectTo {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": redirectTo.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirectTo), redirectResponse: response)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let response: URLResponse
            if current.nonHTTP {
                response = URLResponse(url: request.url!, mimeType: "text/plain", expectedContentLength: -1,
                                       textEncodingName: nil)
            } else {
                var headers = [String: String]()
                if let contentLength = current.contentLength { headers["Content-Length"] = String(contentLength) }
                response = HTTPURLResponse(
                    url: request.url!, statusCode: current.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            deliverChunk(at: 0, from: current)
        }
    }

    override func stopLoading() {
        lifecycleLock.withLock { stopped = true }
        let callback = Self.state.stopCallback()
        callback?()
    }

    private var isActive: Bool { lifecycleLock.withLock { !stopped } }

    private func deliverChunk(at index: Int, from script: Script) {
        guard isActive else { return }
        guard index < script.chunks.count else {
            if !script.holdOpen { client?.urlProtocolDidFinishLoading(self) }
            return
        }
        client?.urlProtocol(self, didLoad: script.chunks[index])
        script.onChunk?()
        deliveryQueue.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in
            deliverChunk(at: index + 1, from: script)
        }
    }
}

private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onRedirect: () -> Void
    private let lock = NSLock()
    private(set) var redirectCount = 0
    private var storedObservedSession: URLSession?
    private var storedObservedQueueName: String?
    var observedSession: URLSession? { lock.withLock { storedObservedSession } }
    var observedQueueName: String? { lock.withLock { storedObservedQueueName } }

    init(onRedirect: @escaping () -> Void) {
        self.onRedirect = onRedirect
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping BoundedRedirectHandler
    ) {
        lock.withLock {
            redirectCount += 1
            storedObservedSession = session
            storedObservedQueueName = OperationQueue.current?.name
        }
        onRedirect()
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping BoundedAuthenticationChallengeHandler
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping BoundedAuthenticationChallengeHandler
    ) {
        completionHandler(.performDefaultHandling, nil)
    }
}
