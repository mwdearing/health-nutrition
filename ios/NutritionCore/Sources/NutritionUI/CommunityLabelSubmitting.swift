import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders

/// The write side of the community catalog, as the intake form needs it. The form never waits for an
/// upload and never shows its outcome: a failed upload is dropped, so it can never change a save.
public protocol CommunityLabelSubmitting: Sendable {
    func submit(_ submission: CommunityLabelSubmission) async
}

extension CommunityClient: CommunityLabelSubmitting {
    public func submit(_ submission: CommunityLabelSubmission) async {
        _ = try? await submitLabel(submission)
    }
}

/// Builds the upload for a label the person captured and saved, or nil when the label must not be uploaded.
///
/// The upload carries values only: the barcode, the basis, the serving text, the name and brand the person
/// settled on, and the nutrients in the catalog's units. The amount eaten, the time, the meal, notes and
/// photos are not inputs here, so they cannot reach the upload.
public enum CommunityLabelUpload {
    /// A label with fewer known values says too little to be worth sharing.
    public static let minimumKnownNutrients = 3

    /// - Parameters:
    ///   - captured: the product the label capture produced, which carries the values and the basis.
    ///   - barcode: the barcode the person typed or scanned, which must pass the shape check.
    ///   - name: the name the person gave the product, trimmed by the caller.
    ///   - brand: the brand the person gave, trimmed here; empty means none.
    ///   - kind: only a food or a drink is shared, never a supplement.
    ///   - serving: the serving the label states, which a per-serving label needs in text.
    public static func submission(
        for captured: ProductDefinition, barcode: String, name: String, brand: String?,
        kind: ProductKind, serving: ServingDefinition?
    ) -> CommunityLabelSubmission? {
        guard captured.catalogOrigin == ProductOrigin.label_capture else { return nil }
        guard kind == .food || kind == .drink else { return nil }
        let productName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !productName.isEmpty else { return nil }
        guard let basis = communityBasis(captured.labelBasis) else { return nil }
        var servingText: String?
        if basis == .perServing {
            let text = serving?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }
            servingText = text
        }
        let nutrients = canonicalNutrients(captured.nutrients)
        guard nutrients.count >= minimumKnownNutrients else { return nil }
        return CommunityLabelSubmission(
            barcode: barcode, basis: basis, servingText: servingText, productName: productName,
            brand: brand?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, nutrients: nutrients)
    }

    /// The catalog's basis for the basis a label capture states. A basis the catalog does not name, such as
    /// one that is per 100 g or mL, is not uploaded.
    static func communityBasis(_ labelBasis: String) -> CommunityBasis? {
        if labelBasis == BarcodeLookupBasis.per100g.label { return .per100g }
        if labelBasis == BarcodeLookupBasis.per100ml.label { return .per100ml }
        let serving = BarcodeLookupBasis.perServing.label
        if labelBasis == serving || labelBasis.hasPrefix(serving + " (") { return .perServing }
        return nil
    }

    /// The known values converted to the catalog's units. A value that is a bound, not an amount, or that does
    /// not convert, is left out rather than guessed.
    static func canonicalNutrients(_ nutrients: [String: NutrientValue]) -> [String: Decimal] {
        var out: [String: Decimal] = [:]
        for key in LookedUpProduct.standardKeys {
            guard case .known(let amount, let unit)? = nutrients[key] else { continue }
            guard let converted = try? Quantity(value: amount, unit: unit).converted(
                to: CommunityLabelMapping.unit(for: key))
            else { continue }
            out[key] = converted.value
        }
        return out
    }
}
