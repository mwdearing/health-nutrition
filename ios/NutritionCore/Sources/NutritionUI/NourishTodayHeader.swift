import NutritionDomain
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

    private func line(_ key: String) -> NutrientProgressLine? {
        model.progress.first { $0.nutrient == key }
    }

    private static func total(of line: NutrientProgressLine?) -> Decimal? {
        guard let line, case .known(let value, _) = line.amount else { return nil }
        return value
    }

    private static func fraction(of line: NutrientProgressLine?) -> Double {
        guard let value = total(of: line), let goal = line?.goal else { return 0 }
        return NourishGauge.fraction(
            value: NSDecimalNumber(decimal: value).doubleValue,
            goal: NSDecimalNumber(decimal: goal.target).doubleValue)
    }

    private static func figure(of line: NutrientProgressLine?) -> String {
        guard let value = total(of: line), case .known(_, let unit)? = line?.amount else { return "—" }
        return "\(DecimalFormatting.text(value)) \(unit.symbol)"
    }

    private var ringLine: NutrientProgressLine? { line(Self.ringKey) }

    private var ringFootnote: String? {
        guard let goal = ringLine?.goal else { return nil }
        return "of \(DecimalFormatting.text(goal.target)) \(goal.unit.symbol) goal"
    }

    private var otherBars: [GoalBarModel] {
        let shown = Set(Self.macroKeys + [Self.ringKey])
        return model.goalBars.filter { !shown.contains($0.id) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l) {
            CalorieRing(
                fraction: Self.fraction(of: ringLine),
                figure: Self.total(of: ringLine).map { DecimalFormatting.text($0) } ?? "—",
                caption: "kcal logged", footnote: ringFootnote)
            HStack(alignment: .top, spacing: DesignSpacing.m) {
                ForEach(Self.macroKeys, id: \.self) { key in
                    MacroColumn(
                        label: NutrientNames.displayName(for: key), figure: Self.figure(of: line(key)),
                        fraction: Self.fraction(of: line(key)))
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
