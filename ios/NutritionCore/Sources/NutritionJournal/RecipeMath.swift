import Foundation
import NutritionDomain

/// Totals for the whole recipe. A nutrient that any ingredient lacks is `.unknown`, never a partial sum.
public struct RecipeTotals: Sendable, Equatable {
    public let values: [String: NutrientValue]
    /// Ingredients that lack each nutrient, keyed by nutrient id.
    public let lacking: [String: Int]
    public let ingredientCount: Int

    public init(values: [String: NutrientValue], lacking: [String: Int], ingredientCount: Int) {
        self.values = values
        self.lacking = lacking
        self.ingredientCount = ingredientCount
    }
}

/// "N of M ingredients lack a nutrient".
public struct RecipeCoverage: Sendable, Equatable, Identifiable {
    public let nutrientID: String
    public let lacking: Int
    public let total: Int

    public var id: String { nutrientID }

    public init(nutrientID: String, lacking: Int, total: Int) {
        self.nutrientID = nutrientID
        self.lacking = lacking
        self.total = total
    }

    public func text(nutrientName: String) -> String {
        "\(lacking) of \(total) ingredients lack \(nutrientName)"
    }

    public var isComplete: Bool { lacking == 0 }

    /// One entry per nutrient, sorted by id.
    public static func make(from totals: RecipeTotals) -> [RecipeCoverage] {
        totals.lacking.keys.sorted().map {
            RecipeCoverage(nutrientID: $0, lacking: totals.lacking[$0] ?? 0, total: totals.ingredientCount)
        }
    }
}

public enum RecipeMath {
    /// Sums each nutrient over the ingredients. Unknown, not-applicable, below-threshold, missing and
    /// unconvertible values all count as lacking; none is read as zero. A known zero stays zero.
    public static func totals(of version: RecipeVersion) -> RecipeTotals {
        var nutrientIDs = Set<String>()
        for ingredient in version.ingredients {
            for key in ingredient.perUnit.keys { nutrientIDs.insert(key) }
        }
        var values: [String: NutrientValue] = [:]
        var lackingCounts: [String: Int] = [:]
        for nutrientID in nutrientIDs {
            var lackingCount = 0
            var sum: Quantity?
            for ingredient in version.ingredients {
                guard let contribution = contribution(of: ingredient, nutrientID: nutrientID) else {
                    lackingCount += 1
                    continue
                }
                if let running = sum {
                    if let added = try? running.adding(contribution) {
                        sum = added
                    } else {
                        lackingCount += 1
                    }
                } else {
                    sum = contribution
                }
            }
            if lackingCount == 0, let sum {
                values[nutrientID] = .known(sum.value, sum.unit)
            } else {
                values[nutrientID] = .unknown
            }
            lackingCounts[nutrientID] = lackingCount
        }
        return RecipeTotals(values: values, lacking: lackingCounts, ingredientCount: version.ingredients.count)
    }

    /// The ingredient's contribution, or nil when it cannot be stated.
    static func contribution(of ingredient: RecipeIngredient, nutrientID: String) -> Quantity? {
        guard let stored = ingredient.perUnit[nutrientID], case .known(let perUnitAmount, let nutrientUnit) = stored else {
            return nil
        }
        guard let amount = try? ingredient.quantity.converted(to: ingredient.effectiveBasisUnit, density: ingredient.density) else {
            return nil
        }
        return Quantity(value: perUnitAmount * amount.value, unit: nutrientUnit)
    }

    /// Scales the totals to one portion. For `.servings` the portion is a number of servings; for `.total`
    /// it is an amount in `portionUnit` (default: the yield's unit), converted exactly to the yield's unit.
    public static func perPortion(
        _ totals: RecipeTotals, yield: RecipeYield, portion: Decimal, portionUnit: MeasureUnit? = nil
    ) throws -> [String: NutrientValue] {
        guard portion > 0 else { throw RecipeError.nonPositivePortion }
        guard yield.amount > 0 else { throw RecipeError.nonPositiveYield }
        let factor: Decimal
        switch yield {
        case .servings(let count):
            if let portionUnit, portionUnit != .serving { throw RecipeError.portionDimensionMismatch }
            factor = portion / count
        case .total(let quantity):
            let unit = portionUnit ?? quantity.unit
            guard unit.dimension == quantity.unit.dimension else { throw RecipeError.portionDimensionMismatch }
            do {
                let converted = try Quantity(value: portion, unit: unit).converted(to: quantity.unit)
                factor = converted.value / quantity.value
            } catch let error as UnitError {
                throw RecipeError.unitConversion(error)
            }
        }
        var result: [String: NutrientValue] = [:]
        for (key, value) in totals.values {
            result[key] = value.scaled(by: factor)
        }
        return result
    }
}
