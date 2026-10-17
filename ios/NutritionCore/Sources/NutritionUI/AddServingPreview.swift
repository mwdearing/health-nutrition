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
        switch unit {
        case .g: grams = amount
        case .oz: grams = amount * gramsPerOunce
        default: return nil
        }
        func per(_ key: String) -> Decimal? {
            guard case .known(let value, _) = nutrients[key] ?? .unknown else { return nil }
            return value * grams / 100
        }
        return AmountPreview(
            grams: grams,
            kcal: per(LookedUpProduct.energyKcal),
            protein: per(LookedUpProduct.protein),
            carbohydrates: per(LookedUpProduct.carbohydrates),
            fat: per(LookedUpProduct.fat))
    }
}
