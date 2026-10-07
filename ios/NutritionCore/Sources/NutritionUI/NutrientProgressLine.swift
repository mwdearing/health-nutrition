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

    public var id: String { nutrient }

    public init(nutrient: String, amount: NutrientValue, goal: NutrientGoal?) {
        self.nutrient = nutrient
        self.label = NutrientNames.displayName(for: nutrient)
        self.amount = amount
        self.goal = goal
    }

    public static func make(
        nutrient: String, total: NutrientTotal?, goal: NutrientGoal?
    ) -> NutrientProgressLine {
        NutrientProgressLine(
            nutrient: nutrient, amount: total?.value ?? .unknown, goal: goal)
    }

    /// True where a target is set, so a caller can tell a comparison from a plain total.
    public var hasGoal: Bool { goal != nil }

    /// False where the day cannot be stated for this nutrient. Unknown is not zero, and a line that
    /// printed a number here would be reporting something the app does not know.
    public var hasKnownAmount: Bool {
        if case .known = amount { return true }
        return false
    }

    public var text: String {
        switch amount {
        case .known(let value, let unit):
            let figure = "\(NutrientNames.displayName(for: nutrient)) "
                + "\(DecimalFormatting.text(value)) \(unit.symbol)"
            guard let goal else { return figure }
            return "\(figure) of \(DecimalFormatting.text(goal.target)) \(goal.unit.symbol)"
        case .unknown, .notApplicable, .belowReportingThreshold:
            return "\(NutrientNames.displayName(for: nutrient)) unknown"
        }
    }
}

/// The name a nutrient key is shown under.
///
/// A key the app does not name is spelled out rather than dropped, because a target a person set
/// for it still has to be recognisable on the screen they set it from.
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
}
