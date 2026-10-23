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

    /// True only when Remaining is shown: a goal and a known food total. The summary's goal footnote belongs with
    /// Remaining, so the view reads this rather than checking Remaining itself.
    public var showsRemaining: Bool { remaining != nil }

    /// Builds the summary from the energy line alone: its partial flag and its missing-entry count. The note is
    /// present exactly when the line is partial, so the flag and the note cannot disagree.
    public static func make(
        goal: Decimal?, food: Decimal?, partial: Bool, missingCount: Int, burned: Decimal?, energyLabel: String
    ) -> CalorieRemaining {
        let note = partial ? missingNote(missingCount: missingCount, label: energyLabel) : nil
        guard let goal, let food else {
            return CalorieRemaining(
                goal: goal, food: food, isPartial: partial, partialNote: note, burned: burned, remaining: nil)
        }
        let remaining = goal - food + (burned ?? 0)
        return CalorieRemaining(
            goal: goal, food: food, isPartial: partial, partialNote: note, burned: burned, remaining: remaining)
    }

    /// The partial note in the goal rows' own wording, from the one shared source.
    static func missingNote(missingCount: Int, label: String) -> String {
        MissingValueWording.note(count: missingCount, name: MissingValueWording.inSentence(label))
    }
}
