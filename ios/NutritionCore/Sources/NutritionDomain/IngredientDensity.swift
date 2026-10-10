import Foundation

/// One ingredient from the ExactCup density table: grams in one US customary cup.
public struct IngredientDensity: Equatable, Sendable {
    public let slug: String
    public let name: String
    public let category: String
    public let gramsPerCup: Decimal
    public let aliases: [String]

    init(slug: String, name: String, category: String, gramsPerCup: Decimal, aliases: [String]) {
        self.slug = slug
        self.name = name
        self.category = category
        self.gramsPerCup = gramsPerCup
        self.aliases = aliases
    }

    /// Grams per milliliter, the unit the recipe editor's density field takes. The table is per cup,
    /// so this divides by the exact cup volume and rounds to six fraction digits for display.
    public var gramsPerMilliliter: Decimal {
        DisplayRounding.rounded(gramsPerCup / MeasureUnit.cup.toBase, fractionDigits: 6)
    }

    /// The grams a volume of `milliliters` weighs at this ingredient's typical density. The table is per
    /// cup, so the grams are the milliliters times the table's grams, divided once by the exact cup volume,
    /// and rounded once to six fraction digits. A full cup is therefore exactly its table value.
    public func grams(forMilliliters milliliters: Decimal) -> Decimal {
        DisplayRounding.rounded(milliliters * gramsPerCup / MeasureUnit.cup.toBase, fractionDigits: 6)
    }
}

/// The density table and its lookup. The rows are generated into `IngredientDensityData.swift`.
public enum IngredientDensityCatalog {
    public static let attribution = "Ingredient densities: ExactCup, CC BY 4.0 (exactcup.github.io)."

    /// Every normalized name, slug and alias, mapped to the slugs that carry it.
    private static let index: [String: Set<String>] = {
        var index: [String: Set<String>] = [:]
        for row in IngredientDensityCatalog.rows {
            for key in [row.name, row.slug] + row.aliases {
                index[IngredientDensityCatalog.normalized(key), default: []].insert(row.slug)
            }
        }
        return index
    }()

    /// The one row a name names, or nil when no row has it or more than one row does. Matching is exact
    /// after normalizing case, hyphens and spaces. There is no substring or fuzzy matching, so an
    /// unknown or ambiguous name is never guessed at.
    public static func match(_ name: String) -> IngredientDensity? {
        guard let slugs = index[IngredientDensityCatalog.normalized(name)], slugs.count == 1,
              let slug = slugs.first else {
            return nil
        }
        return IngredientDensityCatalog.rows.first { $0.slug == slug }
    }

    /// Lowercased, hyphens read as spaces, runs of whitespace collapsed, ends trimmed.
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
