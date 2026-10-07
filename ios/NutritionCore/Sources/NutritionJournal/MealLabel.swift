import Foundation

/// Which meal of the day an entry belongs to.
///
/// Stored as this enum's raw value in `Intake.meal`, so an entry that states no meal keeps a nil
/// and a journal written before the vocabulary existed reads back unchanged. The column stays the
/// free text the export contract describes: this is the vocabulary the app offers and shows, not a
/// constraint on what a file may carry.
public enum MealLabel: String, Sendable, Hashable, Codable, CaseIterable {
    case breakfast
    case lunch
    case dinner
    case snack

    /// The label as words, which is what a screen shows.
    public var displayName: String {
        switch self {
        case .breakfast: return "Breakfast"
        case .lunch: return "Lunch"
        case .dinner: return "Dinner"
        case .snack: return "Snack"
        }
    }

    /// What one stored `Intake.meal` reads as, or nil when it states no meal.
    ///
    /// A value this build has no case for is shown as it was written rather than dropped or
    /// guessed at: the column is free text in the export, so an entry imported from elsewhere may
    /// carry words this vocabulary does not name, and the person's own wording is better than an
    /// invented one. Matching ignores case, so a file that spelled the label `Breakfast` still
    /// shows as a breakfast.
    public static func displayName(for stored: String?) -> String? {
        guard let stored else { return nil }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let label = MealLabel(rawValue: trimmed.lowercased()) { return label.displayName }
        return trimmed
    }
}