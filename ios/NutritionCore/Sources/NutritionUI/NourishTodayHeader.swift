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

    /// Calories remaining in large type, with food and burned beneath, as MyFitnessPal lays them out. It replaces
    /// the goal ring whenever food is known, so a day without a goal shows food and burned only.
    /// Remaining is hidden without a goal; burned is hidden when there is no Health reading or the setting is off.
    /// A partly known day reuses the existing partial note; Remaining is then an upper bound.
    private var calorieSummary: some View {
        let calories = model.calorieRemaining
        let spoken = [
            calories.remaining.map { "\(BodyActivityViewModel.whole($0)) calories remaining" },
            calories.food.map { "\(BodyActivityViewModel.whole($0)) calories food" },
            calories.burned.map { "\(BodyActivityViewModel.whole($0)) calories burned" },
            calories.isPartial ? partialNote(Self.ringKey) : nil,
            ringFootnote,
        ].compactMap { $0 }.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: DesignSpacing.s) {
            if let remaining = calories.remaining {
                Text(BodyActivityViewModel.whole(remaining))
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
                if let food = calories.food {
                    Label {
                        Text("\(BodyActivityViewModel.whole(food)) Food")
                    } icon: {
                        Image(systemName: "fork.knife").accessibilityHidden(true)
                    }
                    .font(.subheadline)
                    .foregroundStyle(TokenColors.textPrimary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(BodyActivityViewModel.whole(food)) calories food")
                }
                if let burned = calories.burned {
                    Label {
                        Text("\(BodyActivityViewModel.whole(burned)) Burned")
                    } icon: {
                        Image(systemName: "flame").accessibilityHidden(true)
                    }
                    .font(.subheadline)
                    .foregroundStyle(TokenColors.textPrimary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(BodyActivityViewModel.whole(burned)) calories burned")
                }
            }
            if calories.isPartial, let note = partialNote(Self.ringKey) {
                Text(note).font(.footnote).foregroundStyle(TokenColors.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l) {
            if model.calorieRemaining.food != nil {
                calorieSummary
            } else if let ring = bar(Self.ringKey) {
                CalorieRing(
                    fraction: fraction(ring), figure: figure(Self.ringKey), caption: "logged",
                    footnote: [partialNote(Self.ringKey), ringFootnote].compactMap { $0 }.joined(separator: " "),
                    spoken: ring.accessibilityText)
            }
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
                    .accessibilityHint("Opens the daily goals")
            }
        }
    }
}
