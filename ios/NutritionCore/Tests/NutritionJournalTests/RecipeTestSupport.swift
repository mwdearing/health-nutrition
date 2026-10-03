import XCTest
import Foundation
import NutritionDomain
@testable import NutritionJournal

func dec(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

func energyPerUnit(_ text: String) -> [String: NutrientValue] {
    ["energy": .known(dec(text), .kcal)]
}

func sampleIngredient(
    _ id: String, amount: String, unit: MeasureUnit = .g, perUnit: [String: NutrientValue],
    density: Decimal? = nil, basis: MeasureUnit? = nil
) -> RecipeIngredient {
    RecipeIngredient(
        id: id, name: id, quantity: Quantity(value: dec(amount), unit: unit), perUnit: perUnit,
        density: density, basisUnit: basis)
}

func sampleVersion(
    recipeID: String = "recipe-1", number: Int = 1, title: String = "Oat bake",
    ingredients: [RecipeIngredient]? = nil, yield: RecipeYield = .servings(4),
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> RecipeVersion {
    RecipeVersion(
        recipeID: recipeID, number: number, title: title,
        ingredients: ingredients ?? [
            sampleIngredient("oat-flour", amount: "200", perUnit: energyPerUnit("3.6")),
            sampleIngredient("olive-oil", amount: "20", perUnit: energyPerUnit("8.8")),
        ],
        yield: yield, createdAt: createdAt)
}

func makeRecipeStoreURL(_ test: XCTestCase) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory.appendingPathComponent("recipes.store")
}
