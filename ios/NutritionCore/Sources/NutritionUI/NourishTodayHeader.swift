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

    /// The figure under a macro column or inside the ring: the day's total, rounded for reading, or a dash
    /// where the day has no known total.
    static func figure(for line: NutrientProgressLine?) -> String {
        guard let line, case .known(let value, let unit) = line.shownAmount else { return "—" }
        return AmountDisplay.nutrient(value, unit: unit).text
    }

    /// The figure under a macro column: the day's total, then "of" the macro goal when one is set, the same
    /// shape the Fiber line uses ("15 g of 32 g"). With no goal it is the total alone; with no known total it is a dash.
    static func macroFigure(for line: NutrientProgressLine?) -> String {
        guard let line, case .known = line.shownAmount, let goal = line.goal else { return figure(for: line) }
        return "\(figure(for: line)) of \(AmountDisplay.nutrient(goal.target, unit: goal.unit).text)"
    }

    static func ringFootnote(for goal: NutrientGoal?) -> String? {
        guard let goal else { return nil }
        // The goal is a whole amount, grouped the way the remaining figure is ("2,357"), so the footnote and the
        // figure agree.
        let target = AmountDisplay.nutrient(goal.target, unit: goal.unit)
        let grouped = DisplayAmount(amount: target.amount, unit: goal.unit, groupsWholeAmount: true)
        return "of \(grouped.text) goal"
    }

    private var ringFootnote: String? {
        Self.ringFootnote(for: model.progress.first(where: { $0.nutrient == Self.ringKey })?.goal)
    }

    private var otherBars: [GoalBarModel] {
        model.nutrientCard
    }

    /// The goal footnote the summary reads out: only while Remaining shows, because without a goal there is no
    /// Remaining for "of N goal" to qualify.
    static func summaryFootnote(_ calories: CalorieRemaining, ringFootnote: String?) -> String? {
        calories.showsRemaining ? ringFootnote : nil
    }

    /// The caption under the remaining figure: over the goal it says so, and the figure beside it is how far over.
    static func remainingCaption(_ calories: CalorieRemaining) -> String {
        (calories.remaining ?? 0) < 0 ? "Calories over goal" : "Calories remaining"
    }

    /// The one spoken line for the summary: remaining (or how far over), or why there is no total, then food and
    /// burned as labels, the partial note and the goal footnote.
    static func spokenSummary(
        _ calories: CalorieRemaining, partial: String?, footnote: String?, uncountedEntries: Int = 0
    ) -> String {
        let lead: String?
        if let remaining = calories.remaining {
            lead = remaining < 0
                ? "\(BodyActivityViewModel.whole(-remaining)) calories over goal"
                : "\(BodyActivityViewModel.whole(remaining)) calories remaining"
        } else if calories.food == nil {
            lead = uncountedEntries > 0 ? "Calories can't total yet" : "Nothing logged yet"
        } else {
            lead = nil
        }
        return [
            lead,
            calories.food.map { "Food, \(BodyActivityViewModel.whole($0)) calories" },
            calories.burned.map { "Burned, \(BodyActivityViewModel.whole($0)) calories" },
            partial,
            footnote,
        ].compactMap { $0 }.joined(separator: ", ")
    }

    /// The prompt shown in place of Calories remaining while no energy goal is stored. Nil once a goal exists,
    /// and nil unless the last load read the goals and found no calorie goal: a failed goal read or a day that
    /// has not loaded yet is not a person without a goal.
    static func goalPrompt(_ calories: CalorieRemaining, goalKnownAbsent: Bool) -> String? {
        calories.goal == nil && goalKnownAbsent ? "Set a calorie goal to see what's left" : nil
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
            remaining = BodyActivityViewModel.whole(value < 0 ? -value : value)
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

    private var uncountedEntries: Int {
        model.progress.first(where: { $0.nutrient == Self.ringKey })?.missingCount ?? 0
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l) {
            let calories = model.calorieRemaining
            let spoken = Self.spokenSummary(
                calories, partial: calories.partialNote,
                footnote: Self.summaryFootnote(calories, ringFootnote: ringFootnote),
                uncountedEntries: uncountedEntries)
            TodayHero(
                calories: calories,
                ringFootnote: ringFootnote,
                spoken: spoken,
                prompt: Self.goalPrompt(calories, goalKnownAbsent: model.calorieGoalKnownAbsent),
                macros: Self.macroKeys.compactMap { key in
                    bar(key).map { MacroEntry(key: key, bar: $0) }
                },
                onEditGoals: onEditGoals)
            if !otherBars.isEmpty {
                ContentCard {
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

private struct MacroEntry: Identifiable {
    let key: String
    let bar: GoalBarModel
    var id: String { key }
}

/// The branded hero: the calorie ring with the remaining figure, the Food and Burned row, and the three macro bars.
/// Everything on it reads the hero text roles, because the card forces the dark appearance.
private struct TodayHero: View {
    let calories: CalorieRemaining
    let ringFootnote: String?
    let spoken: String
    let prompt: String?
    let macros: [MacroEntry]
    let onEditGoals: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let macroColors: [String: Color] = [
        "protein": TokenColors.macroProtein,
        "carbohydrate": TokenColors.macroCarbs,
        "fat": TokenColors.macroFat,
    ]

    private var stacksVertically: Bool { dynamicTypeSize.isAccessibilitySize }

    private var summary: some View {
        let figures = NourishTodayHeader.summaryFigures(calories)
        let partial = calories.partialNote
        return VStack(alignment: .center, spacing: DesignSpacing.s) {
            if let remaining = figures.remaining {
                CalorieRing(model: CalorieRingModel.make(calories), onHero: true) {
                    VStack(spacing: DesignSpacing.xs) {
                        Text(remaining)
                            .font(.largeTitle.bold())
                            .fontDesign(.rounded)
                            .monospacedDigit()
                            .minimumScaleFactor(0.5)
                            .foregroundStyle(TokenColors.heroText)
                            .accessibilityIdentifier("calorieRemainingFigure")
                        Text(NourishTodayHeader.remainingCaption(calories))
                            .font(.subheadline)
                            .foregroundStyle(TokenColors.heroSecondaryText)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("calorieRemainingLabel")
                    }
                    .padding(.horizontal, DesignSpacing.l)
                }
                if let ringFootnote {
                    Text(ringFootnote).font(.footnote).foregroundStyle(TokenColors.heroSecondaryText)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("calorieGoalLine")
                }
            } else if let prompt, let onEditGoals {
                Button(prompt) { onEditGoals() }
                    .font(.headline)
                    .foregroundStyle(TokenColors.mint)
                    .accessibilityHint("Opens your goals to set a calorie goal")
            }
            foodBurnedRow(figures)
            if let note = partial {
                Text(note).font(.footnote).foregroundStyle(TokenColors.heroSecondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        // The group hides its children from VoiceOver, so the goal prompt is offered as a named action on it.
        .accessibilityActions {
            if let prompt, let onEditGoals {
                Button(prompt) { onEditGoals() }
            }
        }
    }

    @ViewBuilder
    private func foodBurnedRow(_ figures: NourishTodayHeader.SummaryFigures) -> some View {
        let layout = stacksVertically
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DesignSpacing.s))
            : AnyLayout(HStackLayout(alignment: .top, spacing: DesignSpacing.l))
        layout {
            Label {
                Text("\(figures.food) Food")
            } icon: {
                Image(systemName: "fork.knife").accessibilityHidden(true)
            }
            .font(.subheadline)
            .foregroundStyle(TokenColors.heroText)
            .accessibilityElement(children: .combine)
            if let burned = figures.burned {
                Label {
                    Text("\(burned) Burned")
                } icon: {
                    Image(systemName: "flame").accessibilityHidden(true)
                }
                .font(.subheadline)
                .foregroundStyle(TokenColors.heroText)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("calorieFoodBurnedRow")
    }

    private var macroBars: some View {
        let layout = stacksVertically
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DesignSpacing.m))
            : AnyLayout(HStackLayout(alignment: .top, spacing: DesignSpacing.m))
        return layout {
            ForEach(macros) { macro in
                MacroBar(
                    model: macro.bar, color: Self.macroColors[macro.key] ?? TokenColors.mint, onHero: true
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("macroColumn-\(macro.bar.label)")
            }
        }
    }

    var body: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: DesignSpacing.l) {
                summary
                if !macros.isEmpty { macroBars }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("todayHero")
        }
    }
}
