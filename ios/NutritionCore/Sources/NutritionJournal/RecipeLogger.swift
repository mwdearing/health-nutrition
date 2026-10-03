import Foundation
import NutritionDomain

/// Writes one portion of a recipe into the journal as a single intake.
public enum RecipeLogger {
    public static let category = "recipe"
    public static let catalogOrigin = "recipe_calculated"

    /// One `create` call. Each nutrient with a known per-portion value becomes one component. A nutrient
    /// that is unknown for this version is omitted, never written as zero. Throws
    /// `RecipeError.nothingToLog` when no nutrient is known. The product snapshot id names the exact version,
    /// and the frozen version itself stays in the recipe store.
    @discardableResult
    public static func logPortion(
        store: JournalStore,
        version: RecipeVersion,
        portion: Decimal,
        now: Date,
        id: String,
        timeZoneIdentifier: String,
        meal: String? = nil,
        portionUnit: MeasureUnit? = nil
    ) throws -> String {
        try version.validate()
        let totals = RecipeMath.totals(of: version)
        let perPortion = try RecipeMath.perPortion(totals, yield: version.yield, portion: portion, portionUnit: portionUnit)
        var components: [IntakeComponent] = []
        for key in perPortion.keys.sorted() {
            guard case .known(let amount, let unit) = perPortion[key] ?? .unknown else { continue }
            components.append(IntakeComponent(
                componentID: componentID(for: key), name: key, amount: amount, unit: unit))
        }
        guard !components.isEmpty else { throw RecipeError.nothingToLog }
        let product = ProductDefinition(
            snapshotID: snapshotID(recipeID: version.recipeID, number: version.number),
            productID: version.recipeID, name: version.title,
            labelBasis: basisText(version.yield),
            catalogOrigin: catalogOrigin, catalogVersion: String(version.number))
        let intake = Intake(
            id: id, category: category, occurredAt: now, timeZoneIdentifier: timeZoneIdentifier, meal: meal)
        try store.create(intake, components: components, product: product, now: now)
        return id
    }

    public static func snapshotID(recipeID: String, number: Int) -> String {
        "recipe:\(recipeID):v\(number)"
    }

    static func basisText(_ yield: RecipeYield) -> String {
        switch yield {
        case .servings(let count):
            return "Yield: \(DecimalText.encode(count)) servings"
        case .total(let quantity):
            return "Yield: \(DecimalText.encode(quantity.value)) \(quantity.unit.symbol)"
        }
    }

    /// `nutrient-<id>` with the id reduced to slug characters.
    static func componentID(for nutrientID: String) -> String {
        var slug = ""
        for scalar in nutrientID.lowercased().unicodeScalars {
            let isAllowed = scalar.isASCII && (("a"..."z").contains(Character(scalar)) || ("0"..."9").contains(Character(scalar)))
            slug.append(isAllowed ? Character(scalar) : "-")
        }
        return String(("nutrient-" + slug).prefix(64))
    }
}
