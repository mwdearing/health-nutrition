import Foundation
import NutritionDomain
import NutritionJournal

/// A named group of foods logged together, such as "Usual breakfast". Like a favorite it is a copy of what
/// was eaten, not a link to entries: deleting or editing an entry never changes a saved meal.
public struct SavedMeal: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// The meal the group was saved under, offered first when it is logged; nil names none. Logging always
    /// takes the meal it is given (`SavedMealLogger.log(_:as:now:)`), so a screen asks for it.
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
    /// The data was erased after the removal, so the removed meal must not come back.
    case erasedSinceRemoval

    /// The name is empty once spaces are trimmed.
    case emptyName
    /// The name is longer than `SavedMealBook.maximumNameLength` characters.
    case nameTooLong
    /// Another saved meal already has this name, ignoring case and outer spaces.
    case duplicateName
    /// There is nothing to save, or more than `SavedMealBook.maximumItems` items.
    case itemCount
    /// There are already `SavedMealBook.maximumMeals` saved meals.
    case tooManyMeals
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
        case .tooManyMeals: return "You can keep up to \(SavedMealBook.maximumMeals) saved meals. Remove one first."
        case .unsavableAmount: return "An item has an amount that cannot be saved."
        case .notFound: return "This saved meal is no longer available."
        case .erasedSinceRemoval: return "Couldn't put back this saved meal."
        case .unreadable: return "Could not read your saved meals."
        }
    }
}

/// Where saved meals are kept. Newest first.
public protocol SavedMealStoring: AnyObject, Sendable {
    /// Throws `SavedMealError.unreadable` when a stored value exists but is not a list this build can
    /// read, so a damaged list is never read as an empty one. No stored value at all is an empty list.
    func meals() throws -> [SavedMeal]
    /// Reads the list, lets `change` edit it and writes the result, as one step no other update on this
    /// store can interleave with. Nothing is written when the read or `change` throws.
    func update(_ change: (inout [SavedMeal]) throws -> Void) throws
    /// Counts erases of this store's data. A removal's Undo is only good in the generation it was issued in.
    var eraseGeneration: Int { get }
}

extension SavedMealStoring {
    /// Stores with no erase of their own never advance the generation.
    public var eraseGeneration: Int { 0 }
}

/// Saved meals in the app's defaults domain, as one JSON list under `key`. `eraseAll()` removes the key and the
/// restore receipt.
///
/// It is also what the journal export reads saved meals from and what a restore writes them into
/// (`JournalSavedMealsStore`): the same list, mapped to the journal's shape.
public final class UserDefaultsSavedMealStore: SavedMealStoring, JournalErasing, JournalSavedMealsStore,
    @unchecked Sendable {
    public static let key = "library.savedMeals.v1"
    /// The file digest of the last restore that wrote this list, kept until the restore is marked finished.
    public static let restoreReceiptKey = "library.savedMeals.restoreReceipt.v1"
    public static let eraseGenerationKey = "library.savedMeals.eraseGeneration.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func meals() throws -> [SavedMeal] {
        try lock.withLock { try read() }
    }

    public func update(_ change: (inout [SavedMeal]) throws -> Void) throws {
        try lock.withLock {
            var list = try read()
            try change(&list)
            defaults.set(try JSONEncoder().encode(list), forKey: Self.key)
        }
    }

    public var erasureName: String { "saved meals" }

    public func eraseAll() throws {
        lock.withLock {
            defaults.removeObject(forKey: Self.key)
            defaults.removeObject(forKey: Self.restoreReceiptKey)
            // Under its own key, absent is 0, and kept out of exports: only Undo reads it.
            defaults.set(eraseGeneration + 1, forKey: Self.eraseGenerationKey)
        }
    }

    public var eraseGeneration: Int { defaults.integer(forKey: Self.eraseGenerationKey) }

    public func journalSavedMeals() throws -> [JournalSavedMeal] {
        try meals().map { JournalSavedMeal(id: $0.id, name: $0.name, meal: $0.meal, items: $0.items) }
    }

    /// The list is written before its receipt, so a stop between the two leaves the file's meals with no
    /// receipt, which a resume recognises and writes again. The check and the write share the store's lock.
    public func restoreJournalSavedMeals(_ meals: [JournalSavedMeal], receipt: String) throws {
        let list = meals.map { SavedMeal(id: $0.id, name: $0.name, meal: $0.meal, items: $0.items) }
        let data = try JSONEncoder().encode(list)
        try lock.withLock {
            let current = try read()
            guard current.isEmpty || current == list else { throw JournalImportError.savedMealsNotEmpty }
            defaults.set(data, forKey: Self.key)
            defaults.set(receipt, forKey: Self.restoreReceiptKey)
        }
    }

    public func hasSavedMealsRestoreReceipt(_ receipt: String) throws -> Bool {
        lock.withLock { defaults.string(forKey: Self.restoreReceiptKey) == receipt }
    }

    public func removeSavedMealsRestoreReceipt(_ receipt: String) throws {
        lock.withLock {
            if defaults.string(forKey: Self.restoreReceiptKey) == receipt {
                defaults.removeObject(forKey: Self.restoreReceiptKey)
            }
        }
    }

    public func clearRestoredSavedMeals(_ meals: [JournalSavedMeal]) throws {
        let list = meals.map { SavedMeal(id: $0.id, name: $0.name, meal: $0.meal, items: $0.items) }
        try lock.withLock {
            guard try read() == list else { throw JournalImportError.savedMealsNotEmpty }
            defaults.removeObject(forKey: Self.key)
            defaults.removeObject(forKey: Self.restoreReceiptKey)
        }
    }

    private func read() throws -> [SavedMeal] {
        guard let value = defaults.object(forKey: Self.key) else { return [] }
        guard let data = value as? Data, let list = try? JSONDecoder().decode([SavedMeal].self, from: data) else {
            throw SavedMealError.unreadable
        }
        return list
    }
}

/// Adds, renames and removes saved meals, refusing an amount it could not log back exactly. It does not
/// re-check what the journal checks when an entry is written (component ids, categories): items come from
/// entries the journal already accepted.
public struct SavedMealBook {
    // The importer restores saved meals under the same limits, so they live where it can read them.
    public static let maximumNameLength = JournalSavedMealLimits.maximumNameLength
    public static let maximumItems = JournalSavedMealLimits.maximumItems
    public static let maximumMeals = JournalSavedMealLimits.maximumMeals
    private let store: any SavedMealStoring
    private let makeID: () -> String

    public init(store: any SavedMealStoring, makeID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.store = store
        self.makeID = makeID
    }

    public func meals() throws -> [SavedMeal] {
        try store.meals()
    }

    /// Ids for the items of a meal about to be added, made by the same generator `add` uses.
    public func newItemIDs(count: Int) -> [String] { (0..<count).map { _ in makeID() } }

    /// Saves `templates` as one new meal, newest first in the list, and returns it. The name is trimmed.
    /// Each template's own meal is dropped: the group is logged under `meal`, or under the meal picked then.
    /// `itemIDs` lets the caller name each item before the meal is written, so units keyed by those ids can be
    /// written first; omitted, each item gets a new id.
    @discardableResult
    public func add(name: String, meal: MealLabel?, templates: [RepeatTemplate], itemIDs: [String]? = nil) throws -> SavedMeal {
        let ids = itemIDs ?? templates.map { _ in makeID() }
        guard ids.count == templates.count else { throw SavedMealError.itemCount }
        let items = try zip(templates, ids).map { try Self.item(from: $0, id: $1) }
        let id = makeID()
        var saved = SavedMeal(id: id, name: name, meal: meal, items: items)
        try store.update { list in
            saved.name = try Self.validName(name, among: list, excluding: nil)
            guard (1...Self.maximumItems).contains(items.count) else { throw SavedMealError.itemCount }
            guard list.count < Self.maximumMeals else { throw SavedMealError.tooManyMeals }
            list.insert(saved, at: 0)
        }
        return saved
    }

    public func rename(id: String, to name: String) throws {
        try store.update { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { throw SavedMealError.notFound }
            list[index].name = try Self.validName(name, among: list, excluding: id)
        }
    }

    /// Removes the meal and returns the position it held, read in the same write so the two cannot disagree.
    @discardableResult
    public func remove(id: String) throws -> Int {
        var position = 0
        try store.update { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { throw SavedMealError.notFound }
            position = index
            list.remove(at: index)
        }
        return position
    }

    /// Puts back a meal `remove` took out, at the position it had. Returns false, and changes nothing, when the
    /// meal is already listed.
    @discardableResult
    /// The erase generation now. A removal records it, so its Undo can tell whether data was erased since.
    public var eraseGeneration: Int { store.eraseGeneration }

    public func restore(_ saved: SavedMeal, at index: Int, generation: Int) throws -> Bool {
        var restored = false
        try store.update { list in
            // An Undo issued before an erase must not write its meal back into the erased data.
            guard store.eraseGeneration == generation else { throw SavedMealError.erasedSinceRemoval }
            guard !list.contains(where: { $0.id == saved.id }) else { return }
            guard list.count < Self.maximumMeals else { throw SavedMealError.tooManyMeals }
            // A name saved since the removal can clash; the restore then fails rather than writing a duplicate.
            _ = try Self.validName(saved.name, among: list, excluding: saved.id)
            list.insert(saved, at: min(max(index, 0), list.count))
            restored = true
        }
        return restored
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

    /// The template as exact decimal text, refused when an amount could not come back as the same number, so
    /// a saved meal logs exactly what was eaten. Stricter than a favorite, which only needs the text to parse.
    private static func item(from template: RepeatTemplate, id: String) throws -> FavoriteTemplate {
        guard !template.components.isEmpty else { throw SavedMealError.unsavableAmount }
        let components = try template.components.map { component -> FavoriteComponent in
            let text = DecimalFormatting.text(component.amount)
            guard !component.amount.isNaN, AmountParser.parse(text) == component.amount else {
                throw SavedMealError.unsavableAmount
            }
            return FavoriteComponent(
                componentID: component.componentID, name: component.name, amountText: text,
                unitSymbol: component.unit.symbol, hydrationPercentText: component.hydrationPercent.map(DecimalFormatting.text))
        }
        return FavoriteTemplate(
            id: id, displayName: template.displayName, category: template.category, components: components,
            productSnapshotID: template.productSnapshotID, meal: nil)
    }
}
