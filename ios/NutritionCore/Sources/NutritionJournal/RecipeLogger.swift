import Foundation
import NutritionDomain

/// Writes one portion of a recipe into the journal as a single intake.
public enum RecipeLogger {
    public static let category = "recipe"
    public static let catalogOrigin = "recipe_calculated"

    /// One `create` call. The intake holds ONE component named after the recipe, holding the portion
    /// in the yield's own unit, and the recipe version as its product snapshot. The snapshot carries
    /// the per-serving nutrient values, so the journal row reads as the recipe the user chose and
    /// Today resolves the values from the snapshot rather than from one component per nutrient.
    ///
    /// A nutrient that is unknown for this version is stored as `.unknown` in the snapshot, never as
    /// a zero-valued component. Throws `RecipeError.nothingToLog` when no nutrient is known at all.
    /// The product snapshot id names the exact version, and the frozen version itself stays in the
    /// recipe store.
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
        guard portion > 0 else { throw RecipeError.nonPositivePortion }
        let totals = RecipeMath.totals(of: version)
        // The snapshot states one serving, so it is the same for every portion of this version.
        let perServing = try RecipeMath.perPortion(totals, yield: version.yield, portion: 1)
        let hasKnownNutrient = perServing.values.contains { value in
            if case .known = value { return true }
            return false
        }
        guard hasKnownNutrient else { throw RecipeError.nothingToLog }
        let quantity = try portionQuantity(yield: version.yield, portion: portion, portionUnit: portionUnit)
        let component = IntakeComponent(
            componentID: componentID(for: version.recipeID), name: version.title,
            amount: quantity.value, unit: quantity.unit)
        let product = ProductDefinition(
            snapshotID: snapshotID(recipeID: version.recipeID, number: version.number),
            productID: version.recipeID, name: version.title,
            labelBasis: basisText(version.yield),
            catalogOrigin: catalogOrigin, catalogVersion: String(version.number),
            nutrients: perServing)
        let intake = Intake(
            id: id, category: category, occurredAt: now, timeZoneIdentifier: timeZoneIdentifier, meal: meal)
        try store.create(intake, components: [component], product: product, now: now)
        return id
    }

    /// The portion as a quantity in the yield's own unit: servings for a `.servings` yield, the
    /// yield's unit for a `.total` yield. Conversions go through the unit registry only.
    static func portionQuantity(
        yield: RecipeYield, portion: Decimal, portionUnit: MeasureUnit?
    ) throws -> Quantity {
        switch yield {
        case .servings:
            if let portionUnit, portionUnit != .serving { throw RecipeError.portionDimensionMismatch }
            return Quantity(value: portion, unit: .serving)
        case .total(let quantity):
            let unit = portionUnit ?? quantity.unit
            guard unit.dimension == quantity.unit.dimension else { throw RecipeError.portionDimensionMismatch }
            do {
                return try Quantity(value: portion, unit: unit).converted(to: quantity.unit)
            } catch let error as UnitError {
                throw RecipeError.unitConversion(error)
            }
        }
    }

    public static func snapshotID(recipeID: String, number: Int) -> String {
        "recipe:\(recipeID):v\(number)"
    }

    public static func basisText(_ yield: RecipeYield) -> String {
        switch yield {
        case .servings(let count):
            return "Per serving; yield \(DecimalText.encode(count)) servings"
        case .total(let quantity):
            return "Per \(quantity.unit.symbol); yield \(DecimalText.encode(quantity.value)) \(quantity.unit.symbol)"
        }
    }

    /// The one component of a logged recipe. A logged recipe is a single component, so it cannot
    /// collide with another component id the way one-per-nutrient ids did; the slug only has to be a
    /// valid component id, and it stays stable for the recipe so a repeat keeps the same shape.
    static func componentID(for recipeID: String) -> String {
        var slug = ""
        for scalar in recipeID.lowercased().unicodeScalars {
            let isLetter = scalar.isASCII && (("a"..."z").contains(Character(scalar)))
            let isDigit = scalar.isASCII && (("0"..."9").contains(Character(scalar)))
            if isLetter || isDigit {
                slug.append(Character(scalar))
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return String(("recipe-" + (slug.isEmpty ? "logged" : slug)).prefix(64))
    }
}