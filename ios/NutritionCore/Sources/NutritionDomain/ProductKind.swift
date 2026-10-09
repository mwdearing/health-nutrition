import Foundation

/// What kind of thing a product snapshot describes: something eaten, something drunk, or a supplement.
///
/// The kind is a property of the product and not of how much of it anyone logged, so it is recorded on
/// the snapshot rather than worked out from the entry. It is also what a coverage line has to leave out:
/// a multivitamin states no fiber, and its silence about fiber is not a gap in anybody's day.
///
/// The raw values are the stored and exported spelling. They are deliberately the same words an intake
/// category uses, so an entry typed by hand — which has no product snapshot to carry a kind — is logged
/// under a category that says what it is.
public enum ProductKind: String, Sendable, Hashable, Codable, CaseIterable {
    case food
    case drink
    case supplement

    /// The words a screen shows for this kind. Only a supplement is ever labeled on its own: a food and
    /// a drink read as themselves without a mark, and a label beside every row would say nothing.
    public var displayName: String {
        switch self {
        case .food: return "Food"
        case .drink: return "Drink"
        case .supplement: return "Supplement"
        }
    }

    /// An SF Symbol that marks the kind, or nil for the two that need no mark of their own.
    public var systemImage: String? {
        switch self {
        case .food, .drink: return nil
        case .supplement: return "pills"
        }
    }

    /// Whether a "N of M foods lack X" line counts a product of this kind.
    ///
    /// A food and a drink are what the line is about. A supplement is not one of them and is left out of
    /// both counts: it is never missing from the denominator, and it never produces a "lack" line about a
    /// nutrient no supplement is expected to state. The values a supplement does declare still count,
    /// in the day's totals.
    public var countsTowardCoverage: Bool {
        self != .supplement
    }

    /// The kind a stored or exported spelling names, or `.food` when it names none this build knows.
    ///
    /// A snapshot and an export written before this column and this field existed carry no kind at all,
    /// and a food is the honest reading of them: the app had no notion of a supplement then, so every
    /// product it recorded was recorded as the food it stood for. A spelling no build knows reads the
    /// same way rather than being refused, because it cannot describe anything the food reading misses.
    public init(storedRawValue: String?) {
        guard let raw = storedRawValue, let kind = ProductKind(rawValue: raw) else {
            self = .food
            return
        }
        self = kind
    }
}