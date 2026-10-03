import Foundation
import NutritionDomain
import NutritionJournal
import XCTest

func uiDec(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

func uiTempURL(_ test: XCTestCase, _ name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory.appendingPathComponent(name)
}

func uiSampleVersion(
    number: Int = 1, perUnitB: [String: NutrientValue] = ["energy": .known(8, .kcal)]
) -> RecipeVersion {
    RecipeVersion(
        recipeID: "recipe-1", number: number, title: "Oat bake",
        ingredients: [
            RecipeIngredient(
                id: "oat-flour", name: "Oat flour", quantity: Quantity(value: 200, unit: .g),
                perUnit: ["energy": .known(uiDec("3.5"), .kcal), "protein": .known(uiDec("0.1"), .g)]),
            RecipeIngredient(
                id: "olive-oil", name: "Olive oil", quantity: Quantity(value: 20, unit: .g), perUnit: perUnitB),
        ],
        yield: .servings(4), createdAt: Date(timeIntervalSince1970: 1_700_000_000))
}
