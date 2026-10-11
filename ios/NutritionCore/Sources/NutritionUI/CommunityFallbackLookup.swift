import Foundation
import NutritionProviders

/// The read side of the community catalog, as the barcode lookup needs it. `CommunityClient` already has
/// this call, so the app passes the client itself.
public protocol CommunityLabelLookup: Sendable {
    func lookupLabel(barcode: String) async throws -> [CommunityLabel]
}

extension CommunityClient: CommunityLabelLookup {}

/// Asks the community catalog about a barcode the primary source did not find.
///
/// Only a `notFound` from the primary source goes on to the catalog, and only for a person who is signed
/// in. Every catalog failure reads as `notFound`, so a catalog problem never shows as a failed lookup.
/// Found, rate-limited and failed answers from the primary source pass through unchanged.
public struct CommunityFallbackLookup: BarcodeProductLookup {
    private let primary: BarcodeProductLookup
    private let community: CommunityLabelLookup
    private let isSignedIn: @MainActor @Sendable () -> Bool

    public init(
        primary: BarcodeProductLookup, community: CommunityLabelLookup,
        isSignedIn: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.primary = primary
        self.community = community
        self.isSignedIn = isSignedIn
    }

    public func lookUp(barcode: String) async -> BarcodeLookupResult {
        let result = await primary.lookUp(barcode: barcode)
        guard case .notFound = result else { return result }
        guard await isSignedIn() else { return .notFound }
        do {
            let labels = try await community.lookupLabel(barcode: barcode)
            guard let product = CommunityLabelMapping.product(barcode: barcode, labels: labels) else {
                return .notFound
            }
            return .found(product)
        } catch {
            // The error is dropped on purpose: its text could carry the request, and the person needs only the outcome.
            return .notFound
        }
    }
}
