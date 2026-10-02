import Foundation

public actor OpenFoodFactsClient {
    public static let requestedFields = [
        "code", "product_name", "brands", "serving_size", "serving_quantity",
        "nutrition_data_per", "nutriments", "last_modified_t",
    ]
    /// Open Food Facts allows 100 product reads per minute; we stay far below at 15.
    public static let maxLookups = 15
    public static let windowSeconds: TimeInterval = 60

    private let environment: OpenFoodFactsEnvironment
    private let transport: OpenFoodFactsTransport
    private let userAgent: String
    private let now: @Sendable () -> Date
    private let monotonic: @Sendable () -> TimeInterval
    private var recent: [TimeInterval] = []

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

/// Retry-After is either delay-seconds or an HTTP-date (RFC 9110); the result is never negative.
func parseRetryAfter(_ raw: String, now: Date) -> TimeInterval? {
    let value = raw.trimmingCharacters(in: .whitespaces)
    if !value.isEmpty, value.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) {
        return TimeInterval(value)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    guard let date = formatter.date(from: value) else {
        return nil
    }
    return max(0, date.timeIntervalSince(now))
}
