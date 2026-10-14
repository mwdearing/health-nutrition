import Foundation

public actor OpenFoodFactsClient {
    public static let requestedFields = [
        "code", "product_name", "brands", "serving_size", "serving_quantity",
        "nutrition_data_per", "nutriments", "last_modified_t", "product_quantity_unit",
    ]
    /// Open Food Facts publishes 15 product reads per minute for apps; we stay below that at 10.
    public static let maxLookups = 10
    public static let windowSeconds: TimeInterval = 60
    /// Open Food Facts allows 10 search requests per minute; we stay below at 6.
    public static let maxSearches = 6
    public static let searchMinimumScalars = 2
    public static let searchMaximumCharacters = 80
    public static let searchPageSize = 20
    public static let searchFields = ["code", "product_name", "brands", "nutriments", "last_modified_t"]
    /// Characters the search service reads as query syntax (field filters, grouping, ranges, wildcards,
    /// boosts, negation, regular expressions). None of them helps find a food by name.
    private static let searchSyntax = CharacterSet(charactersIn: "+-&|!(){}[]^\"~*?:\\/<>=")
    private static let searchOperators: Set<String> = ["AND", "OR", "NOT", "TO"]

    private let environment: OpenFoodFactsEnvironment
    private let transport: OpenFoodFactsTransport
    private let userAgent: String
    private let now: @Sendable () -> Date
    private let monotonic: @Sendable () -> TimeInterval
    private var recent: [TimeInterval] = []
    private var recentSearches: [TimeInterval] = []
    /// Replies to name searches sent inside the current window, by the trimmed query that was sent.
    private var answeredSearches: [String: (sentAt: TimeInterval, outcome: OpenFoodFactsSearchOutcome)] = [:]
    private var searchesInFlight: [String: Task<OpenFoodFactsSearchOutcome, Never>] = [:]

    public init(
        environment: OpenFoodFactsEnvironment = .production,
        transport: OpenFoodFactsTransport = URLSessionOpenFoodFactsTransport(),
        appVersion: String,
        now: @escaping @Sendable () -> Date = { Date() },
        monotonic: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.environment = environment
        self.transport = transport
        self.userAgent = "HealthNutrition/\(appVersion) (https://github.com/mwdearing/health-nutrition/issues)"
        self.now = now
        self.monotonic = monotonic
    }

    public func lookup(barcode: String) async -> OpenFoodFactsOutcome {
        guard BarcodeValidator.isValid(barcode) else {
            return .invalidBarcode
        }
        let current = monotonic()
        recent.removeAll { current - $0 >= Self.windowSeconds }
        if recent.count >= Self.maxLookups, let oldest = recent.first {
            return .rateLimited(retryAfter: max(0, oldest + Self.windowSeconds - current))
        }
        recent.append(current)

        guard let request = makeRequest(barcode: barcode) else {
            return .transport("could not build the request")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.get(request)
        } catch BoundedResponseError.responseTooLarge {
            return .transport("response exceeded the local size limit")
        } catch {
            return .transport(String(describing: error))
        }
        switch response.statusCode {
        case 200..<300:
            break
        case 404:
            return .notFound
        case 429, 503:
            let header = response.value(forHTTPHeaderField: "Retry-After")
            return .rateLimited(retryAfter: header.flatMap { parseRetryAfter($0, now: now()) })
        default:
            return .transport("HTTP status \(response.statusCode)")
        }
        return Self.interpret(data, barcode: barcode)
    }

    /// Name search on the full-text search service, which ranks products by how well their name matches.
    /// The query is trimmed, capped and reduced to plain words; one shorter than two characters is
    /// answered `.empty` without spending a rate-limit slot or sending a request.
    ///
    /// Submitting the same query again inside the window sends nothing and spends no slot: it gets the
    /// reply already received, or waits for the request still running. Only a reply with results or
    /// none is kept; a failed or refused search is sent again when the person retries.
    public func search(query: String) async -> OpenFoodFactsSearchOutcome {
        let trimmed = Self.plainWords(
            String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.searchMaximumCharacters)))
        guard trimmed.count >= Self.searchMinimumScalars else {
            return .empty
        }
        guard environment.searchBaseURL != nil else {
            return .transport("no search service in this environment")
        }
        let current = monotonic()
        answeredSearches = answeredSearches.filter { current - $0.value.sentAt < Self.windowSeconds }
        if let answered = answeredSearches[trimmed] {
            return answered.outcome
        }
        if let running = searchesInFlight[trimmed] {
            return await running.value
        }
        recentSearches.removeAll { current - $0 >= Self.windowSeconds }
        if recentSearches.count >= Self.maxSearches, let oldest = recentSearches.first {
            return .rateLimited(retryAfter: max(0, oldest + Self.windowSeconds - current))
        }
        recentSearches.append(current)

        // The request runs in its own task, so a caller that stops waiting does not cancel it: the slot
        // is already spent, and the reply answers the next submit of the same query.
        let running = Task { await self.sendSearch(query: trimmed) }
        searchesInFlight[trimmed] = running
        let outcome = await running.value
        searchesInFlight[trimmed] = nil
        switch outcome {
        case .results, .empty:
            answeredSearches[trimmed] = (current, outcome)
        case .rateLimited, .transport:
            break
        }
        return outcome
    }

    private func sendSearch(query trimmed: String) async -> OpenFoodFactsSearchOutcome {
        guard let request = makeSearchRequest(query: trimmed) else {
            return .transport("could not build the request")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.get(
                request, maxBytes: BoundedResponseLimits.openFoodFactsSearch)
        } catch {
            return .transport(String(describing: error))
        }
        switch response.statusCode {
        case 200..<300:
            break
        case 429:
            let header = response.value(forHTTPHeaderField: "Retry-After")
            return .rateLimited(retryAfter: header.flatMap { parseRetryAfter($0, now: now()) })
        case 503:
            // The search endpoint answers 503 with no Retry-After when it is down or shedding load. That
            // is the source being unavailable, not a limit this person reached.
            guard let wait = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap({ parseRetryAfter($0, now: now()) }) else {
                return .transport("HTTP status 503")
            }
            return .rateLimited(retryAfter: wait)
        default:
            return .transport("HTTP status \(response.statusCode)")
        }
        guard data.count <= BoundedResponseLimits.openFoodFactsSearch else {
            return .transport("response too large")
        }
        return Self.interpretSearch(data, query: trimmed)
    }

    /// The typed text as plain words. The service parses its query as a language, so every syntax
    /// character becomes a space and an operator word is lowercased, which makes it an ordinary word.
    /// What is sent can then only ever be a list of words to match.
    static func plainWords(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { searchSyntax.contains($0) ? " " : $0 }))
            .split(whereSeparator: \.isWhitespace)
            .map { searchOperators.contains(String($0)) ? $0.lowercased() : String($0) }
            .joined(separator: " ")
    }

    private func makeSearchRequest(query: String) -> URLRequest? {
        guard let base = environment.searchBaseURL else {
            return nil
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/search"
        // Nothing but the words is sent: no language, country or sort. The service's default order is
        // relevance to the words.
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page_size", value: String(Self.searchPageSize)),
            URLQueryItem(name: "fields", value: Self.searchFields.joined(separator: ",")),
        ]
        guard let url = components?.url else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Lowercased with accents removed, so "Crème" and "creme" compare equal.
    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func interpretSearch(_ data: Data, query: String) -> OpenFoodFactsSearchOutcome {
        guard let decoded = try? JSONDecoder().decode(OpenFoodFactsSearchResponse.self, from: data) else {
            return .transport("unreadable response")
        }
        var seen: Set<String> = []
        let products: [OpenFoodFactsProduct] = (decoded.hits ?? []).compactMap { hit in
            // A reply is untrusted: only a well-formed barcode becomes a result.
            // The stored code is the one that was validated: a padded value is refused, not trimmed for the
            // check and kept as received.
            guard let code = hit.code?.text, BarcodeValidator.isValid(code) else {
                return nil
            }
            // A result with no name cannot be told apart in a list of names, so it is left out.
            guard let name = hit.product_name?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return nil
            }
            let product = OpenFoodFactsProduct(hit: hit, barcode: code, name: name)
            // The same name and brand again is the same row to the reader; the better match came first.
            let brand = product.brands?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard seen.insert(name.lowercased() + "\u{1F}" + brand.lowercased()).inserted else {
                return nil
            }
            return product
        }
        // The service also matches on brand, category and names in other languages, so a row can rank
        // high without the words in the name shown. Rows whose name has every word go first; the
        // service's order is kept inside each group and nothing is dropped.
        let words = folded(query).split(separator: " ").map(String.init)
        func named(_ product: OpenFoodFactsProduct) -> Bool {
            let name = folded(product.name ?? "")
            return words.allSatisfy { name.contains($0) }
        }
        let ordered = products.filter(named) + products.filter { !named($0) }
        let limited = Array(ordered.prefix(Self.searchPageSize))
        return limited.isEmpty ? .empty : .results(limited)
    }

    private func makeRequest(barcode: String) -> URLRequest? {
        var components = URLComponents(url: environment.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/api/v3/product/\(barcode)"
        components?.queryItems = [URLQueryItem(name: "fields", value: Self.requestedFields.joined(separator: ","))]
        guard let url = components?.url else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = environment.authorizationHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func interpret(_ data: Data, barcode: String) -> OpenFoodFactsOutcome {
        guard let decoded = try? JSONDecoder().decode(OpenFoodFactsResponse.self, from: data) else {
            return .transport("unreadable response")
        }
        if decoded.result?.id == "product_not_found" {
            return .notFound
        }
        guard let body = decoded.product else {
            return .transport("response without a product")
        }
        return .found(OpenFoodFactsProduct(body: body, requestedBarcode: barcode))
    }
}

/// The longest wait a Retry-After header can ask for. A larger or unreadable-as-a-number value is cut to this, so a
/// hostile or broken header can never become a figure the app cannot represent.
let maxRetryAfter: TimeInterval = 86_400

/// Retry-After is either delay-seconds or an HTTP-date (RFC 9110); the result is never negative and never more than
/// `maxRetryAfter`.
func parseRetryAfter(_ raw: String, now: Date) -> TimeInterval? {
    let value = raw.trimmingCharacters(in: .whitespaces)
    if !value.isEmpty, value.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) {
        return TimeInterval(value).map { min($0, maxRetryAfter) }
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    guard let date = formatter.date(from: value) else {
        return nil
    }
    return min(max(0, date.timeIntervalSince(now)), maxRetryAfter)
}
