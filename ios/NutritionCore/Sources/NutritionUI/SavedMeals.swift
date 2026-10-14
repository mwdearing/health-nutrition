import Foundation
import NutritionDomain
import NutritionJournal

/// A named group of foods logged together, such as "Usual breakfast". Like a favorite it is a copy of what
/// was eaten, not a link to entries: deleting or editing an entry never changes a saved meal.
public struct SavedMeal: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// The meal the group is logged under unless the person picks another one; nil names none.
    public var meal: MealLabel?
    /// One template per entry the group logs, in the order they were saved. Each keeps its amounts as exact
    /// decimal text and states no meal of its own: the group's meal applies to all of them.
    public var items: [FavoriteTemplate]

    public init(id: String, name: String, meal: MealLabel?, items: [FavoriteTemplate]) {
        self.id = id
        self.name = name
        self.meal = meal
        self.items = items
    }
}

/// Why a saved meal was refused or could not be read. Nothing is written when one is thrown.
public enum SavedMealError: Error, Equatable, Sendable {
    /// The name is empty once spaces are trimmed.
    case emptyName
    /// The name is longer than `SavedMealBook.maximumNameLength` characters.
    case nameTooLong
    /// Another saved meal already has this name, ignoring case and outer spaces.
    case duplicateName
    /// There is nothing to save, or more than `SavedMealBook.maximumItems` items.
    case itemCount
    /// An item has an amount that is unknown or cannot be written back as exact decimal text.
    case unsavableAmount
    /// No saved meal has this id any more.
    case notFound
    /// The stored list cannot be read. It is reported, never shown as an empty list.
    case unreadable

    /// The words a screen shows for the refusal.
    public var message: String {
        switch self {
        case .emptyName: return "Give the meal a name."
        case .nameTooLong: return "Use a name of \(SavedMealBook.maximumNameLength) characters or fewer."
        case .duplicateName: return "You already have a saved meal with this name."
        case .itemCount: return "A saved meal holds 1 to \(SavedMealBook.maximumItems) items."
        case .unsavableAmount: return "An item has an amount that cannot be saved."
        case .notFound: return "This saved meal is no longer available."
        case .unreadable: return "Could not read your saved meals."
        }
    }
}

/// Where saved meals are kept. Newest first.
public protocol SavedMealStoring: AnyObject, Sendable {
    /// Throws `SavedMealError.unreadable` when a stored list exists but cannot be decoded, so a damaged
    /// list is never read as an empty one. No stored list at all is an empty list.
    func meals() throws -> [SavedMeal]
    func replaceAll(with meals: [SavedMeal]) throws
}

/// Saved meals in the app's defaults domain, as one JSON list under `key`. Erase all data removes the key.
public final class UserDefaultsSavedMealStore: SavedMealStoring, JournalErasing, @unchecked Sendable {
    public static let key = "library.savedMeals.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func meals() throws -> [SavedMeal] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        guard let list = try? JSONDecoder().decode([SavedMeal].self, from: data) else { throw SavedMealError.unreadable }
        return list
    }

    public func replaceAll(with meals: [SavedMeal]) throws {
        defaults.set(try JSONEncoder().encode(meals), forKey: Self.key)
    }

    public func eraseAll() throws {
        defaults.removeObject(forKey: Self.key)
    }
}

/// Adds, renames and removes saved meals, refusing anything it could not log back exactly.
public struct SavedMealBook {
    public static let maximumNameLength = 60
    public static let maximumItems = 30
    private let store: any SavedMealStoring
    private let makeID: () -> String

    public init(store: any SavedMealStoring, makeID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.store = store
        self.makeID = makeID
    }

    public func meals() throws -> [SavedMeal] {
        try store.meals()
    }

    /// Saves `templates` as one new meal, newest first in the list, and returns it. The name is trimmed.
    /// Each template's own meal is dropped: the group is logged under `meal`, or under the meal picked then.
    @discardableResult
    public func add(name: String, meal: MealLabel?, templates: [RepeatTemplate]) throws -> SavedMeal {
        let current = try store.meals()
        let trimmed = try Self.validName(name, among: current, excluding: nil)
        guard (1...Self.maximumItems).contains(templates.count) else { throw SavedMealError.itemCount }
        let items = try templates.map { try Self.item(from: $0, id: makeID()) }
        let saved = SavedMeal(id: makeID(), name: trimmed, meal: meal, items: items)
        try store.replaceAll(with: [saved] + current)
        return saved
    }

    public func rename(id: String, to name: String) throws {
        var current = try store.meals()
        guard let index = current.firstIndex(where: { $0.id == id }) else { throw SavedMealError.notFound }
        current[index].name = try Self.validName(name, among: current, excluding: id)
        try store.replaceAll(with: current)
    }

    public func remove(id: String) throws {
        let current = try store.meals()
        guard current.contains(where: { $0.id == id }) else { throw SavedMealError.notFound }
        try store.replaceAll(with: current.filter { $0.id != id })
    }

    private static func validName(_ name: String, among meals: [SavedMeal], excluding id: String?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SavedMealError.emptyName }
        guard trimmed.count <= maximumNameLength else { throw SavedMealError.nameTooLong }
        let taken = meals.contains {
            $0.id != id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !taken else { throw SavedMealError.duplicateName }
        return trimmed
    }

    /// The template as exact decimal text, refused when an amount could not come back as the same number:
    /// the rule a favorite follows, so a saved meal logs exactly what was eaten.
    private static func item(from template: RepeatTemplate, id: String) throws -> FavoriteTemplate {
        guard !template.components.isEmpty else { throw SavedMealError.unsavableAmount }
        let components = try template.components.map { component -> FavoriteComponent in
            let text = DecimalFormatting.text(component.amount)
            guard !component.amount.isNaN, AmountParser.parse(text) == component.amount else {
                throw SavedMealError.unsavableAmount
            }
            return FavoriteComponent(
                componentID: component.componentID, name: component.name, amountText: text,
                unitSymbol: component.unit.symbol)
        }
        return FavoriteTemplate(
            id: id, displayName: template.displayName, category: template.category, components: components,
            productSnapshotID: template.productSnapshotID, meal: nil)
    }
}
