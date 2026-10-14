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
    /// Vitamins A, D and E are never offered a reference goal. They are the ones the Goals screen keeps
    /// off its fixed list because a label may state them in IU (vitamins A and D usually, vitamin E on
    /// older labels), which a goal in mcg or mg cannot be compared with; they stay on the label-capture
    /// goal path.
    public static let referenceGoalExcludedKeys: Set<String> = ["vitaminA", "vitaminD", "vitaminE"]

    /// The reference value a row may take, or nil when no group is chosen, the key is not in the
    /// reference table (chloride, a captured alias such as `vitamin-a`, a macronutrient) or is one of
    /// `referenceGoalExcludedKeys`, the row is not offered, a goal is already set, or the person has
    /// started typing their own number in the row (Use would replace it).
    public func referenceGoalHint(for nutrient: String) -> ReferenceGoalHint? {
        let row = self.rows.first(where: { $0.nutrient == nutrient })
        // A goal kept under another key for the same nutrient, such as a label's `vitamin-c`, is a goal for
        // this nutrient too, so the row is not offered a second one.
        let hasGoalUnderAlias = self.rows.contains {
            $0.nutrient != nutrient && $0.targetText != nil
                && HealthKitWritePlanner.canonicalKey(for: $0.nutrient) == nutrient
        }
        return Self.referenceGoalHint(
            nutrient: nutrient, group: self.referenceGroup,
            isOfferedWithoutGoal: row != nil && row?.targetText == nil && !hasGoalUnderAlias,
            draft: self.draftText[nutrient], goalUnit: self.unit(for: nutrient))
    }

    /// The rule behind `referenceGoalHint(for:)`, with the row's state passed in so each condition can be
    /// tested on its own. `goalUnit` is the unit the row's goal is counted in; a reference in another
    /// dimension (a row counted in IU) is never offered.
    static func referenceGoalHint(
        nutrient: String, group: ReferenceGroup?, isOfferedWithoutGoal: Bool, draft: String?,
        goalUnit: MeasureUnit
    ) -> ReferenceGoalHint? {
        guard let group, !referenceGoalExcludedKeys.contains(nutrient), isOfferedWithoutGoal,
            (draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let intake = ReferenceIntakes.intake(for: nutrient, group: group),
            intake.unit.dimension == goalUnit.dimension
        else { return nil }
        // Worded and rounded exactly as the vitamins and minerals screen states the same value.
        let figure = NutrientGapRow.figure(intake.amount, intake.unit)
        return ReferenceGoalHint(
            nutrient: nutrient, amount: intake.amount, unit: intake.unit,
            text: "\(intake.kind.abbreviation) \(figure) for \(group.label)")
    }

    /// Writes the row's reference value as its goal. Returns whether it was written.
    ///
    /// It goes through the row exactly as a typed target does: the row's draft and unit are set to the
    /// value and the row is committed, so the field shows the new goal (an empty draft left behind would
    /// be committed as a request to remove it when the field next loses focus) and any error the row
    /// showed for earlier text is cleared.
    @discardableResult
    public func useReferenceGoal(for nutrient: String) -> Bool {
        guard let hint = self.referenceGoalHint(for: nutrient) else { return false }
        let earlierUnit = self.selectedUnits[nutrient]
        self.draftText[nutrient] = DecimalFormatting.text(hint.amount)
        self.selectedUnits[nutrient] = hint.unit
        guard self.commitTarget(for: nutrient) else {
            // Nothing was saved, so the row goes back to how it was, unit included.
            self.draftText[nutrient] = ""
            self.selectedUnits[nutrient] = earlierUnit
            return false
        }
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
