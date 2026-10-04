import Foundation
import NutritionJournal

/// Accessibility text for the recipe screens, kept here so tests can read it.
public enum RecipeLabels {
    public static let newRecipe = "New recipe"
    public static let saveRecipe = "Save recipe"
    public static let addIngredient = "Add ingredient"
    public static let logPortion = "Log a portion"
    public static let editRecipe = "Edit recipe"
    public static let portionField = "Portion"
    public static let titleField = "Recipe title"
    public static let notesField = "Notes"
    public static let yieldAmountField = "Yield amount"
    public static let yieldKindPicker = "Yield type"
    public static let recipesRow = "Recipes"

    public static func open(title: String, version: Int) -> String {
        "Open \(title), version \(version)"
    }
    public static func delete(title: String) -> String { "Delete \(title)" }
    public static func removeIngredient(_ position: Int) -> String { "Remove ingredient \(position)" }
    public static func ingredientName(_ position: Int) -> String { "Name of ingredient \(position)" }
    public static func ingredientAmount(_ position: Int) -> String { "Amount of ingredient \(position)" }
    public static func ingredientUnit(_ position: Int) -> String { "Unit of ingredient \(position)" }
    public static func nutrientField(_ nutrient: String, position: Int) -> String {
        "\(nutrient) per unit of ingredient \(position)"
    }
}

public struct RecipeListItem: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let versionNumber: Int
    public let detail: String
}

@MainActor
public final class RecipeListViewModel: ObservableObject {
    @Published public private(set) var items: [RecipeListItem] = []
    @Published public private(set) var skippedMessage: String?
    @Published public private(set) var errorMessage: String?

    private let store: RecipeStore

    public init(store: RecipeStore) {
        self.store = store
    }

    public func load() {
        do {
            let result = try store.list()
            items = result.recipes.map {
                RecipeListItem(
                    id: $0.recipeID, title: $0.title, versionNumber: $0.number,
                    detail: "Version \($0.number), \($0.ingredients.count) ingredients")
            }
            skippedMessage = Self.skippedText(result.skippedCount)
            errorMessage = nil
        } catch {
            errorMessage = "Could not read the recipes."
        }
    }

    /// Hides the recipe; every stored version stays on the device.
    public func delete(id: String) {
        do {
            try store.deleteRecipe(id: id)
            load()
        } catch {
            errorMessage = "Could not delete the recipe."
        }
    }

    static func skippedText(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 stored recipe could not be read" : "\(count) stored recipes could not be read"
    }
}
