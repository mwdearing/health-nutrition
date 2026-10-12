import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders

public enum CustomProductMappingError: Error { case requiresExplicitChoices, unsupportedLegacyFact, unresolvedBasis, sourcedIdentityIsFixed }

/// An editor staging value, never a saved strict revision. The original source remains available
/// while the person resolves missing choices; a historical snapshot cannot reconstruct lost facts.
public struct LegacyCustomProductDraft: Sendable {
    public var historicalIntakeReference: [String] = []
    public let originalSnapshot: ProductDefinition?
    public let legacyLabel: LegacyProductLabel?
    public let source: CommunityProductSource?
    public let name: String
    public let brand: String?
    public let barcode: String?
    public let kind: ProductKind?
    public let basis: ProductBasis?
    public let serving: ProductServing?
    public let rawServingText: String?
    public let facts: [ProductFact]

    public func completed(kind: ProductKind, basis: ProductBasis, serving: ProductServing?,
                          localProductID: UUID = UUID(), revisionID: UUID = UUID()) throws -> CustomProductRevision {
        let resolvedServing = serving.map { ProductServing(quantity: $0.quantity, unit: $0.unit, text: rawServingText ?? $0.text) }
        // A raw legacy serving cannot be silently discarded when resolving the draft.
        if rawServingText != nil && resolvedServing == nil { throw CustomProductMappingError.requiresExplicitChoices }
        let content = CustomProductContent(name: name, brand: brand, barcode: barcode, kind: kind,
            basis: basis, serving: resolvedServing, facts: facts)
        try CustomProductValidation.validate(content)
        return CustomProductRevision(localProductID: localProductID, revisionID: revisionID, content: content, source: source)
    }
}

public enum CustomProductMapping {
    /// Deliberate repair of one selected manual template. Intake quantities are reference only.
    public static func legacyDraft(from template: RepeatTemplate) throws -> LegacyCustomProductDraft {
        guard template.productSnapshotID == nil, ["food", "supplement"].contains(template.category),
              !template.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CustomProductMappingError.requiresExplicitChoices
        }
        var draft = LegacyCustomProductDraft(originalSnapshot: nil, legacyLabel: nil, source: nil,
            name: template.displayName, brand: nil, barcode: nil, kind: nil, basis: nil,
            serving: nil, rawServingText: nil, facts: [])
        draft.historicalIntakeReference = template.components.map {
            "\($0.name): \(NSDecimalNumber(decimal: $0.amount).stringValue) \($0.unit.symbol) consumed"
        }
        return draft
    }
    public static func snapshot(for revision: CustomProductRevision) throws -> ProductDefinition {
        try CustomProductValidation.validate(revision.content)
        let content = revision.content
        let basis: String
        switch content.basis {
        case .per100g: basis = "per 100 g"
        case .per100mL: basis = "per 100 mL"
        case .perServing:
            if let serving = content.serving {
                basis = "per serving (\(NSDecimalNumber(decimal: serving.quantity).stringValue) \(serving.unit.symbol))"
            } else { basis = "per serving" }
        }
        var nutrients: [String: NutrientValue] = [:], names: [String: String] = [:]
        for fact in content.facts {
            let key = snapshotKey(fact.key)
            nutrients[key] = fact.value; names[key] = fact.displayName
        }
        return ProductDefinition(snapshotID: revision.revisionID.uuidString, productID: revision.localProductID.uuidString,
            name: content.name, brand: content.brand, barcode: content.barcode, labelBasis: basis,
            catalogOrigin: "custom", catalogVersion: revision.revisionID.uuidString, kind: content.kind,
            nutrients: nutrients, nutrientDisplayNames: names)
    }

    public static func importedRevision(from product: CommunityProduct) throws -> CustomProductRevision {
        guard case .custom(let content) = product.product else { throw CustomProductMappingError.requiresExplicitChoices }
        guard product.source.productID == product.productID,
              product.source.representativeRevision == product.representativeRevision else { throw CustomProductMappingError.requiresExplicitChoices }
        let imported = try content.domainContent(), source = product.source.domainSource
        let evidence = ImportedProductVerification(source: source, content: imported,
            ownerReviewed: product.verification.status == .verified && product.verification.source == "owner_reviewed")
        return CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: imported, source: source, importVerification: evidence)
    }

    public static func stagedDraft(from product: CommunityProduct) throws -> LegacyCustomProductDraft {
        guard case .legacyLabel(let label) = product.product else { throw CustomProductMappingError.requiresExplicitChoices }
        let facts = try label.nutrients.keys.sorted().map { key -> ProductFact in
            guard let amount = label.nutrients[key], CustomProductValidation.standardDimensions[key] != nil || key == "salt" else {
                throw CustomProductMappingError.unsupportedLegacyFact
            }
            return ProductFact(key: key == "salt" ? "ingredient:salt" : key, displayName: key == "salt" ? "Salt" : key,
                value: .known(amount, key == "energyKcal" ? .kcal : key == "sodium" ? .mg : .g))
        }
        let serving: ProductServing?
        if let value = label.serving {
            guard let quantity = Decimal(string: value.quantity, locale: Locale(identifier: "en_US_POSIX")) else { throw CustomProductMappingError.requiresExplicitChoices }
            serving = ProductServing(quantity: quantity, unit: value.unit, text: label.rawServingText ?? value.text)
        } else { serving = nil }
        return LegacyCustomProductDraft(originalSnapshot: nil, legacyLabel: label, source: product.source.domainSource,
            name: label.name, brand: label.brand, barcode: label.barcode, kind: label.kind,
            basis: label.basis == .per100g ? .per100g : label.basis == .per100ml ? .per100mL : .perServing,
            serving: serving, rawServingText: label.rawServingText, facts: facts)
    }

    public static func legacyDraft(from snapshot: ProductDefinition) throws -> LegacyCustomProductDraft {
        let basis: ProductBasis?
        switch IntakeContextSnapshotBasis.parse(snapshot.labelBasis) {
        case .perHundred(.g): basis = .per100g
        case .perHundred(.mL): basis = .per100mL
        case .perCount(.serving): basis = .perServing
        default: basis = nil
        }
        let quantity = IntakeContextSnapshotBasis.statedServingQuantity(snapshot.labelBasis)
        let serving = quantity.map { ProductServing(quantity: $0.value, unit: $0.unit, text: snapshot.labelBasis) }
        let facts = try snapshot.nutrients.keys.sorted().map { key -> ProductFact in
            let raw: String
            if key.hasPrefix("customfact_utf8_") {
                raw = try rawFactKey(key)
            } else if CustomProductValidation.standardDimensions[key] != nil { raw = key }
            else { raw = "ingredient:" + key }
            return ProductFact(key: raw, displayName: snapshot.nutrientDisplayNames[key] ?? key, value: snapshot.nutrients[key]!)
        }
        // Legacy ProductDefinition.kind may be the old implicit food fallback. Require explicit choice.
        return LegacyCustomProductDraft(originalSnapshot: snapshot, legacyLabel: nil, source: nil,
            name: snapshot.name, brand: snapshot.brand, barcode: snapshot.barcode, kind: snapshot.kind == .food ? nil : snapshot.kind, basis: basis,
            serving: serving, rawServingText: basis == .perServing ? snapshot.labelBasis : nil, facts: facts)
    }

    private static func snapshotKey(_ raw: String) -> String {
        guard raw.utf8.starts(with: "ingredient:".utf8) else { return raw }
        return "customfact_utf8_" + raw.utf8.map { String(format: "%02x", $0) }.joined()
    }
    private static func rawFactKey(_ key: String) throws -> String {
        let hex = Array(key.dropFirst("customfact_utf8_".count))
        guard hex.count.isMultiple(of: 2) else { throw CustomProductMappingError.unsupportedLegacyFact }
        var bytes = [UInt8]()
        for i in stride(from: 0, to: hex.count, by: 2) {
            guard let byte = UInt8(String(hex[i...i + 1]), radix: 16) else { throw CustomProductMappingError.unsupportedLegacyFact }
            bytes.append(byte)
        }
        guard let raw = String(bytes: bytes, encoding: .utf8), raw.utf8.starts(with: "ingredient:".utf8) else { throw CustomProductMappingError.unsupportedLegacyFact }
        return raw
    }
}
