import Foundation
import NutritionProviders
import NutritionUI

/// Adapts the Open Food Facts client to the lookup protocol the intake UI depends on. The UI never
/// sees the client, the outcome type or the provider name; this file owns that knowledge, including
/// the attribution the license requires and the serving definition.
struct OpenFoodFactsProductLookup: BarcodeProductLookup {
    /// Stored with an entry as its catalog origin, so a later reader can tell which source a set of
    /// values came from.
    static let catalogOrigin = "open-food-facts"

    private let client: OpenFoodFactsClient

    init(client: OpenFoodFactsClient) {
        self.client = client
    }

    func lookUp(barcode: String) async -> BarcodeLookupResult {
        switch await client.lookup(barcode: barcode) {
        case .found(let product):
            return .found(Self.product(from: product))
        case .notFound:
            return .notFound
        case .rateLimited(let retryAfter):
            // Round up: retrying a second early would be rate-limited straight away, and a wait
            // that is never shorter than the source asked for cannot be wrong.
            return .rateLimited(retryAfterSeconds: retryAfter.map { max(1, Int(min($0, 86_400).rounded(.up))) })
        case .invalidBarcode:
            // The form checks the barcode before calling, so this only means the two checks
            // disagree; report it rather than looking up nothing.
            return .failed("invalid barcode")
        case .transport(let reason):
            return .failed(reason)
        }
    }

    private static func product(from product: OpenFoodFactsProduct) -> LookedUpProduct {
        LookedUpProduct(
            barcode: product.barcode,
            name: product.name,
            brand: product.brands,
            basis: basis(from: product.basis),
            nutrients: product.nutrients,
            attribution: attribution(),
            serving: serving(from: product),
            version: version(from: product)
        )
    }

    /// The wording and the link the license requires, carried in rather than hard-coded in the UI.
    private static func attribution() -> ProductAttribution {
        ProductAttribution(
            source: catalogOrigin, text: OpenFoodFactsAttribution.text, url: OpenFoodFactsAttribution.url)
    }

    /// Only for per-serving values: without the serving size those figures are ambiguous. The source
    /// may give the size only as text ("1 biscuit"), only as a number, or as both; whichever it gives
    /// is carried, and a per-serving response with neither says nothing rather than guessing.
    private static func serving(from product: OpenFoodFactsProduct) -> ServingDefinition? {
        guard product.basis == .perServing else { return nil }
        let text = product.servingSize?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = (text?.isEmpty == false) ? text : nil
        let quantity = product.servingQuantity.flatMap { $0 > 0 ? $0 : nil }
        guard trimmedText != nil || quantity != nil else { return nil }
        return ServingDefinition(quantity: quantity, unit: quantity == nil ? nil : .g, text: trimmedText)
    }

    /// The last-modified timestamp, so an entry can be traced to the version of the data it was
    /// filled from.
    private static func version(from product: OpenFoodFactsProduct) -> String? {
        guard let modified = product.lastModified else { return nil }
        return ISO8601DateFormatter().string(from: modified)
    }

    private static func basis(from basis: OpenFoodFactsBasis) -> BarcodeLookupBasis {
        switch basis {
        case .per100g: return .per100g
        case .per100ml: return .per100ml
        case .per100Unspecified: return .per100Unspecified
        case .perServing: return .perServing
        }
    }
}
