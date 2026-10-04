import Foundation

/// What a single label lookup produced.
///
/// A lookup has exactly four outcomes, and none of them is a guess: a label either came back and parsed,
/// the database says it has no such label, the database asked us to slow down, or the request or the
/// response could not be trusted.
public enum DSLDOutcome: Sendable, Equatable {
    /// The label was returned by the API and parsed by `DSLDLabelAdapter`.
    case found(label: DSLDSupplementLabel)
    /// The API has no label with this identifier (HTTP 404).
    case notFound
    /// The API refused the request for now (HTTP 429 or 503). `retryAfter` is the number of seconds
    /// `Retry-After` asked for, or `DSLDClient.defaultRetryAfter` when the header is absent or unreadable.
    case rateLimited(retryAfter: TimeInterval)
    /// The request never completed, or the body was not a label the adapter could parse.
    case failed(reason: String)
}

/// One hit of a DSLD search: an identifier and the names to show, nothing more.
///
/// A search never returns amounts. A caller that wants facts fetches the label by identifier, so every
/// amount in the app still comes from the label endpoint and its serving sizes.
public struct DSLDSearchHit: Sendable, Hashable {
    /// The DSLD label identifier, to be passed to `DSLDClient.label(id:)`.
    public let id: Int
    /// `fullName` of the label, empty when the search hit states none.
    public let fullName: String
    /// `brandName` of the label, empty when the search hit states none.
    public let brandName: String
    /// True when the hit is recorded as off market. Off-market labels are still readable.
    public let offMarket: Bool

    public init(id: Int, fullName: String, brandName: String, offMarket: Bool) {
        self.id = id
        self.fullName = fullName
        self.brandName = brandName
        self.offMarket = offMarket
    }
}

/// Why a `search-filter` body could not be read.
///
/// A search response is not a label, so it has its own errors rather than borrowing the adapter's. Bytes
/// that are not well-formed JSON still throw `DSLDAdapterError.malformedJSON`, because that is what the
/// shared reader raises.
public enum DSLDSearchError: Error, Sendable, Equatable {
    /// The document is well-formed JSON but not a JSON object.
    case notAnObject
    /// The document has no `hits` array, so it is not a search response.
    case missingHits
}

/// The hits of a DSLD search.
public struct DSLDSearchResults: Sendable, Equatable {
    public let hits: [DSLDSearchHit]
    /// How many labels the database holds for the term, when it states a count. A search page of ten
    /// hits can stand for thousands of labels, and this is that number.
    public let total: Int?

    public init(hits: [DSLDSearchHit], total: Int?) {
        self.hits = hits
        self.total = total
    }
}

/// What a search produced. The same four outcomes as a lookup, with the hits in place of the label.
public enum DSLDSearchOutcome: Sendable, Equatable {
    case found(results: DSLDSearchResults)
    case notFound
    case rateLimited(retryAfter: TimeInterval)
    case failed(reason: String)
}