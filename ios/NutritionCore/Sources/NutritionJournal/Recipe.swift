import Foundation
import NutritionDomain

public enum RecipeError: Error, Sendable, Equatable {
    case emptyTitle
    case noIngredients
    case invalidVersionNumber(Int)
    case nonPositiveYield
    case emptyIngredientName(String)
    case nonPositiveQuantity(String)
    case invalidDensity(String)
    case duplicateIngredientID(String)
    case nonPositivePortion
    case portionDimensionMismatch
    case unitConversion(UnitError)
    case nothingToLog
}

/// One ingredient line. Nutrient values are stated per ONE of `basisUnit` (default: the quantity's own unit).
public struct RecipeIngredient: Sendable, Hashable {
    public var id: String
    public var name: String
    public var quantity: Quantity
    /// Keyed by nutrient id. A missing key means the value is not known.
    public var perUnit: [String: NutrientValue]
    /// Grams per millilitre, used only when mass and volume must be converted.
    public var density: Decimal?
    public var sourceNote: String?
    /// The unit the per-unit values refer to; nil means the quantity's unit.
    public var basisUnit: MeasureUnit?

    public init(
        id: String, name: String, quantity: Quantity, perUnit: [String: NutrientValue],
        density: Decimal? = nil, sourceNote: String? = nil, basisUnit: MeasureUnit? = nil
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.perUnit = perUnit
        self.density = density
        self.sourceNote = sourceNote
        self.basisUnit = basisUnit
    }

    public var effectiveBasisUnit: MeasureUnit { basisUnit ?? quantity.unit }
}

public enum RecipeYield: Sendable, Hashable {
    case servings(Decimal)
    case total(Quantity)

    public var amount: Decimal {
        switch self {
        case .servings(let count): return count
        case .total(let quantity): return quantity.value
        }
    }
}

/// An immutable, numbered version of a recipe. A change is a new version; older versions never change.
public struct RecipeVersion: Sendable, Hashable {
    public let recipeID: String
    public let number: Int
    public let title: String
    public let ingredients: [RecipeIngredient]
    public let yield: RecipeYield
    public let notes: String
    public let createdAt: Date

    public init(
        recipeID: String, number: Int, title: String, ingredients: [RecipeIngredient],
        yield: RecipeYield, notes: String = "", createdAt: Date
    ) {
        self.recipeID = recipeID
        self.number = number
        self.title = title
        self.ingredients = ingredients
        self.yield = yield
        self.notes = notes
        self.createdAt = createdAt
    }

    /// Throws the first rule that is broken.
    public func validate() throws {
        guard number >= 1 else { throw RecipeError.invalidVersionNumber(number) }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RecipeError.emptyTitle }
        guard !ingredients.isEmpty else { throw RecipeError.noIngredients }
        guard yield.amount > 0 else { throw RecipeError.nonPositiveYield }
        var seen = Set<String>()
        for ingredient in ingredients {
            guard !ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RecipeError.emptyIngredientName(ingredient.id)
            }
            guard ingredient.quantity.value > 0 else { throw RecipeError.nonPositiveQuantity(ingredient.id) }
            if let density = ingredient.density, !(density > 0) {
                throw RecipeError.invalidDensity(ingredient.id)
            }
            guard seen.insert(ingredient.id).inserted else { throw RecipeError.duplicateIngredientID(ingredient.id) }
        }
    }
}
