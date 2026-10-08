import Foundation
import NutritionDomain

/// The nutrients a US Nutrition Facts panel states, named with the keys the journal and the write plan
/// already use (`energyKcal`, `fat`, `addedSugars`, …). A parsed panel always carries every key, so a
/// consumer never has to ask whether a key is missing from the dictionary.
public enum NutritionFactKey: String, Sendable, Hashable, CaseIterable {
    /// The panel's "Calories" row. The key is the journal's `energyKcal`.
    case calories = "energyKcal"
    case fat
    case saturatedFat
    case transFat
    case cholesterol
    case sodium
    case carbohydrates
    case fiber
    case sugars
    case addedSugars
    case protein
    case vitaminD
    case calcium
    case iron
    case potassium
}

/// The serving size as the label prints it, plus the measure it states when it states one.
public struct ParsedServingSize: Sendable, Hashable {
    /// The text after "Serving size", for example `1 cup (240mL)`.
    public let text: String
    /// The stated measure, taken from the parentheses when the label writes one: `1 cup (240mL)` gives
    /// `240 mL`. `nil` when the text states no measure the registry carries, because a household word on
    /// its own ("1 large biscuit") is never turned into an amount.
    public let quantity: Quantity?
    /// Why the measure needed a correction, or `nil` when it was read exactly as printed. The serving
    /// size scales every nutrient saved from this panel, so a correction here is shown to the user before
    /// anything is saved.
    public let review: ParsedValueReview?

    public init(text: String, quantity: Quantity?, review: ParsedValueReview? = nil) {
        self.text = text
        self.quantity = quantity
        self.review = review
    }
}

/// Why the confirmation screen should highlight a value: the parser read the line, but not with the
/// confidence a clean row has.
public struct ParsedValueReview: Sendable, Hashable {
    public enum Reason: String, Sendable, Hashable, CaseIterable {
        /// A letter `O` stood where a zero belongs, so the printed text was corrected to read the number.
        case correctedLetterO
        /// The unit the row carries is not the unit this nutrient usually carries, so the amount is kept
        /// exactly as printed and the value is not silently rewritten.
        case unexpectedUnit
        /// A microgram symbol OCR spelled as `µg`, `μg` or `ug` was normalised to `mcg`.
        case normalisedMicrogramSymbol
    }

    public let reasons: Set<Reason>

    public init(reasons: Set<Reason>) {
        self.reasons = reasons
    }
}

/// Which panel the capture read: a **Nutrition Facts** panel, which states a food or a drink, or a
/// **Supplement Facts** panel, which states what is in a supplement.
///
/// The distinction is the whole reason the kind is recorded. The two panels print some of the same rows
/// — vitamin D, calcium, iron and potassium are named on both — so the values read off a supplement are
/// read just as carefully; what differs is what the absence of a row means. A food that says nothing
/// about fibre has a gap in it, and a supplement that says nothing about fibre is a supplement.
public enum NutritionPanelKind: String, Sendable, Hashable, Codable, CaseIterable {
    case nutritionFacts
    case supplementFacts

    /// The product kind a captured panel is recorded as.
    ///
    /// Only a Supplement Facts panel makes a supplement. Everything else is recorded as a food, which is
    /// what a capture read before this distinction existed recorded every panel as.
    public var productKind: ProductKind {
        switch self {
        case .nutritionFacts: return .food
        case .supplementFacts: return .supplement
        }
    }
}

/// One row of a panel that the table of named nutrients does not carry.
///
/// A supplement states its own compounds routinely — `Creatine Monohydrate 3g`, `Zinc 15mg` — and
/// reading them is the point of scanning one, so the row is kept under the name the label printed and
/// a slug of that name rather than dropped for having no key in the journal's table.
public struct ParsedAdditionalNutrient: Sendable, Hashable, Identifiable {
    /// The name the label printed for the compound, as it printed it.
    public let name: String
    /// The key the value is stored under: `creatine-monohydrate` for `Creatine Monohydrate`.
    public let key: String
    /// The value, in the unit the row printed.
    public let value: NutrientValue
    /// Why the value was read with less than full confidence, or nil when it was read as printed.
    public let review: ParsedValueReview?

    public init(name: String, key: String, value: NutrientValue, review: ParsedValueReview? = nil) {
        self.name = name
        self.key = key
        self.value = value
        self.review = review
    }

    public var id: String { key }
}

/// One Nutrition Facts panel, read from the text a capture session produced.
///
/// The parser is pure: text in, a panel out. Nothing here is saved anywhere, and nothing here decides
/// that a value is right. A value the panel does not state is `.unknown`, which is never the same
/// amount as a stated zero, and a value the parser had to correct is listed in
/// `valuesNeedingReview` so the confirmation screen can highlight it before the user saves anything.
public struct ParsedNutritionFacts: Sendable, Hashable {
    /// The serving size the panel states, or `nil` when it states none.
    public let servingSize: ParsedServingSize?
    /// The servings-per-container count, or `nil` when the panel states none.
    public let servingsPerContainer: Decimal?
    /// Per serving, keyed by `NutritionFactKey.rawValue`. Every key is present.
    public let nutrients: [String: NutrientValue]
    /// The rows the panel states that the named table does not carry, in the order it printed them.
    /// Empty for a panel that names every row it states.
    public let additionalNutrients: [ParsedAdditionalNutrient]
    /// The name the panel printed for a nutrient, keyed by `NutritionFactKey.rawValue`, when that name
    /// carries a chemical form: `Calcium Citrate 200mg` is calcium, and the form is kept here so the
    /// review screen can show the words the label printed rather than only the journal's own name.
    public let nutrientDisplayNames: [String: String]
    /// Only the values that were read with less than full confidence, keyed the same way as `nutrients`.
    public let valuesNeedingReview: [String: ParsedValueReview]
    /// Which panel was read: a Nutrition Facts panel or a Supplement Facts one.
    ///
    /// Nutrition Facts unless the capture found the other heading. A panel whose heading was missed,
    /// cropped away or misread is recorded as the food it always was before this was known, so a failed
    /// recognition costs the label's kind and never its values.
    public let panelKind: NutritionPanelKind

    public init(
        servingSize: ParsedServingSize?,
        servingsPerContainer: Decimal?,
        nutrients: [String: NutrientValue],
        additionalNutrients: [ParsedAdditionalNutrient] = [],
        nutrientDisplayNames: [String: String] = [:],
        valuesNeedingReview: [String: ParsedValueReview],
        panelKind: NutritionPanelKind = .nutritionFacts
    ) {
        var complete = nutrients
        for key in NutritionFactKey.allCases where complete[key.rawValue] == nil {
            complete[key.rawValue] = .unknown
        }
        self.servingSize = servingSize
        self.servingsPerContainer = servingsPerContainer
        self.nutrients = complete
        self.additionalNutrients = additionalNutrients
        self.nutrientDisplayNames = nutrientDisplayNames
        self.valuesNeedingReview = valuesNeedingReview
        self.panelKind = panelKind
    }

    /// Whether the capture read a Supplement Facts panel rather than a Nutrition Facts one.
    public var isSupplementPanel: Bool { panelKind == .supplementFacts }

    public func value(for key: NutritionFactKey) -> NutrientValue {
        nutrients[key.rawValue] ?? .unknown
    }

    /// The name the panel printed for a nutrient when it states its chemical form with it, such as
    /// `Calcium Citrate` for calcium, or nil when the panel named the nutrient plainly.
    public func displayName(for key: NutritionFactKey) -> String? {
        nutrientDisplayNames[key.rawValue]
    }

    /// The compound the panel printed under `key`, or nil when it stated no such row.
    public func additionalNutrient(for key: String) -> ParsedAdditionalNutrient? {
        additionalNutrients.first { $0.key == key }
    }

    /// Whether the value was read with less than full confidence, so the confirmation screen highlights it.
    public func needsReview(_ key: NutritionFactKey) -> Bool {
        valuesNeedingReview[key.rawValue] != nil
    }

    /// The keys to highlight, in panel order.
    public var reviewKeys: [NutritionFactKey] {
        NutritionFactKey.allCases.filter { needsReview($0) }
    }

    public var reviewCount: Int {
        valuesNeedingReview.count
    }

    /// True when the panel stated no amount at all, so there is nothing to show for confirmation.
    /// A panel whose only amounts are compounds it names itself still stated amounts, so a supplement
    /// panel is not written off as unreadable.
    public var isUnreadable: Bool {
        nutrients.values.allSatisfy { $0 == .unknown } && additionalNutrients.isEmpty
    }
}
