import Foundation
import NutritionDomain
import NutritionJournal

/// The nutrient keys the Goals screen offers, with the unit each is counted in.
///
/// A fixed list rather than whatever the catalog happens to hold, because a target a person cannot
/// choose is a target they cannot correct. Every key is one the journal already uses, so a goal set
/// here compares against the same totals Today shows.
public enum NutrientGoalChoices {
    /// Keys in the order the screen lists them.
    public static let keys = [
        "energy", "protein", "carbohydrate", "fiber", "fat", "sodium", "potassium", "water",
    ]

    /// The unit a key is counted in, which is where its total is read. Water is a volume; every
    /// other key here is a mass or an energy, matching what the catalog states for it.
    public static func unit(forKey key: String) -> MeasureUnit {
        key == DailyTotals.waterKey ? DailyTotals.waterUnit : .g
    }

    /// Every unit a key may be counted in: the registry's mass and energy units for a nutrient, and
    /// the registry's volume units for water. No other unit is offered, so a target cannot be set
    /// in something the totals are not counted in.
    public static func units(forKey key: String) -> [MeasureUnit] {
        guard key == DailyTotals.waterKey else {
            return UnitRegistry.all.filter { $0.dimension == .mass || $0.dimension == .energy }
        }
        return UnitRegistry.all.filter { $0.dimension == .volume }
    }
}

/// One row on the Goals screen: a nutrient, what it is targeted at, and whether a target is set.
public struct NutrientGoalRow: Equatable, Identifiable {
    public let nutrient: String
    public let displayName: String
    /// "60 g", or nil where no target is set for this nutrient.
    public let targetText: String?

    public var id: String { nutrient }

    public init(nutrient: String, displayName: String, targetText: String?) {
        self.nutrient = nutrient
        self.displayName = displayName
        self.targetText = targetText
    }

    /// The row for a nutrient with no target, which is still listed so the screen can offer it.
    public static func withoutGoal(_ nutrient: String) -> NutrientGoalRow {
        NutrientGoalRow(
            nutrient: nutrient, displayName: NutrientNames.displayName(for: nutrient), targetText: nil)
    }
}

/// Backs the Goals screen: the targets a person set, and the writes that change them.
///
/// The keys come from `NutrientGoalChoices` rather than from the store, so the screen lists the same
/// nutrients however few targets exist. A read that throws leaves the list empty and says so: an
/// empty screen that looks loaded would invite a person to set a target over one already stored.
@MainActor
public final class GoalsViewModel: ObservableObject {
    @Published public private(set) var rows: [NutrientGoalRow] = []
    @Published public private(set) var errorMessage: String?

    public static let readFailedMessage = "Could not read the daily goals."
    public static let saveFailedMessage = "Could not save that daily goal."
    public static let removeFailedMessage = "Could not remove that daily goal."

    private let store: GoalStore

    public init(store: GoalStore) {
        self.store = store
    }

    /// Every offered nutrient, with a target's text where one is stored.
    public func load() {
        do {
            let stored = try store.goals()
            let byNutrient = Dictionary(stored.map { ($0.nutrient, $0) }, uniquingKeysWith: { _, last in last })
            rows = NutrientGoalChoices.keys.map { key in
                guard let goal = byNutrient[key] else { return .withoutGoal(key) }
                return NutrientGoalRow(
                    nutrient: key, displayName: NutrientNames.displayName(for: key),
                    targetText: "\(DecimalFormatting.text(goal.target)) \(goal.unit.symbol)")
            }
            errorMessage = nil
        } catch {
            rows = []
            errorMessage = Self.readFailedMessage
        }
    }

    /// Stores `target` for `nutrient`, replacing any target already set for it.
    ///
    /// Returns whether it was written. Invalid text is refused rather than rounded or guessed at, and
    /// leaves whatever was stored before untouched.
    @discardableResult
    public func setTarget(_ targetText: String, for nutrient: String, unit: MeasureUnit? = nil) -> Bool {
        let chosen = unit ?? NutrientGoalChoices.unit(forKey: nutrient)
        guard let target = AmountParser.parse(targetText) else {
            errorMessage = "Enter a target above zero."
            return false
        }
        do {
            try store.setGoal(NutrientGoal(nutrient: nutrient, target: target, unit: chosen))
            load()
            return true
        } catch {
            errorMessage = Self.saveFailedMessage
            return false
        }
    }

    /// Removes the target for `nutrient`, so the nutrient falls back to a plain total.
    @discardableResult
    public func removeTarget(for nutrient: String) -> Bool {
        do {
            try store.removeGoal(nutrient: nutrient)
            load()
            return true
        } catch {
            errorMessage = Self.removeFailedMessage
            return false
        }
    }
}
