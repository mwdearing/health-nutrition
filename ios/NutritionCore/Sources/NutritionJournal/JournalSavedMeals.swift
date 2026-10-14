import Foundation

/// A saved meal as the journal export and restore see it: a named group of templates logged together.
/// The app keeps saved meals outside the journal store; its store maps them to and from this shape, so the
/// exporter and the importer need nothing from the screens' module.
public struct JournalSavedMeal: Sendable, Hashable {
    public var id: String
    public var name: String
    /// The meal the group was saved under; nil names none.
    public var meal: MealLabel?
    /// One template per entry the group logs, in the order they were saved. An item states no meal of its own.
    public var items: [FavoriteTemplate]

    public init(id: String, name: String, meal: MealLabel?, items: [FavoriteTemplate]) {
        self.id = id
        self.name = name
        self.meal = meal
        self.items = items
    }
}

/// The limits a saved meal list keeps, shared by the screens that save meals and the importer that
/// restores them, so a restore can never write a list the app would refuse to save.
public enum JournalSavedMealLimits {
    /// The longest name, in characters, once outer spaces are trimmed.
    public static let maximumNameLength = 60
    /// The most items one saved meal holds.
    public static let maximumItems = 30
    /// The most saved meals the list holds.
    public static let maximumMeals = 100

    /// The name as it is kept: outer spaces trimmed.
    public static func trimmedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether two names are the same name: equal once trimmed, ignoring case.
    public static func sameName(_ first: String, _ second: String) -> Bool {
        trimmedName(first).caseInsensitiveCompare(trimmedName(second)) == .orderedSame
    }
}

/// Where the exporter reads saved meals from and the importer writes them to.
///
/// A restore writes the whole list in one write, and in the same step a receipt naming the restored file,
/// so the fact that these saved meals were written survives a stop before the restore is marked finished
/// (#118). The importer only restores into a list that is empty or already holds exactly the file's meals.
public protocol JournalSavedMealsStore: AnyObject, Sendable {
    /// Every saved meal, in the list's own order (newest first).
    func journalSavedMeals() throws -> [JournalSavedMeal]
    /// Replaces the list with `meals` and records `receipt`. A failure leaves the list as it was.
    func restoreJournalSavedMeals(_ meals: [JournalSavedMeal], receipt: String) throws
    /// Whether a restore that carried this receipt has been written.
    func hasSavedMealsRestoreReceipt(_ receipt: String) throws -> Bool
    /// Forgets the receipt once nothing needs it.
    func removeSavedMealsRestoreReceipt(_ receipt: String) throws
    /// Empties the list and forgets any receipt: how a restore whose next step failed is put back.
    func clearRestoredSavedMeals() throws
}
