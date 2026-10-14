import Foundation

public struct OpenFoodFactsEnvironment: Sendable, Hashable {
    public let baseURL: URL
    /// Value for the Authorization header; only the staging server asks for it.
    public let authorizationHeader: String?
    /// The full-text search service, a separate host from the product API. Nil where there is none:
    /// name search then sends nothing. The Authorization header is never sent to it.
    public let searchBaseURL: URL?

    public init(baseURL: URL, authorizationHeader: String?, searchBaseURL: URL? = nil) {
        self.baseURL = baseURL
        self.authorizationHeader = authorizationHeader
        self.searchBaseURL = searchBaseURL
    }

    public static let production = OpenFoodFactsEnvironment(
        baseURL: URL(string: "https://world.openfoodfacts.org")!,
        authorizationHeader: nil,
        searchBaseURL: URL(string: "https://search.openfoodfacts.org")!
    )

    /// Staging is for manual checks only. The caller injects the Authorization header value
    /// (the staging credentials are published in the Open Food Facts documentation); it is
    /// never stored in this repository.
    public static func staging(authorization: String?) -> OpenFoodFactsEnvironment {
        OpenFoodFactsEnvironment(
            baseURL: URL(string: "https://world.openfoodfacts.net")!,
            authorizationHeader: authorization
        )
    }
}

public enum OpenFoodFactsAttribution: Sendable {
    public static let text = "Nutrition facts from Open Food Facts, available under the Open Database License (ODbL)."
    public static let url = "https://world.openfoodfacts.org"
}
