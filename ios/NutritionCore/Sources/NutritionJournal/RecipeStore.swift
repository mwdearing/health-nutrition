import Foundation

public enum RecipeStoreError: Error, Sendable, Equatable {
    case closed
    case versionConflict(expected: Int, got: Int)
    case recipeDeleted(String)
    case corruptRecord(String)
}

public struct RecipeListResult: Sendable, Equatable {
    /// The latest version of each recipe that is not deleted, newest first.
    public let recipes: [RecipeVersion]
    /// Stored rows that could not be read or failed validation.
    public let skippedCount: Int

    public init(recipes: [RecipeVersion], skippedCount: Int) {
        self.recipes = recipes
        self.skippedCount = skippedCount
    }
}

public protocol RecipeStore: AnyObject, Sendable {
    /// The version number must be 1 for a new recipe, else the latest number plus one. Never overwrites.
    func saveNewVersion(_ version: RecipeVersion) throws
    func list() throws -> RecipeListResult
    func version(recipeID: String, number: Int) throws -> RecipeVersion?
    /// Every readable version, oldest first. Still available after the recipe is deleted; a stored
    /// row that cannot be read is skipped and counted by `list()`.
    func versions(of recipeID: String) throws -> [RecipeVersion]
    /// Hides the recipe from `list()`. Every stored version is kept.
    func deleteRecipe(id: String) throws
    func close()
}
