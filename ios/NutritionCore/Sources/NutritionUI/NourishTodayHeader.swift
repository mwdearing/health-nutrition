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

    /// The missing-value note, shown only on a partial day. A whole day's unknown keeps its own figure and no note.
    private func partialNote(_ key: String) -> String? {
        guard model.progress.first(where: { $0.nutrient == key })?.isPartial == true else { return nil }
        return bar(key)?.reason
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

    /// The one spoken line for the summary: remaining, food and burned as labels, then the partial note and the goal footnote.
    static func spokenSummary(_ calories: CalorieRemaining, partial: String?, footnote: String?) -> String {
        [
            calories.remaining.map { "\(BodyActivityViewModel.whole($0)) calories remaining" },
            calories.food.map { "Food, \(BodyActivityViewModel.whole($0)) calories" },
            calories.burned.map { "Burned, \(BodyActivityViewModel.whole($0)) calories" },
            partial,
            footnote,
        ].compactMap { $0 }.joined(separator: ", ")
    }

    /// The figures the calorie summary shows. Food is a dash until something is logged, never 0. Remaining is hidden
    /// without a goal and a dash with one but no known food. Burned is hidden unless the model has a Health figure.
    struct SummaryFigures: Equatable {
        let remaining: String?
        let food: String
        let burned: String?
    }

    static func summaryFigures(_ calories: CalorieRemaining) -> SummaryFigures {
        let remaining: String?
        if let value = calories.remaining {
            remaining = BodyActivityViewModel.whole(value)
        } else if calories.goal != nil {
            remaining = "—"
        } else {
            remaining = nil
        }
        return SummaryFigures(
            remaining: remaining,
            food: calories.food.map { BodyActivityViewModel.whole($0) } ?? "—",
            burned: calories.burned.map { BodyActivityViewModel.whole($0) })
    }

    /// Calories remaining in large type, with food and burned beneath, as MyFitnessPal lays them out. It is the
    /// top block on Today every day. A day without a goal shows food and burned only.
    /// Remaining is hidden without a goal; burned is hidden when there is no Health reading or the setting is off.
    /// A partly known day reuses the existing partial note; Remaining is then an upper bound.
    private var calorieSummary: some View {
        let calories = model.calorieRemaining
        let figures = Self.summaryFigures(calories)
        // The note comes from the calorie model, which builds it from the same missing count as its partial flag.
        let partial = calories.partialNote
        let spoken = Self.spokenSummary(calories, partial: partial, footnote: calories.showsRemaining ? ringFootnote : nil)
        return VStack(alignment: .leading, spacing: DesignSpacing.s) {
            if let remaining = figures.remaining {
                Text(remaining)
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(TokenColors.textPrimary)
                Text("Calories remaining")
                    .font(.subheadline)
                    .foregroundStyle(TokenColors.textSecondary)
                if let ringFootnote {
                    Text(ringFootnote).font(.footnote).foregroundStyle(TokenColors.textSecondary)
                }
            }
            HStack(alignment: .top, spacing: DesignSpacing.l) {
                Label {
                    Text("\(figures.food) Food")
                } icon: {
                    Image(systemName: "fork.knife").accessibilityHidden(true)
                }
                .font(.subheadline)
                .foregroundStyle(TokenColors.textPrimary)
                .accessibilityElement(children: .combine)
                if let burned = figures.burned {
                    Label {
                        Text("\(burned) Burned")
                    } icon: {
                        Image(systemName: "flame").accessibilityHidden(true)
                    }
                    .font(.subheadline)
                    .foregroundStyle(TokenColors.textPrimary)
                    .accessibilityElement(children: .combine)
                }
            }
            if let note = partial {
                Text(note).font(.footnote).foregroundStyle(TokenColors.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l) {
            calorieSummary
            let macros = Self.macroKeys.compactMap { key in bar(key).map { (key, $0) } }
            if !macros.isEmpty {
                HStack(alignment: .top, spacing: DesignSpacing.m) {
                    ForEach(macros, id: \.0) { key, macro in
                        MacroColumn(
                            label: macro.label, figure: figure(key), fraction: fraction(macro),
                            spoken: macro.accessibilityText, note: partialNote(key))
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
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityHint("Opens the daily goals")
            }
        }
    }
}
