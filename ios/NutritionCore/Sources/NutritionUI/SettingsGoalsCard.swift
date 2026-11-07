import NutritionDomain
import SwiftUI

/// The lines the Settings goals card shows. Plain values, so the wording is unit-tested without a view.
struct SettingsGoalsSummary: Equatable {
    let title = "Daily goals"
    /// "2,000 Calories a day" when an energy goal is set, otherwise the row's earlier wording ("None set", "3 set").
    let energyLine: String
    /// Present only when a weight plan exists, in the person's weight unit.
    let planLine: String?
    /// "Edit goals", or "Set your goals" when nothing is set.
    let capsuleTitle: String

    /// - Parameter energyGoal: the stored daily energy goal; nil or zero means none is set.
    init(energyGoal: Decimal?, energyUnit: MeasureUnit, goalsSetText: String, plan: WeightPlan?, unitSystem: UnitSystem) {
        if let energyGoal, energyGoal > 0 {
            energyLine = energyGoal.formatted(.number.precision(.fractionLength(0))) + " \(energyUnit == .kcal ? "Calories" : energyUnit.symbol) a day"
            capsuleTitle = "Edit goals"
        } else {
            energyLine = goalsSetText
            capsuleTitle = goalsSetText == "None set" ? "Set your goals" : "Edit goals"
        }
        planLine = Self.planLine(plan, unitSystem: unitSystem)
    }

    private static func planLine(_ plan: WeightPlan?, unitSystem: UnitSystem) -> String? {
        guard let plan else { return nil }
        switch plan.aim {
        case .justTrack:
            return nil
        case .maintain:
            return "Keep your weight"
        case .lose, .gain:
            guard let pace = plan.weeklyPaceKilograms else { return nil }
            let us = unitSystem == .usCustomary
            let shown = us ? pace * BodyActivityViewModel.poundsPerKilogram : pace
            let text = BodyActivityViewModel.twoDecimals(shown)
            return (plan.aim == .lose ? "Lose " : "Gain ") + text + (us ? " lb" : " kg") + " a week"
        }
    }
}

/// The Settings hero row: the daily goals at a glance, one button that opens the goals screen.
struct SettingsGoalsCard: View {
    let summary: SettingsGoalsSummary
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: DesignSpacing.m))
                : AnyLayout(HStackLayout(spacing: DesignSpacing.m))
            layout {
                HStack(spacing: DesignSpacing.m) {
                    IconWell(systemName: "target", size: .small)
                    VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                        Text(summary.title).font(.footnote).foregroundStyle(TokenColors.heroSecondaryText)
                        Text(summary.energyLine).font(.headline).foregroundStyle(TokenColors.heroText)
                        if let plan = summary.planLine {
                            Text(plan).font(.footnote).foregroundStyle(TokenColors.heroSecondaryText)
                        }
                    }
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: DesignSpacing.s) }
                Text(summary.capsuleTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TokenColors.hero)
                    .padding(.horizontal, DesignSpacing.m).padding(.vertical, DesignSpacing.xs)
                    .background(TokenColors.mint, in: Capsule())
            }
            .frame(minHeight: 44)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([summary.title, summary.energyLine, summary.planLine].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens your goals")
    }
}
