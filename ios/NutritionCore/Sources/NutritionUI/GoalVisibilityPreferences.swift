import Foundation

/// Which goals show on Today. A goal with a target is shown by default; a person can switch one off.
///
/// Hiding a goal removes its bar from the Today card and from the Journal day header. It changes
/// nothing else: the goal and its target are kept, and the day's totals are still computed.
public protocol GoalVisibilityPreferences: AnyObject {
    /// The nutrients whose bars are hidden. Empty when every goal shows.
    var hiddenTodayGoals: Set<String> { get }
    /// Shows or hides the bar for `nutrient`.
    func setGoalShownOnToday(_ nutrient: String, shown: Bool)
}

/// The hidden set of a preference store, or none hidden where the store does not keep the choice.
/// Today and the Journal read the choice through this, so a store that predates it still works.
func hiddenTodayGoals(in preferences: DisplayPreferences) -> Set<String> {
    (preferences as? GoalVisibilityPreferences)?.hiddenTodayGoals ?? []
}
