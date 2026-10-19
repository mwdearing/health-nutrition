import Foundation

/// The calories left today: Remaining = goal − food + burned.
///
/// `burned` is nil unless the person chose to count activity, so a Burned figure is shown only when it is part of
/// Remaining. With no goal there is no Remaining. With no known food total there is no Remaining either, because
/// it would read as more left than there is. A partial food total (some entries have no calories) is still used.
///
/// The partial flag and the partial note come from one missing-entry count, so they cannot disagree: the day is
/// partial exactly when entries lack a value, and the note is present exactly then. The note does not depend on the
/// goal, so it shows the same way with the goal on and with it off.
public struct CalorieRemaining: Equatable, Sendable {
    public let goal: Decimal?
    public let food: Decimal?
    public let isPartial: Bool
    /// The note for a partial day, as the goal rows word it, or nil when every entry has a value.
    public let partialNote: String?
    public let burned: Decimal?
    public let remaining: Decimal?

    public static let none = CalorieRemaining(
        goal: nil, food: nil, isPartial: false, partialNote: nil, burned: nil, remaining: nil)

    public init(
        goal: Decimal?, food: Decimal?, isPartial: Bool, partialNote: String?, burned: Decimal?, remaining: Decimal?
    ) {
        self.goal = goal
        self.food = food
        self.isPartial = isPartial
        self.partialNote = partialNote
        self.burned = burned
        self.remaining = remaining
    }

    /// Builds the summary from the energy line's missing-entry count, so the flag and the note come from one value.
    public static func make(
        goal: Decimal?, food: Decimal?, missingCount: Int, burned: Decimal?, energyLabel: String
    ) -> CalorieRemaining {
        let note = partialNote(missingCount: missingCount, label: energyLabel)
        let isPartial = note != nil
        guard let goal, let food else {
            return CalorieRemaining(
                goal: goal, food: food, isPartial: isPartial, partialNote: note, burned: burned, remaining: nil)
        }
        let remaining = goal - food + (burned ?? 0)
        return CalorieRemaining(
            goal: goal, food: food, isPartial: isPartial, partialNote: note, burned: burned, remaining: remaining)
    }

    /// The shipped partial wording: "1 entry has no energy value" and "2 entries have no energy value".
    static func partialNote(missingCount: Int, label: String) -> String? {
        let name = label.prefix(1).lowercased() + label.dropFirst()
        if missingCount == 1 { return "1 entry has no \(name) value" }
        if missingCount > 1 { return "\(missingCount) entries have no \(name) value" }
        return nil
    }
}
