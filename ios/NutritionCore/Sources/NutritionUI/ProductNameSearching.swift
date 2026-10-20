import Foundation

/// What a name search against an open product source returned, in the shape the UI shows. The UI
/// never sees the provider's client or its outcome type; the app target adapts one to the other.
public enum ProductNameSearchOutcome: Sendable, Equatable {
    case results([LookedUpProduct])
    case empty
    case rateLimited(retryAfterSeconds: Int?)
    case failed(String)
}

/// Name search for the Search foods screen. Implemented by the app target over the Open Food Facts client.
public protocol ProductNameSearching: Sendable {
    func search(query: String) async -> ProductNameSearchOutcome
}

/// The state of the open product source section of Search foods.
public enum ProductNameSearchState: Equatable {
    case idle, queryTooShort, loading, results, empty, rateLimited(retryAfterSeconds: Int?), unavailable
}
