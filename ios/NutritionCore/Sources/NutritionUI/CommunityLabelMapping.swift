import Foundation
import NutritionDomain
import NutritionProviders

/// The limits the catalog enforces on what it stores. The app sends nothing outside them and trusts nothing
/// outside them when it reads a label back, because every value is something another person typed.
public enum CommunityLabelLimits {
    public static let nameLength = 120
    public static let brandLength = 80
    public static let servingLength = 80
    /// Decimal places the catalog keeps.
    public static let fractionDigits = 3

    /// The largest amount the catalog accepts for a standard nutrient, in the unit it is stored in.
    public static func maximum(for key: String) -> Decimal {
        switch key {
        case LookedUpProduct.energyKcal: return 9_000
        case LookedUpProduct.sodium: return 100_000
        default: return 1_000
        }
    }

    /// Whether an amount is inside the catalog's range for the nutrient.
    public static func accepts(_ amount: Decimal, for key: String) -> Bool {
        amount >= 0 && amount <= maximum(for: key)
    }

    /// Whether the text fields are short enough for the catalog to take.
    public static func fits(name: String, brand: String?, serving: String?) -> Bool {
        name.count <= nameLength && (brand?.count ?? 0) <= brandLength && (serving?.count ?? 0) <= servingLength
    }
}

/// Turns what the community catalog shows for a barcode into the product the form reads, and says how
/// many people agree on it. The values are carried as the catalog gives them: nothing is rounded or guessed.
public enum CommunityLabelMapping {
    /// The catalog's identifier, stored with an entry as its origin so a reader can tell where the values came from.
    public static let source = "community"

    /// The bases in the order they are preferred: values per 100 g are the most comparable, then per 100 mL,
    /// then per serving.
    private static let preference: [CommunityBasis] = [.per100g, .per100ml, .perServing]

    /// The product for a barcode, from the most preferred basis the catalog has. Nil when the catalog has no
    /// label, or the chosen label states none of the standard nutrients.
    public static func product(barcode: String, labels: [CommunityLabel]) -> LookedUpProduct? {
        for basis in preference {
            guard let label = labels.first(where: { $0.basis == basis }) else { continue }
            let nutrients = nutrients(label.nutrients)
            guard !nutrients.isEmpty else { return nil }
            return LookedUpProduct(
                barcode: barcode, name: String(label.productName.prefix(CommunityLabelLimits.nameLength)),
                brand: label.brand.map { String($0.prefix(CommunityLabelLimits.brandLength)) },
                basis: lookupBasis(basis), nutrients: nutrients,
                attribution: attribution(verified: label.verified, supportingAccounts: label.supportingAccounts),
                serving: basis == .perServing
                    ? ServingDefinition(quantity: nil, unit: nil, text: label.servingText) : nil)
        }
        return nil
    }

    /// The line that goes next to the values. A verified label and an unverified one read differently, so a
    /// person can tell which values the community has settled on.
    public static func attribution(verified: Bool, supportingAccounts: Int) -> ProductAttribution {
        let agreement = supportingAccounts == 1 ? "1 person agrees" : "\(supportingAccounts) people agree"
        let text = verified
            ? "Verified by the community: \(agreement) on these values."
            : "Shared by the community, not yet verified: \(agreement)."
        return ProductAttribution(source: source, text: text, url: "")
    }

    /// The unit each standard nutrient is stored in: energy in kcal, sodium in mg, the rest in grams.
    static func unit(for key: String) -> MeasureUnit {
        switch key {
        case LookedUpProduct.energyKcal: return .kcal
        case LookedUpProduct.sodium: return .mg
        default: return .g
        }
    }

    /// The catalog's nutrient amounts under the app's own keys. A key the app does not know is dropped, and a
    /// standard key the label lacks is absent, so the product reads it as unknown.
    static func nutrients(_ values: [String: Decimal]) -> [String: NutrientValue] {
        var out: [String: NutrientValue] = [:]
        for key in LookedUpProduct.standardKeys {
            guard let amount = values[key], CommunityLabelLimits.accepts(amount, for: key) else { continue }
            out[key] = .known(amount, unit(for: key))
        }
        return out
    }

    private static func lookupBasis(_ basis: CommunityBasis) -> BarcodeLookupBasis {
        switch basis {
        case .per100g: return .per100g
        case .per100ml: return .per100ml
        case .perServing: return .perServing
        }
    }
}
