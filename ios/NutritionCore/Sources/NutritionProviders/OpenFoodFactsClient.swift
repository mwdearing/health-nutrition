import Foundation

public actor OpenFoodFactsClient {
    public static let requestedFields = [
        "code", "product_name", "brands", "serving_size", "serving_quantity",
        "nutrition_data_per", "nutriments", "last_modified_t", "product_quantity_unit",
    ]
    /// Open Food Facts allows 100 product reads per minute; we stay far below at 15.
    public static let maxLookups = 15
    public static let windowSeconds: TimeInterval = 60
    /// Open Food Facts allows 10 search requests per minute; we stay below at 6.
    public static let maxSearches = 6
    public static let searchMinimumScalars = 2
    public static let searchMaximumCharacters = 80
    public static let searchPageSize = 20

    private let environment: OpenFoodFactsEnvironment
    private let transport: OpenFoodFactsTransport
    private let userAgent: String
    private let now: @Sendable () -> Date
    private let monotonic: @Sendable () -> TimeInterval
    private var recent: [TimeInterval] = []
    private var recentSearches: [TimeInterval] = []

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

    /// Name search. The query is trimmed and capped; a query shorter than two characters is answered
    /// `.empty` without spending a rate-limit slot or sending a request.
    public func search(query: String) async -> OpenFoodFactsSearchOutcome {
        let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.searchMaximumCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count >= Self.searchMinimumScalars else {
            return .empty
        }
        let current = monotonic()
        recentSearches.removeAll { current - $0 >= Self.windowSeconds }
        if recentSearches.count >= Self.maxSearches, let oldest = recentSearches.first {
            return .rateLimited(retryAfter: max(0, oldest + Self.windowSeconds - current))
        }
        recentSearches.append(current)

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
        case 429, 503:
            let header = response.value(forHTTPHeaderField: "Retry-After")
            return .rateLimited(retryAfter: header.flatMap { parseRetryAfter($0, now: now()) })
        default:
            return .transport("HTTP status \(response.statusCode)")
        }
        guard data.count <= BoundedResponseLimits.openFoodFactsSearch else {
            return .transport("response too large")
        }
        return Self.interpretSearch(data)
    }

    private func makeSearchRequest(query: String) -> URLRequest? {
        // Only the typed text is encoded as the search term. `+`, `&` and `=` are escaped, so the server
        // reads them as typed rather than as separators or spaces.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encodedTerms = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        var components = URLComponents(url: environment.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/cgi/search.pl"
        components?.percentEncodedQueryItems = [
            URLQueryItem(name: "search_terms", value: encodedTerms),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: String(Self.searchPageSize)),
            URLQueryItem(name: "fields", value: Self.requestedFields.joined(separator: ",")),
        ]
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

    private static func interpretSearch(_ data: Data) -> OpenFoodFactsSearchOutcome {
        guard let decoded = try? JSONDecoder().decode(OpenFoodFactsSearchResponse.self, from: data) else {
            return .transport("unreadable response")
        }
        let products: [OpenFoodFactsProduct] = (decoded.products ?? []).compactMap { body in
            // A reply is untrusted: only a well-formed barcode becomes a result.
            // The stored code is the one that was validated: a padded value is refused, not trimmed for the
            // check and kept as received.
            guard let code = body.code?.text, BarcodeValidator.isValid(code) else {
                return nil
            }
            return OpenFoodFactsProduct(body: body, requestedBarcode: code)
        }
        let limited = Array(products.prefix(Self.searchPageSize))
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
