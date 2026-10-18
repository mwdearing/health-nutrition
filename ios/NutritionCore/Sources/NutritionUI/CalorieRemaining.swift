import Foundation

/// The calories left today: Remaining = goal − food + burned.
///
/// `burned` is nil unless the person chose to count activity, so a Burned figure is shown only when it is part of
/// Remaining. With no goal there is no Remaining. With no known food total there is no Remaining either, because
/// it would read as more left than there is. A partial food total (some entries have no calories) is still used,
/// and `isPartial` says so for the screen to mark.
public struct CalorieRemaining: Equatable, Sendable {
    public let goal: Decimal?
    public let food: Decimal?
    public let isPartial: Bool
    public let burned: Decimal?
    public let remaining: Decimal?

    public static let none = CalorieRemaining(goal: nil, food: nil, isPartial: false, burned: nil, remaining: nil)

    public init(goal: Decimal?, food: Decimal?, isPartial: Bool, burned: Decimal?, remaining: Decimal?) {
        self.goal = goal
        self.food = food
        self.isPartial = isPartial
        self.burned = burned
        self.remaining = remaining
    }

    public static func make(goal: Decimal?, food: Decimal?, isPartial: Bool, burned: Decimal?) -> CalorieRemaining {
        guard let goal, let food else {
            return CalorieRemaining(goal: goal, food: food, isPartial: isPartial, burned: burned, remaining: nil)
        }
        let remaining = goal - food + (burned ?? 0)
        return CalorieRemaining(goal: goal, food: food, isPartial: isPartial, burned: burned, remaining: remaining)
    }
}
