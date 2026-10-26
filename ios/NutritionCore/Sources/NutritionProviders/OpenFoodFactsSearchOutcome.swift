import Foundation

/// What a name search against Open Food Facts returned. A query that
/// is too short to search is answered `.empty` without any request being sent.
public enum OpenFoodFactsSearchOutcome: Sendable, Equatable {
    case results([OpenFoodFactsProduct])
    case empty
    case rateLimited(retryAfter: TimeInterval?)
    case transport(String)
}
