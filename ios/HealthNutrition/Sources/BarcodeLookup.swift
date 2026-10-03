import Foundation
import NutritionProviders
import NutritionUI

/// Adapts the Open Food Facts client to the lookup protocol the intake UI depends on. The UI never
/// sees the client, the outcome type or the provider name; the app target owns that knowledge.
struct OpenFoodFactsProductLookup: BarcodeProductLookup {
    private let client: OpenFoodFactsClient

    init(client: OpenFoodFactsClient) {
        self.client = client
    }

    func lookUp(barcode: String) async -> BarcodeLookupResult {
        switch await client.lookup(barcode: barcode) {
        case .found(let product):
            return .found(
                LookedUpProduct(
                    barcode: product.barcode,
                    name: product.name,
                    brand: product.brands,
                    basis: Self.basis(from: product.basis),
                    nutrients: product.nutrients
                )
            )
        case .notFound:
            return .notFound
        case .rateLimited:
            // The client already waits its turn; a rate limit that reaches the UI means try later.
            return .rateLimited
        case .invalidBarcode:
            // The form validates the barcode before calling, so this only means the two checks
            // disagree; report it rather than looking up nothing.
            return .failed("invalid barcode")
        case .transport(let reason):
            return .failed(reason)
        }
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
