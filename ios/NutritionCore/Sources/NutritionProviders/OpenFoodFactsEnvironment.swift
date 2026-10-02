import Foundation

public struct OpenFoodFactsEnvironment: Sendable, Hashable {
    public let baseURL: URL
    /// Value for the Authorization header; only the staging server asks for it.
    public let authorizationHeader: String?

    public init(baseURL: URL, authorizationHeader: String?) {
        self.baseURL = baseURL
        self.authorizationHeader = authorizationHeader
    }

    public static let production = OpenFoodFactsEnvironment(
        baseURL: URL(string: "https://world.openfoodfacts.org")!,
        authorizationHeader: nil
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
