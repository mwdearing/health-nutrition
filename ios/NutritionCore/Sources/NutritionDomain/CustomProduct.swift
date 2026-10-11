import Foundation

public enum ProductBasis: String, Sendable, Hashable, Codable {
    case per100g = "per_100_g"
    case per100mL = "per_100_ml"
    case perServing = "per_serving"
}

public struct ProductServing: Sendable, Hashable, Codable {
    public let quantity: Decimal
    public let unit: MeasureUnit
    public let text: String?
    public init(quantity: Decimal, unit: MeasureUnit, text: String? = nil) {
        self.quantity = quantity; self.unit = unit; self.text = text
    }
}

public struct ProductFact: Sendable, Hashable, Codable {
    public let key: String
    public let displayName: String
    public let value: NutrientValue
    public init(key: String, displayName: String, value: NutrientValue) {
        self.key = key; self.displayName = displayName; self.value = value
    }
}

/// Display facts remain as entered. Wire encoding is defined by shared-products-v2,
/// rather than the synthesized local Codable representation of these domain values.
public struct CustomProductContent: Sendable, Hashable, Codable {
    public let name: String
    public let brand: String?
    public let barcode: String?
    public let kind: ProductKind
    public let basis: ProductBasis
    public let serving: ProductServing?
    public let facts: [ProductFact]
    public init(name: String, brand: String? = nil, barcode: String? = nil, kind: ProductKind, basis: ProductBasis, serving: ProductServing? = nil, facts: [ProductFact] = []) {
        self.name = name; self.brand = brand; self.barcode = barcode; self.kind = kind
        self.basis = basis; self.serving = serving; self.facts = facts
    }
}

/// Attribution is public display text, never an account identifier or ownership proof.
public struct CommunityProductSource: Sendable, Hashable, Codable {
    public let productID: UUID
    public let representativeRevision: String
    public let attribution: String
    public init(productID: UUID, representativeRevision: String, attribution: String) {
        self.productID = productID; self.representativeRevision = representativeRevision; self.attribution = attribution
    }
}

public struct CustomProductRevision: Sendable, Hashable, Codable {
    public let localProductID: UUID
    public let revisionID: UUID
    public let content: CustomProductContent
    public let source: CommunityProductSource?
    public init(localProductID: UUID, revisionID: UUID, content: CustomProductContent, source: CommunityProductSource? = nil) {
        self.localProductID = localProductID; self.revisionID = revisionID; self.content = content; self.source = source
    }
}
