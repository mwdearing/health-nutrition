import Foundation
#if canImport(ObjectiveC)
import ObjectiveC
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Per-response payload limits applied before a provider decodes JSON.
enum BoundedResponseLimits {
    static let community = 1 * 1_024 * 1_024
    static let openFoodFacts = 4 * 1_024 * 1_024
    static let dsld = 8 * 1_024 * 1_024
    /// Twenty search results with the requested fields are well under this.
    static let openFoodFactsSearch = 1 * 1_024 * 1_024
}

enum BoundedResponseError: Error, Equatable, Sendable {
    case invalidLimit
    case responseTooLarge
}

#if canImport(ObjectiveC)
typealias BoundedRedirectHandler = (URLRequest?) -> Void
typealias BoundedAuthenticationChallengeHandler = (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
typealias BoundedResponseDispositionHandler = (URLSession.ResponseDisposition) -> Void
#else
typealias BoundedRedirectHandler = @Sendable (URLRequest?) -> Void
typealias BoundedAuthenticationChallengeHandler = @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
typealias BoundedResponseDispositionHandler = @Sendable (URLSession.ResponseDisposition) -> Void
#endif

/// Reads URLSession data incrementally and refuses a response before its buffered body exceeds `maxBytes`.
enum BoundedResponseLoader {
    static func data(
        for request: URLRequest, session: URLSession, maxBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        guard maxBytes > 0 else { throw BoundedResponseError.invalidLimit }
        try Task.checkCancellation()
        let operation = BoundedResponseOperation(
            originalSession: session,
            configuration: session.configuration,
            forwardingDelegate: session.delegate,
            delegateQueue: session.delegateQueue,
            maxBytes: maxBytes)
        return try await operation.load(request)
    }
}

final class BoundedResponseOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let originalSession: URLSession
    private let configuration: URLSessionConfiguration
    private let forwardingDelegate: URLSessionDelegate?
    private let delegateQueue: OperationQueue
    private let maxBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var finished = false

    init(
        originalSession: URLSession,
        configuration: URLSessionConfiguration,
        forwardingDelegate: URLSessionDelegate?,
        delegateQueue: OperationQueue,
        maxBytes: Int
    ) {
        self.originalSession = originalSession
        self.configuration = configuration
        self.forwardingDelegate = forwardingDelegate
        self.delegateQueue = delegateQueue
        self.maxBytes = maxBytes
    }

    // These policy callbacks are routed explicitly so an injected delegate observes the original
    // session identity. Response, data and completion callbacks stay with this bounded reader,
    // matching URLSession's async data(for:) behavior.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping BoundedRedirectHandler
    ) {
        guard forwardingDelegate != nil else {
            completionHandler(request)
            return
        }
        // URLSession owns its delegate queue. Sharing the injected session's queue with this
        // second session can stall completion when a response is canceled while streaming.
        // Forward policy callbacks back to the injected session's queue instead.
        delegateQueue.addOperation { [self] in
#if canImport(ObjectiveC)
        let selector = #selector(URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:))
        if let delegate = forwardingDelegate as? URLSessionTaskDelegate,
           delegate.responds(to: selector) {
            delegate.urlSession?(originalSession, task: task, willPerformHTTPRedirection: response,
                                 newRequest: request, completionHandler: completionHandler)
        } else {
            completionHandler(request)
        }
#else
        if let delegate = forwardingDelegate as? URLSessionTaskDelegate {
            delegate.urlSession(originalSession, task: task, willPerformHTTPRedirection: response,
                                newRequest: request, completionHandler: completionHandler)
        } else {
            completionHandler(request)
        }
#endif
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping BoundedAuthenticationChallengeHandler
    ) {
        guard forwardingDelegate != nil else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        delegateQueue.addOperation { [self] in
#if canImport(ObjectiveC)
        let taskSelector = #selector(URLSessionTaskDelegate.urlSession(_:task:didReceive:completionHandler:))
        let sessionSelector = #selector(URLSessionDelegate.urlSession(_:didReceive:completionHandler:))
        if let delegate = forwardingDelegate as? URLSessionTaskDelegate,
           delegate.responds(to: taskSelector) {
            delegate.urlSession?(originalSession, task: task, didReceive: challenge, completionHandler: completionHandler)
        } else if let delegate = forwardingDelegate, delegate.responds(to: sessionSelector) {
            delegate.urlSession?(originalSession, didReceive: challenge, completionHandler: completionHandler)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
#else
        if let delegate = forwardingDelegate as? URLSessionTaskDelegate {
            delegate.urlSession(originalSession, task: task, didReceive: challenge, completionHandler: completionHandler)
        } else if let delegate = forwardingDelegate {
            delegate.urlSession(originalSession, didReceive: challenge, completionHandler: completionHandler)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
#endif
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping BoundedAuthenticationChallengeHandler
    ) {
        guard forwardingDelegate != nil else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        delegateQueue.addOperation { [self] in
#if canImport(ObjectiveC)
        let selector = #selector(URLSessionDelegate.urlSession(_:didReceive:completionHandler:))
        if let delegate = forwardingDelegate, delegate.responds(to: selector) {
            delegate.urlSession?(originalSession, didReceive: challenge, completionHandler: completionHandler)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
#else
        if let delegate = forwardingDelegate {
            delegate.urlSession(originalSession, didReceive: challenge, completionHandler: completionHandler)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
#endif
        }
    }

    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                begin(request, continuation: continuation)
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    private func begin(
        _ request: URLRequest,
        continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
    ) {
        let mayStart = lock.withLock { () -> Bool in
            guard !finished else { return false }
            self.continuation = continuation
            return true
        }
        guard mayStart else {
            continuation.resume(throwing: CancellationError())
            return
        }

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        let shouldStart = lock.withLock { () -> Bool in
            guard !finished else { return false }
            self.session = session
            self.task = task
            return true
        }
        guard shouldStart else {
            session.invalidateAndCancel()
            return
        }
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping BoundedResponseDispositionHandler
    ) {
        let http = response as? HTTPURLResponse
        let advertisedLength = http?.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
            ?? http?.expectedContentLength ?? -1
        let refusal: Error?
        if http == nil {
            refusal = URLError(.badServerResponse)
        } else if advertisedLength > Int64(maxBytes) {
            refusal = BoundedResponseError.responseTooLarge
        } else {
            refusal = nil
            lock.withLock {
                if !finished { self.response = http }
            }
        }

        completionHandler(.allow)
        if let refusal { finish(.failure(refusal)) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        enum ChunkDecision: Equatable { case accept, overflow, discard }
        let decision = lock.withLock { () -> ChunkDecision in
            guard !finished else { return .discard }
            guard data.count <= maxBytes - body.count else { return .overflow }
            body.append(data)
            return .accept
        }
        if decision == .overflow {
            finish(.failure(BoundedResponseError.responseTooLarge))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        let result = lock.withLock { () -> Result<(Data, HTTPURLResponse), Error>? in
            guard !finished else { return nil }
            guard let response else {
                return .failure(URLError(.badServerResponse))
            }
            return .success((body, response))
        }
        if let result { finish(result) }
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        let completed = lock.withLock {
            () -> (CheckedContinuation<(Data, HTTPURLResponse), Error>?, URLSession?, URLSessionDataTask?) in
            guard !finished else { return (nil, nil, nil) }
            finished = true
            let continuation = self.continuation
            let session = self.session
            let task = self.task
            self.continuation = nil
            self.session = nil
            self.task = nil
            return (continuation, session, task)
        }
        completed.0?.resume(with: result)
        if let session = completed.1 {
            // URLSession delegate callbacks may invoke this method. Invalidation can wait for the delegate
            // queue to drain, so do it off that queue after cancellation/resumption.
            let shouldCancel: Bool
            if case .success = result { shouldCancel = false } else { shouldCancel = true }
            DispatchQueue.global(qos: .utility).async {
                if shouldCancel { completed.2?.cancel() }
                session.invalidateAndCancel()
            }
        }
    }
}
