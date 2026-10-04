import Foundation

/// A live client for the NIH Dietary Supplement Label Database (DSLD).
///
/// The client is a seam around two endpoints and nothing else:
///
/// - `label(id:)` reads `GET /v9/label/<id>` and hands the bytes to `DSLDLabelAdapter`, so a live label
///   and a recorded one parse through exactly the same code path and the amount rules in
///   `docs/providers/dsld.md` hold for both.
/// - `search(term:limit:)` reads `GET /v9/search-filter?q=<term>&size=<n>` and returns identifiers and
///   names only.
///
/// Search is an explicit user action. There is deliberately no type-ahead: the database counts every
/// search as a request, a blank term sends nothing, and a caller that wants to run a search on every
/// keystroke must not, because it would spend the database's request budget on answers nobody asked for.
public actor DSLDClient {
    /// Waited before retrying when the API asks us to slow down without saying for how long.
    public static let defaultRetryAfter: TimeInterval = 60
    /// Hits a search asks for when the caller states no size.
    public static let defaultSearchSize = 10
    /// The most hits one search may ask for, however large a size the caller passes.
    public static let maximumSearchSize = 100
    private static let requestTimeout: TimeInterval = 15

    private let environment: DSLDEnvironment
    private let transport: DSLDTransport
    private let userAgent: String

    public init(
        environment: DSLDEnvironment = .production,
        transport: DSLDTransport = URLSessionDSLDTransport(),
        appVersion: String
    ) {
        self.environment = environment
        self.transport = transport
        self.userAgent = "HealthNutrition/\(appVersion) (+\(DSLDAttribution.issueURL))"
    }

    // MARK: - Label

    /// Reads one label by its DSLD identifier.
    ///
    /// An identifier the database could never hold sends no request and is `.failed`, because there is
    /// nothing to ask about; a 404 from the database is `.notFound` instead.
    public func label(id: Int) async -> DSLDOutcome {
        guard id > 0 else {
            return .failed(reason: "\(id) is not a DSLD label identifier")
        }
        guard let request = makeRequest(path: "/v9/label/\(id)", queryItems: []) else {
            return .failed(reason: "could not build the label request")
        }
        switch await fetch(request) {
        case .failure(let failure):
            return failure.labelOutcome
        case .success(let data):
            do {
                return .found(label: try DSLDLabelAdapter.parse(data))
            } catch {
                return .failed(reason: "the label could not be parsed: \(String(describing: error))")
            }
        }
    }

    // MARK: - Search

    /// Searches labels for a term the user asked for.
    ///
    /// Only identifiers and names come back. No amount is ever carried by a search hit, so every amount
    /// in the app still comes from `label(id:)` and the serving sizes that label states.
    ///
    /// The limit is clamped to `maximumSearchSize`, and a blank term is `.failed` without a request.
    public func search(term: String, limit: Int = DSLDClient.defaultSearchSize) async -> DSLDSearchOutcome {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failed(reason: "a search needs a term the user typed")
        }
        let size = Swift.min(Swift.max(limit, 1), Self.maximumSearchSize)
        guard let request = makeRequest(path: "/v9/search-filter", queryItems: [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "size", value: String(size)),
        ]) else {
            return .failed(reason: "could not build the search request")
        }
        switch await fetch(request) {
        case .failure(let failure):
            return failure.searchOutcome
        case .success(let data):
            do {
                return .found(results: try Self.decodeSearch(data))
            } catch {
                return .failed(reason: "the search response could not be read: \(String(describing: error))")
            }
        }
    }

    // MARK: - Requests

    /// One request, as either its body or the refusal it carried. A transport error is a refusal too:
    /// the request never completed, and the caller cannot tell that from a status it would have mapped.
    private enum Response {
        case success(Data)
        case failure(Refusal)
    }

    /// Everything that is not a body: a missing label, a request the database asked us to postpone, or
    /// a reason the request cannot be trusted.
    private enum Refusal {
        case notFound
        case rateLimited(retryAfter: TimeInterval)
        case failed(reason: String)

        var labelOutcome: DSLDOutcome {
            switch self {
            case .notFound: return .notFound
            case .rateLimited(let retryAfter): return .rateLimited(retryAfter: retryAfter)
            case .failed(let reason): return .failed(reason: reason)
            }
        }

        var searchOutcome: DSLDSearchOutcome {
            switch self {
            case .notFound: return .notFound
            case .rateLimited(let retryAfter): return .rateLimited(retryAfter: retryAfter)
            case .failed(let reason): return .failed(reason: reason)
            }
        }
    }

    private func fetch(_ request: URLRequest) async -> Response {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.get(request)
        } catch {
            return .failure(.failed(reason: String(describing: error)))
        }
        switch response.statusCode {
        case 200..<300:
            return .success(data)
        case 404:
            return .failure(.notFound)
        case 429, 503:
            // The database asks us to wait through Retry-After when it states a wait, and leaves the wait
            // to us when it does not. An unreadable header is no reason to retry immediately, so the
            // default stands in for it.
            let stated = response.value(forHTTPHeaderField: "Retry-After").flatMap { parseRetryAfter($0, now: Date()) }
            return .failure(.rateLimited(retryAfter: stated ?? Self.defaultRetryAfter))
        default:
            return .failure(.failed(reason: "the API answered with HTTP status \(response.statusCode)"))
        }
    }

    private func makeRequest(path: String, queryItems: [URLQueryItem]) -> URLRequest? {
        guard var components = URLComponents(url: environment.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

extension DSLDLabelAdapter {
    /// Parses one label body with an adapter.
    ///
    /// This is the entry point the live client uses. The client never interprets a label itself; it only
    /// fetches bytes and hands them to the adapter, so a live label and a recorded one take the same path
    /// through the same amount rules.
    public static func parse(
        _ data: Data,
        using adapter: DSLDLabelAdapter = DSLDLabelAdapter()
    ) throws -> DSLDSupplementLabel {
        try adapter.parse(data)
    }
}

extension DSLDClient {
    /// Reads a `search-filter` body into identifiers and names.
    ///
    /// The reader keeps every number as the literal text the API wrote and never builds a floating point
    /// value, the same rule the label adapter follows. A hit without a usable identifier is skipped
    /// rather than guessed at, so no search result can name a label the database does not hold.
    static func decodeSearch(_ data: Data) throws -> DSLDSearchResults {
        let document = try DSLDJSONReader.read(data)
        guard let root = document.objectValue else {
            throw DSLDSearchError.notAnObject
        }
        guard let entries = root["hits"]?.arrayValue else {
            throw DSLDSearchError.missingHits
        }
        var decoded: [DSLDSearchHit] = []
        for entry in entries {
            guard let hit = entry.objectValue, let identifier = identifier(in: hit) else { continue }
            let source = hit["_source"]?.objectValue ?? [:]
            decoded.append(
                DSLDSearchHit(
                    id: identifier,
                    fullName: text(in: source, "fullName") ?? "",
                    brandName: text(in: source, "brandName") ?? "",
                    offMarket: source["offMarket"]?.flagValue ?? false
                )
            )
        }
        return DSLDSearchResults(hits: decoded, total: total(in: root))
    }

    /// The identifier of a search hit, from `_id` or from `id` inside `_source`. DSLD writes the first as
    /// text and the second as a number, so both spellings are read.
    private static func identifier(in hit: [String: DSLDJSON]) -> Int? {
        let source = hit["_source"]?.objectValue ?? [:]
        for value in [hit["_id"], source["id"]] {
            if let value, let identifier = integerLiteral(value), identifier > 0 {
                return identifier
            }
        }
        return nil
    }

    /// How many labels the database holds for the term, when the body states a count. A page of ten hits
    /// can stand for thousands of labels, and this is that number. It is nil when the body states none.
    private static func total(in root: [String: DSLDJSON]) -> Int? {
        if let stats = root["stats"]?.objectValue, let count = integerLiteral(stats["count"] ?? .null) {
            return count
        }
        return integerLiteral(root["count"] ?? .null)
    }

    private static func integerLiteral(_ value: DSLDJSON) -> Int? {
        if let text = value.numberText {
            return Int(text)
        }
        if let text = value.stringValue {
            return Int(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func text(in object: [String: DSLDJSON], _ key: String) -> String? {
        guard let value = object[key]?.stringValue else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}