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

    /// Staging is for tests only. Its shared basic-auth credentials are public.
    public static let staging = OpenFoodFactsEnvironment(
        baseURL: URL(string: "https://world.openfoodfacts.net")!,
        authorizationHeader: "Basic " + Data("off:off".utf8).base64EncodedString()
    )
}

public enum OpenFoodFactsAttribution: Sendable {
    public static let text = "Nutrition facts from Open Food Facts, available under the Open Database License (ODbL)."
    public static let url = "https://world.openfoodfacts.org"
}
