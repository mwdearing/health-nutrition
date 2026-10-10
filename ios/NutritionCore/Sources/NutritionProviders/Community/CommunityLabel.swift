import Foundation

/// The basis a label's nutrients are given for. The raw values are the catalog's own.
public enum CommunityBasis: String, Codable, Equatable, Sendable {
    case per100g = "per_100g"
    case per100ml = "per_100ml"
    case perServing = "per_serving"
}

/// What the catalog answered for a submission: kept as received, agreed with other devices, or verified.
public enum CommunitySubmitResult: String, Codable, Equatable, Sendable {
    case received
    case shared
    case verified
}

/// One label a person captured. Energy is kcal, sodium is mg, every other nutrient is grams.
public struct CommunityLabelSubmission: Equatable, Sendable {
    public let barcode: String
    public let basis: CommunityBasis
    public let servingText: String?
    public let productName: String
    public let brand: String?
    /// Keys: energyKcal, protein, carbohydrates, sugars, fat, saturatedFat, fiber, sodium, salt.
    public let nutrients: [String: Decimal]

    public init(
        barcode: String,
        basis: CommunityBasis,
        servingText: String?,
        productName: String,
        brand: String?,
        nutrients: [String: Decimal]
    ) {
        self.barcode = barcode
        self.basis = basis
        self.servingText = servingText
        self.productName = productName
        self.brand = brand
        self.nutrients = nutrients
    }
}

/// A label the community catalog shows for a barcode.
public struct CommunityLabel: Equatable, Sendable {
    public let barcode: String
    public let basis: CommunityBasis
    public let servingText: String?
    public let productName: String
    public let brand: String?
    public let nutrients: [String: Decimal]
    public let verified: Bool
    /// How many accounts agree with this label.
    public let supportingAccounts: Int

    public init(
        barcode: String,
        basis: CommunityBasis,
        servingText: String?,
        productName: String,
        brand: String?,
        nutrients: [String: Decimal],
        verified: Bool,
        supportingAccounts: Int
    ) {
        self.barcode = barcode
        self.basis = basis
        self.servingText = servingText
        self.productName = productName
        self.brand = brand
        self.nutrients = nutrients
        self.verified = verified
        self.supportingAccounts = supportingAccounts
    }
}
