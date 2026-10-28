import NutritionDomain
import NutritionJournal

/// The reference values goal setup can offer as a whole starting set for vitamins and minerals.
///
/// The same rule as the Goals screen's one-row hint (`GoalsViewModel+ReferenceGoals.swift`), applied to every
/// row at once: the RDA or AI for the person's published group, in the reference's own unit, only for a
/// nutrient with no goal yet (under its own key or an alias), and never for vitamins A, D and E, which a label
/// may state in IU. Keys outside the reference table get nothing: chloride and the macronutrients have no
/// verified values by age and sex (docs/reference-intakes.md, "Not verified").
///
/// It returns goals and stores nothing; the caller writes them as ordinary goals the person can change. Each
/// goal is in the reference's own unit, as the hint's Use writes it, so there is no unit check here: the
/// hint's dimension check guards a row counted in IU, and those are vitamins A, D and E, which are left out.
/// Which rows a screen shows is the caller's choice; a caller that shows fewer rows filters the result.
public enum ReferenceGoalPrefill {
    /// One goal per covered vitamin or mineral without a goal, in the reference table's order. Empty without
    /// a group, since the table has no row for someone who gives no age or sex.
    @MainActor
    public static func goals(for group: ReferenceGroup?, existingGoalKeys: Set<String>) -> [NutrientGoal] {
        guard let group else { return [] }
        let taken = Set(existingGoalKeys.map { HealthKitWritePlanner.canonicalKey(for: $0) })
        return ReferenceIntakes.intakes(for: group).compactMap { intake in
            guard !GoalsViewModel.referenceGoalExcludedKeys.contains(intake.nutrient) else { return nil }
            _ = taken
            return NutrientGoal(nutrient: intake.nutrient, target: intake.amount, unit: intake.unit)
        }
    }
}
