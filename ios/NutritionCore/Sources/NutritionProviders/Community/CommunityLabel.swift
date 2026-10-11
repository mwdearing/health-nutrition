import Foundation

/// The basis a label's nutrients are given for. The raw values are the catalog's own.
public enum CommunityBasis: String, Codable, Equatable, Sendable {
    case per100g = "per_100g"
    case per100ml = "per_100ml"
    case perServing = "per_serving"
}

/// What the catalog answered for a submission. `verified` remains decodable for older server replies.
public enum CommunitySubmitResult: String, Codable, Equatable, Sendable {
    case received
    case shared
    case verified
}

/// The explicit authority behind a label's verification state in lookup_label_v2.
public enum CommunityVerificationSource: String, Codable, Equatable, Sendable {
    case community
    case ownerReviewed = "owner_reviewed"
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
    /// Compatibility bit; only the explicit source controls how the app describes verification.
    public let verified: Bool
    /// How many accounts agree with this label.
    public let supportingAccounts: Int
    /// Explicit source of verification. Community agreement is never verification.
    public let verificationSource: CommunityVerificationSource

    public init(
        barcode: String,
        basis: CommunityBasis,
        servingText: String?,
        productName: String,
        brand: String?,
        nutrients: [String: Decimal],
        verified: Bool,
        supportingAccounts: Int,
        verificationSource: CommunityVerificationSource = .community
    ) {
        self.barcode = barcode
        self.basis = basis
        self.servingText = servingText
        self.productName = productName
        self.brand = brand
        self.nutrients = nutrients
        self.verified = verified
        self.supportingAccounts = supportingAccounts
        self.verificationSource = verificationSource
    }
}
