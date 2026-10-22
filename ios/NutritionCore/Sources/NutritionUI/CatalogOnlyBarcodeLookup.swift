import Foundation
import NutritionProviders

/// Answers a barcode with nothing found. Used as the primary of the catalog lookup, so the only place a barcode can
/// resolve is the community catalog, and Open Food Facts is never asked about a barcode.
struct NoBarcodeLookup: BarcodeProductLookup {
    public init() {}

    public func lookUp(barcode: String) async -> BarcodeLookupResult {
        .notFound
    }
}

/// Barcodes resolve through the community catalog only. Without a catalog there is nothing to ask, so the answer is
/// not found; with one, a signed-in person's barcode is asked of the catalog and nothing else.
public enum CatalogOnlyBarcodeLookup {
    public static func make(
        community: CommunityLabelLookup?, isSignedIn: (@MainActor @Sendable () -> Bool)?
    ) -> BarcodeProductLookup {
        guard let community, let isSignedIn else { return NoBarcodeLookup() }
        return CommunityFallbackLookup(primary: NoBarcodeLookup(), community: community, isSignedIn: isSignedIn)
    }
}
