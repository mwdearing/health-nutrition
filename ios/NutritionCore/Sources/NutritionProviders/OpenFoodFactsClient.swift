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
    private var recent: [Date] = []

    public init(
        environment: OpenFoodFactsEnvironment = .production,
        transport: OpenFoodFactsTransport = URLSessionOpenFoodFactsTransport(),
        appVersion: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.environment = environment
        self.transport = transport
        self.userAgent = "HealthNutrition/\(appVersion) (https://github.com/mwdearing/health-nutrition/issues)"
        self.now = now
    }

    public func lookup(barcode: String) async -> OpenFoodFactsOutcome {
        guard BarcodeValidator.isValid(barcode) else {
            return .invalidBarcode
        }
        let current = now()
        recent.removeAll { current.timeIntervalSince($0) >= Self.windowSeconds }
        if recent.count >= Self.maxLookups, let oldest = recent.first {
            return .rateLimited(retryAfter: max(0, oldest.addingTimeInterval(Self.windowSeconds).timeIntervalSince(current)))
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
            let header = response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            return .rateLimited(retryAfter: header)
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
