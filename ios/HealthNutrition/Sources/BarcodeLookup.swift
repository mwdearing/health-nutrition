import Foundation
import NutritionDomain
import NutritionProviders
import NutritionUI

/// Open Food Facts name search. Barcodes do not use this source: barcodes resolve through the community
/// catalog only, so this adapter no longer answers a barcode lookup.
struct OpenFoodFactsProductLookup {
    /// Stored with an entry as its catalog origin, so a later reader can tell which source a set of
    /// values came from.
    static let catalogOrigin = "open-food-facts"

    private let client: OpenFoodFactsClient

    init(client: OpenFoodFactsClient) {
        self.client = client
    }

    /// Name search reuses the same mapping as a barcode hit, so a picked result is filled exactly like a scan.
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
        // The source's quantity is in the unit its text names: millilitres for "250 ml", grams for "30 g".
        // A text naming neither gives no unit, so the amount is not opened on it.
        let lowered = trimmedText?.lowercased() ?? ""
        let unit: MeasureUnit?
        let names = (
            volume: lowered.contains("ml"),
            mass: lowered.range(of: #"\d\s*g\b"#, options: .regularExpression) != nil)
        if quantity == nil || names.volume == names.mass {
            // Neither unit, or both ("1 cup (240 ml) (30 g)"), leaves the unit unknown.
            unit = nil
        } else {
            unit = names.volume ? .mL : .g
        }
        return ServingDefinition(quantity: quantity, unit: unit, text: trimmedText)
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

extension OpenFoodFactsProductLookup: ProductNameSearching {
    func search(query: String) async -> ProductNameSearchOutcome {
        switch await client.search(query: query) {
        case .results(let products):
            return .results(products.map { Self.product(from: $0) })
        case .empty:
            return .empty
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfterSeconds: retryAfter.map { max(1, Int(min($0, 86_400).rounded(.up))) })
        case .transport(let reason):
            return .failed(reason)
        }
    }
}
