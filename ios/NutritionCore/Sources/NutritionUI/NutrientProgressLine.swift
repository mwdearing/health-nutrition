import Foundation
import NutritionDomain
import NutritionJournal

/// One tracked nutrient on Today: what the day has reached, against a target where one is set.
///
/// The line is plain text because that is what the screen shows and what a test asserts:
///
/// | the day | a goal | the line reads |
/// |---|---|---|
/// | 42 g of protein | 60 g | `Protein 42 g of 60 g` |
/// | 42 g of protein | none | `Protein 42 g` |
/// | unknown | 60 g | `Protein unknown` |
///
/// A day above its target still shows the real figure rather than capping at the target, and a
/// target in another metric unit is shown as it was set rather than silently converted, so the
/// comparison on screen is the one that was entered.
public struct NutrientProgressLine: Equatable, Identifiable {
    public let nutrient: String
    /// The display name, from `NutrientNames`.
    public let label: String
    /// The day's total for this nutrient.
    public let amount: NutrientValue
    /// The target, nil where none is set for this nutrient.
    public let goal: NutrientGoal?
    /// True when some entries of the day have no value. `amount` stays the whole-day value, which is unknown then.
    public let isPartial: Bool
    /// The sum of the known entries, set only when `isPartial`. Readers that show a partial day read this.
    public let knownSum: NutrientValue?

    public var id: String { nutrient }

    public init(
        nutrient: String, amount: NutrientValue, goal: NutrientGoal?, displayName: String? = nil,
        isPartial: Bool = false, knownSum: NutrientValue? = nil
    ) {
        self.nutrient = nutrient
        self.label = displayName ?? NutrientNames.displayName(for: nutrient)
        self.amount = amount
        self.goal = goal
        self.isPartial = isPartial
        self.knownSum = knownSum
    }

    /// The amount a partial-aware screen shows: the known sum on a partial day, otherwise `amount`.
    public var shownAmount: NutrientValue {
        isPartial ? (knownSum ?? amount) : amount
    }

    /// `knownSum` is the day's known partial sum. It is used only when the total is unknown because some entries
    /// have no value. Then `amount` stays unknown, `isPartial` is true and `knownSum` carries the known part.
    public static func make(
        nutrient: String, total: NutrientTotal?, goal: NutrientGoal?, displayName: String? = nil,
        knownSum: NutrientValue? = nil
    ) -> NutrientProgressLine {
        if let knownSum, total?.coverage.hasUnknown == true {
            return NutrientProgressLine(
                nutrient: nutrient, amount: total?.value ?? .unknown, goal: goal, displayName: displayName,
                isPartial: true, knownSum: knownSum)
        }
        return NutrientProgressLine(
            nutrient: nutrient, amount: total?.value ?? .unknown, goal: goal, displayName: displayName)
    }

    /// True where a target is set, so a caller can tell a comparison from a plain total.
    public var hasGoal: Bool { goal != nil }

    /// False where the day cannot be stated for this nutrient. Unknown is not zero, and a line that
    /// printed a number here would be reporting something the app does not know.
    public var hasKnownAmount: Bool {
        if case .known = shownAmount { return true }
        return false
    }

    public var text: String {
        switch amount {
        case .known(let value, let unit):
            let figure = "\(label) "
                + AmountDisplay.nutrient(value, unit: unit).text
            guard let goal else { return figure }
            return "\(figure) of \(AmountDisplay.nutrient(goal.target, unit: goal.unit).text)"
        case .unknown, .notApplicable, .belowReportingThreshold:
            return "\(label) unknown"
        }
    }
}

/// The name a nutrient key is shown under.
///
/// A key the app does not name is spelled out rather than dropped, because a target a person set
/// for it still has to be recognizable on the screen they set it from.
public enum NutrientNames {
    private static let names = [
        "energy": "Energy",
        "protein": "Protein",
        "carbohydrate": "Carbohydrate",
        "fiber": "Fiber",
        "fat": "Fat",
        "sugar": "Sugar",
        "sodium": "Sodium",
        "potassium": "Potassium",
        "calcium": "Calcium",
        "iron": "Iron",
        "zinc": "Zinc",
        "water": "Water",
        "vitaminA": "Vitamin A",
        "vitaminB6": "Vitamin B6",
        "vitaminB12": "Vitamin B12",
        "vitaminC": "Vitamin C",
        "vitaminD": "Vitamin D",
        "vitaminE": "Vitamin E",
        "vitaminK": "Vitamin K",
        "thiamin": "Thiamin (B1)",
        "riboflavin": "Riboflavin (B2)",
        "niacin": "Niacin (B3)",
        "folate": "Folate",
        "biotin": "Biotin",
        "pantothenicAcid": "Pantothenic acid (B5)",
        "magnesium": "Magnesium",
        "phosphorus": "Phosphorus",
        "chloride": "Chloride",
        "chromium": "Chromium",
        "copper": "Copper",
        "iodine": "Iodine",
        "manganese": "Manganese",
        "molybdenum": "Molybdenum",
        "selenium": "Selenium",
        "caffeine": "Caffeine",
    ]

    public static func displayName(for nutrient: String) -> String {
        if let name = names[nutrient] { return name }
        guard !nutrient.isEmpty else { return nutrient }
        // A compound key is a slug of the printed name (`creatine-monohydrate`), so it is spelled back
        // out rather than shown with its hyphens and one capital.
        return nutrient.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// The name a nutrient key is shown under, preferring the words the label printed for it when the
    /// snapshots this screen read carry them. A key with no printed name falls back to the name it
    /// spells out.
    public static func displayName(for nutrient: String, displayNames: [String: String]) -> String {
        displayNames[nutrient] ?? displayName(for: nutrient)
    }
}
