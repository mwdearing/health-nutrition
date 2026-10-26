import Foundation
import NutritionDomain
import NutritionJournal
import SwiftUI

/// What a goal bar is saying about one nutrient.
///
/// The day's value alone cannot tell these apart: an empty day and a day with an unreadable entry are
/// both `.unknown`, so the state is decided by the caller from what the day holds.
public enum GoalBarState: Equatable, Sendable {
    case progress, overGoal, noGoal, cannotTotal, nothingLogged
}

/// One goal bar as plain data: the label, the figure, the state, the fraction to draw and the words a
/// screen reader gets. The view renders this and decides nothing.
///
/// Fractions stay `Decimal`. The one conversion to a drawing `Double` is `GoalBar.drawingWidth`.
public struct GoalBarModel: Equatable, Identifiable {
    public let id: String
    public let label: String
    /// The figure beside the label: "52 g of 60 g", "1150 mg", "Can't total yet", "Nothing logged yet".
    public let valueText: String
    public let state: GoalBarState
    /// How full the bar is, 0 through 1. Nil whenever there is nothing honest to draw: no goal, a day
    /// that cannot be totaled, or nothing logged. Unknown is never a fraction.
    public let fraction: Decimal?
    /// Over goal only: where the goal falls along the full bar, goal divided by total.
    public let goalMarker: Decimal?
    public let accessibilityText: String
    /// The one line that explains a state that needs explaining, or nil.
    public let reason: String?

    public init(
        id: String, label: String, valueText: String, state: GoalBarState, fraction: Decimal?,
        goalMarker: Decimal?, accessibilityText: String, reason: String?
    ) {
        self.id = id
        self.label = label
        self.valueText = valueText
        self.state = state
        self.fraction = fraction
        self.goalMarker = goalMarker
        self.accessibilityText = accessibilityText
        self.reason = reason
    }

    /// Builds the bar for one progress line.
    ///
    /// - Parameters:
    ///   - hasEntries: whether any entry of the day could contribute to this nutrient. Without one the
    ///     bar says nothing is logged, which is not the same as a total of zero.
    ///   - missingCount: how many entries `CoverageLine` reports as lacking this nutrient. Zero gives
    ///     the generic reason, because a gap the coverage model does not report is not claimed.
    ///   - skippedWaterCount: for water, the entries left out for not being a volume.
    public static func make(
        line: NutrientProgressLine, hasEntries: Bool, missingCount: Int, skippedWaterCount: Int = 0,
        someKnown: Bool = false, unitSystem: UnitSystem = .metric
    ) -> GoalBarModel {
        let label = line.label
        let isWater = line.nutrient == DailyTotalsBuilder.waterKey
        // Words only: the state, the fraction and the goal marker below are decided on the exact total.
        func shown(_ amount: Decimal, _ unit: MeasureUnit) -> DisplayAmount {
            isWater ? AmountDisplay.water(amount, unit: unit, system: unitSystem)
                : AmountDisplay.nutrient(amount, unit: unit)
        }
        func spokenDisplay(_ amount: DisplayAmount) -> String {
            "\(amount.spokenAmount) \(AmountDisplay.spokenName(for: amount.unit))"
        }
        guard hasEntries else {
            var spoken = "\(label), nothing logged yet"
            if let goal = line.goal {
                let displayGoal = shown(goal.target, goal.unit)
                spoken += ", goal \(spokenDisplay(displayGoal))"
            }
            return GoalBarModel(
                id: line.id, label: label, valueText: "Nothing logged yet", state: .nothingLogged,
                fraction: nil, goalMarker: nil, accessibilityText: spoken, reason: nil)
        }
        guard case .known(let total, let unit) = line.shownAmount else {
            let reason = reasonText(line: line, missingCount: missingCount, skippedWaterCount: skippedWaterCount)
            // "No data" only when nothing is known. Otherwise the figure is the existing "Can't total yet" and the
            // reason sits once, in the footnote, which says which entries lack a value.
            let figure = someKnown ? "Can't total yet" : "No data"
            return GoalBarModel(
                id: line.id, label: label, valueText: figure, state: .cannotTotal,
                fraction: nil, goalMarker: nil,
                accessibilityText: someKnown ? "\(label), \(reason)" : "\(label), no data, \(reason)", reason: reason)
        }
        let displayTotal = shown(total, unit)
        let figure = displayTotal.text
        let spokenFigure = spokenDisplay(displayTotal)
        // A partial day shows its known sum with the same note the unknown case uses, so the reader sees why.
        let note: String? = line.isPartial
            ? reasonText(line: line, missingCount: missingCount, skippedWaterCount: skippedWaterCount) : nil
        guard let goal = line.goal else {
            return GoalBarModel(
                id: line.id, label: label, valueText: figure, state: .noGoal, fraction: nil,
                goalMarker: nil, accessibilityText: note.map { "\(label), \(spokenFigure), \($0)" } ?? "\(label), \(spokenFigure)",
                reason: note)
        }
        let displayGoal = shown(goal.target, goal.unit)
        let valueText = "\(figure) of \(displayGoal.text)"
        let spoken = "\(label), \(spokenFigure) of \(spokenDisplay(displayGoal))"
        // On a partial day the spoken text says so too, so a screen reader does not hear a short day.
        let spokenPartial = note.map { "\(spoken), \($0)" } ?? spoken
        // The comparison is made in the unit the total is stated in, so a target set in another metric
        // unit is compared exactly while still being shown as it was set.
        let comparable: Decimal?
        if goal.unit == unit {
            comparable = goal.target
        } else {
            comparable = (try? Quantity(value: goal.target, unit: goal.unit).converted(to: unit))?.value
        }
        guard let target = comparable, target > 0 else {
            return GoalBarModel(
                id: line.id, label: label, valueText: valueText, state: .progress, fraction: nil,
                goalMarker: nil, accessibilityText: spokenPartial, reason: note)
        }
        if total > target {
            return GoalBarModel(
                id: line.id, label: label, valueText: valueText, state: .overGoal, fraction: 1,
                goalMarker: target / total, accessibilityText: spokenPartial + ", over goal", reason: note)
        }
        let fraction = total < 0 ? Decimal(0) : total / target
        return GoalBarModel(
            id: line.id, label: label, valueText: valueText, state: .progress, fraction: fraction,
            goalMarker: nil, accessibilityText: spokenPartial, reason: note)
    }

    /// The nutrient's name inside a sentence: lower case, except a name that is all capitals.
    private static func inSentence(_ label: String) -> String {
        MissingValueWording.inSentence(label)
    }

    private static func reasonText(
        line: NutrientProgressLine, missingCount: Int, skippedWaterCount: Int
    ) -> String {
        let name = inSentence(line.label)
        if line.nutrient == DailyTotalsBuilder.waterKey {
            if skippedWaterCount > 0 {
                return "\(skippedWaterCount) water entries have a unit that is not a volume and are not counted."
            }
            return MissingValueWording.fallback(name: name)
        }
        return MissingValueWording.partialNote(name: name, healthGap: line.healthGap, count: missingCount)
    }

}

/// A labeled bar: the nutrient and its figure above a capsule track. One accessibility element, so
/// the bar is never read as a separate unlabeled control and is never color alone.
public struct GoalBar: View {
    private let model: GoalBarModel

    public init(_ model: GoalBarModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.label)
                    .font(.subheadline)
                    .foregroundStyle(TokenColors.textPrimary)
                Spacer(minLength: DesignSpacing.s)
                Text(model.valueText)
                    .font(.subheadline)
                    .foregroundStyle(valueColor)
                    .multilineTextAlignment(.trailing)
            }
            // A nutrient with no goal keeps its empty track, so every row lines up with the goal rows.
            track
            if let reason = model.reason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityText)
    }

    private var valueColor: Color {
        switch model.state {
        case .cannotTotal, .nothingLogged: return TokenColors.textSecondary
        case .progress, .overGoal, .noGoal: return TokenColors.textPrimary
        }
    }

    private var track: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(TokenColors.track)
                if model.state == .cannotTotal {
                    HatchLines()
                        .stroke(TokenColors.textSecondary, lineWidth: 1)
                        .clipShape(Capsule())
                }
                if let fraction = model.fraction {
                    Capsule()
                        .fill(TokenColors.accent)
                        .frame(width: Self.drawingWidth(of: fraction, in: proxy.size.width))
                }
                if let marker = model.goalMarker {
                    Rectangle()
                        .fill(TokenColors.textPrimary)
                        .frame(width: 2)
                        .offset(x: Self.drawingWidth(of: marker, in: proxy.size.width) - 1)
                }
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    /// The one place a `Decimal` fraction becomes a `Double`, because a bar's width has to be a number
    /// the drawing system can take. Every model keeps its fractions exact.
    static func drawingWidth(of fraction: Decimal, in available: CGFloat) -> CGFloat {
        let clamped = min(max(fraction, 0), 1)
        return available * CGFloat(NSDecimalNumber(decimal: clamped).doubleValue)
    }
}

/// Diagonal lines across a rectangle: the look of a track that cannot be filled.
struct HatchLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = CGFloat(0)
        while x < rect.width + rect.height {
            path.move(to: CGPoint(x: x, y: rect.height))
            path.addLine(to: CGPoint(x: x - rect.height, y: 0))
            x += 6
        }
        return path
    }
}

/// The one source for the missing-value wording shared by the goal rows and the calorie summary: the name in a
/// sentence, the count note, and the fallback for a partial line with no missing entry.
enum MissingValueWording {
    /// Lower case unless the label is all capitals, so a name reads the same wherever it sits in a sentence.
    static func inSentence(_ label: String) -> String {
        label == label.uppercased() ? label : label.lowercased()
    }

    /// "1 entry has no energy value" and "2 entries have no energy value"; the fallback when no entry is missing.
    static func note(count: Int, name: String) -> String {
        if count == 1 { return "1 entry has no \(name) value" }
        if count > 1 { return "\(count) entries have no \(name) value" }
        return fallback(name: name)
    }

    /// The wording for a partial line with no missing entry (a below-threshold amount).
    static func fallback(name: String) -> String {
        "Some entries can't be added up for \(name)"
    }

    /// The note for a partial line whose journal side is complete and whose Health side is short.
    static func healthGapNote(name: String) -> String {
        "Some data from the Health app can't be counted for \(name)"
    }

    /// The note a partial line shows: the Health note when only Health is short, otherwise the count note or fallback.
    static func partialNote(name: String, healthGap: Bool, count: Int) -> String {
        healthGap ? healthGapNote(name: name) : note(count: count, name: name)
    }
}
