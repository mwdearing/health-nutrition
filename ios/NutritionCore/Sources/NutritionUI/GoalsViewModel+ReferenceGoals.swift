import NutritionDomain
import NutritionJournal
import SwiftUI

/// A published reference value offered as the goal for a vitamin or mineral row that has none.
public struct ReferenceGoalHint: Equatable {
    public let nutrient: String
    /// The RDA or AI, in `unit`.
    public let amount: Decimal
    public let unit: MeasureUnit
    /// "RDA 8 mg for Men 31 to 50", the words under the row.
    public let text: String
}

/// Reference values as a starting point for vitamin and mineral goals.
///
/// Using one is a one-time copy: it writes the RDA or AI as an ordinary goal, which the person can then
/// change like any other. Nothing links the goal to the table afterwards, so picking another group on the
/// vitamins and minerals screen never rewrites a goal, and nothing new is stored. A row that already has
/// a goal is never offered one, so a number a person set is never overwritten.
extension GoalsViewModel {
    /// The reference value a row may take, or nil when no group is chosen, the key is not in the
    /// reference table (chloride, a captured alias such as `vitamin-a`, a macronutrient), the row is not
    /// offered, or a goal is already set.
    public func referenceGoalHint(for nutrient: String) -> ReferenceGoalHint? {
        guard let group = self.referenceGroup,
            let row = self.rows.first(where: { $0.nutrient == nutrient }), row.targetText == nil,
            let intake = ReferenceIntakes.intake(for: nutrient, group: group),
            intake.unit.dimension == self.unit(for: nutrient).dimension
        else { return nil }
        let figure = "\(DecimalFormatting.text(intake.amount)) \(intake.unit.symbol)"
        return ReferenceGoalHint(
            nutrient: nutrient, amount: intake.amount, unit: intake.unit,
            text: "\(intake.kind.abbreviation) \(figure) for \(group.label)")
    }

    /// Writes the row's reference value as its goal. Returns whether it was written.
    ///
    /// The row's draft and unit are set to the new goal too: an empty row's draft is an empty string, and
    /// left that way the next time its field loses focus it would be committed as a request to remove
    /// the goal just written.
    @discardableResult
    public func useReferenceGoal(for nutrient: String) -> Bool {
        guard let hint = self.referenceGoalHint(for: nutrient) else { return false }
        let text = DecimalFormatting.text(hint.amount)
        guard self.setTarget(text, for: nutrient, unit: hint.unit) else { return false }
        self.draftText[nutrient] = text
        self.selectedUnits[nutrient] = hint.unit
        return true
    }
}

/// The reference value under a goal row with no target, and a button that makes it the goal. Shows
/// nothing when there is no hint for the row.
struct ReferenceGoalHintLine: View {
    @ObservedObject var model: GoalsViewModel
    let nutrient: String

    var body: some View {
        if let hint = model.referenceGoalHint(for: nutrient) {
            HStack(alignment: .firstTextBaseline) {
                Text(hint.text)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
                Spacer(minLength: DesignSpacing.s)
                Button("Use") { model.useReferenceGoal(for: nutrient) }
                    .font(.footnote)
                    // Only the button takes the tap, not the whole row it sits in.
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Use \(hint.text) as the daily target for \(model.displayName(for: nutrient))")
            }
        }
    }
}
