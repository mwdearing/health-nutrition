import Foundation
import NutritionDomain

/// What the amount on the Add form comes to, from per-100 g values: calories and the three macros.
/// A value the source did not give is nil and reads as unknown, never as zero.
public struct AmountPreview: Equatable {
    public let grams: Decimal
    public let kcal: Decimal?
    public let protein: Decimal?
    public let carbohydrates: Decimal?
    public let fat: Decimal?

    static let gramsPerOunce = Decimal(string: "28.349523125")!

    static func make(
        nutrients: [String: NutrientValue], basis: BarcodeLookupBasis?, amountText: String, unit: MeasureUnit
    ) -> AmountPreview? {
        guard basis == .per100g, let amount = AmountParser.parseTyped(amountText) else { return nil }
        let grams: Decimal
        // Any mass the menu offers converts exactly through the shared quantity conversion; a volume does not.
        guard unit.dimension == .mass,
              let converted = try? Quantity(value: amount, unit: unit).converted(to: .g)
        else { return nil }
        grams = converted.value
        // Only a value in the unit the key is stated in (kcal for energy, grams for the macros) is scaled.
        func per(_ key: String, in expected: MeasureUnit) -> Decimal? {
            guard case .known(let value, let stated) = nutrients[key] ?? .unknown, stated == expected else {
                return nil
            }
            return value * grams / 100
        }
        return AmountPreview(
            grams: grams,
            kcal: per(LookedUpProduct.energyKcal, in: .kcal),
            protein: per(LookedUpProduct.protein, in: .g),
            carbohydrates: per(LookedUpProduct.carbohydrates, in: .g),
            fat: per(LookedUpProduct.fat, in: .g))
    }
}
