import Foundation

/// What a name search against an open product source returned, in the shape the UI shows. The UI
/// never sees the provider's client or its outcome type; the app target adapts one to the other.
public enum ProductNameSearchOutcome: Sendable, Equatable {
    case results([LookedUpProduct])
    case empty
    case rateLimited(retryAfterSeconds: Int?)
    case failed(String)
}

/// Name search for the Find products screen. Implemented by the app target over the Open Food Facts client.
public protocol ProductNameSearching: Sendable {
    func search(query: String) async -> ProductNameSearchOutcome
    /// The source's full record for a picked search result. A search result carries the name and
    /// per-100 figures only; the full record adds the serving and whether the product is measured in
    /// grams or millilitres. Returns the result unchanged when the full record cannot be read.
    func details(for product: LookedUpProduct) async -> LookedUpProduct
}

extension ProductNameSearching {
    public func details(for product: LookedUpProduct) async -> LookedUpProduct { product }
}

/// The state of the open product source section of Find products.
public enum ProductNameSearchState: Equatable {
    case idle, queryTooShort, loading, results, empty, rateLimited(retryAfterSeconds: Int?), unavailable
}
