import NutritionDomain
import NutritionJournal
import SwiftUI

/// The top of Today in the Nourish look: the calorie ring, the three macro columns, and a bar for every
/// other goal the person tracks.
///
/// It reads the same lines the plain goals card read, so a goal switched off on the Goals screen stays off.
/// Nothing here is a sample value: a nutrient with no known total shows a dash and an empty bar.
public struct NourishTodayHeader: View {
    @ObservedObject var model: TodayViewModel
    private let onEditGoals: (() -> Void)?

    private static let macroKeys = ["protein", "carbohydrate", "fat"]
    private static let ringKey = "energy"

    public init(model: TodayViewModel, onEditGoals: (() -> Void)? = nil) {
        self.model = model
        self.onEditGoals = onEditGoals
    }

    /// The bar Today already publishes for a nutrient. Reading it, not the raw progress line, keeps a goal
    /// switched off on the Goals screen hidden, and its fraction already accounts for a goal stored in a
    /// different unit from the day's total.
    private func bar(_ key: String) -> GoalBarModel? {
        model.goalBars.first { $0.id == key }
    }

    private func figure(_ key: String) -> String {
        Self.figure(for: model.progress.first(where: { $0.nutrient == key }))
    }

    /// The figure under a macro column or inside the ring: the day's total, rounded for reading, or a dash
    /// where the day has no known total.
    static func figure(for line: NutrientProgressLine?) -> String {
        guard let line, case .known(let value, let unit) = line.shownAmount else { return "—" }
        return AmountDisplay.nutrient(value, unit: unit).text
    }

    static func ringFootnote(for goal: NutrientGoal?) -> String? {
        guard let goal else { return nil }
        return "of \(AmountDisplay.nutrient(goal.target, unit: goal.unit).text) goal"
    }

    private func fraction(_ bar: GoalBarModel?) -> Double {
        guard let value = bar?.fraction else { return 0 }
        return NourishGauge.clamped(NSDecimalNumber(decimal: value).doubleValue)
    }

    private var ringFootnote: String? {
        Self.ringFootnote(for: model.progress.first(where: { $0.nutrient == Self.ringKey })?.goal)
    }

    private var otherBars: [GoalBarModel] {
        let shown = Set(Self.macroKeys + [Self.ringKey])
        return model.goalBars.filter { !shown.contains($0.id) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l) {
            if let ring = bar(Self.ringKey) {
                CalorieRing(
                    fraction: fraction(ring), figure: figure(Self.ringKey), caption: "logged",
                    footnote: ring.reason ?? ringFootnote, spoken: ring.accessibilityText)
            }
            let macros = Self.macroKeys.compactMap { key in bar(key).map { (key, $0) } }
            if !macros.isEmpty {
                HStack(alignment: .top, spacing: DesignSpacing.m) {
                    ForEach(macros, id: \.0) { key, macro in
                        MacroColumn(
                            label: macro.label, figure: figure(key), fraction: fraction(macro),
                            spoken: macro.accessibilityText, note: macro.reason)
                    }
                }
            }
            if !otherBars.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: DesignSpacing.m) {
                        ForEach(otherBars) { GoalBar($0) }
                    }
                }
            }
            if let onEditGoals {
                Button("Edit goals") { onEditGoals() }
                    .font(.subheadline)
                    .foregroundStyle(TokenColors.accent)
                    .accessibilityHint("Opens the daily goals")
            }
        }
    }
}
