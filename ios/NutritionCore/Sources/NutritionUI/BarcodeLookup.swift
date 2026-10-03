import Foundation
import NutritionDomain

/// What a barcode resolves to. The UI knows the shape of a looked-up product, never where it came
/// from: the app target injects the lookup that fetches it.
public protocol BarcodeProductLookup: Sendable {
    func lookUp(barcode: String) async -> BarcodeLookupResult
}

/// The basis the source states its nutrient values are given on. Nothing is guessed: a source that
/// does not say whether the values are per 100 g or per 100 mL says so here too.
public enum BarcodeLookupBasis: String, Sendable, Hashable, CaseIterable {
    case per100g
    case per100ml
    case per100Unspecified
    case perServing

    /// Short text for the intake form: "per 100 g", "per 100 mL", "per serving".
    public var label: String {
        switch self {
        case .per100g: return "per 100 g"
        case .per100ml: return "per 100 mL"
        case .per100Unspecified: return "per 100 g or mL"
        case .perServing: return "per serving"
        }
    }
}

/// One product found by a barcode lookup. Every value is optional except the barcode: a source that
/// gives no brand leaves it nil rather than inventing one.
public struct LookedUpProduct: Sendable, Hashable {
    public static let energyKcal = "energyKcal"
    public static let protein = "protein"
    public static let carbohydrates = "carbohydrates"
    public static let sugars = "sugars"
    public static let fat = "fat"
    public static let saturatedFat = "saturatedFat"
    public static let fiber = "fiber"
    public static let sodium = "sodium"
    public static let salt = "salt"

    /// The nutrients the intake form can prefill, in display order.
    public static let standardKeys = [
        energyKcal, protein, carbohydrates, sugars, fat, saturatedFat, fiber, sodium, salt,
    ]

    public static let displayNames: [String: String] = [
        energyKcal: "Energy", protein: "Protein", carbohydrates: "Carbohydrates", sugars: "Sugars",
        fat: "Fat", saturatedFat: "Saturated fat", fiber: "Fiber", sodium: "Sodium", salt: "Salt",
    ]

    public let barcode: String
    public let name: String?
    public let brand: String?
    public let basis: BarcodeLookupBasis
    /// A nutrient the source does not give is `.unknown`, never `.known(0, _)`.
    public let nutrients: [String: NutrientValue]

    public init(
        barcode: String, name: String?, brand: String?, basis: BarcodeLookupBasis,
        nutrients: [String: NutrientValue]
    ) {
        self.barcode = barcode
        self.name = name
        self.brand = brand
        self.basis = basis
        var complete: [String: NutrientValue] = [:]
        for key in Self.standardKeys where nutrients[key] == nil {
            complete[key] = .unknown
        }
        self.nutrients = complete.merging(nutrients) { given, _ in given }
    }

    /// The value for one nutrient; a nutrient the source did not give is unknown, never zero.
    public func value(for nutrient: String) -> NutrientValue {
        nutrients[nutrient] ?? .unknown
    }
}

/// The outcome of one lookup. `rateLimited` is its own case because the user is told to try later
/// rather than that something went wrong.
public enum BarcodeLookupResult: Sendable, Equatable {
    case found(LookedUpProduct)
    case notFound
    case rateLimited
    case failed(String)
}

/// Digit and length check for the barcode field: EAN-8, UPC-A or EAN-13, nothing else.
public enum BarcodeShape {
    public static let acceptedLengths = [8, 12, 13]

    public static func isValid(_ barcode: String) -> Bool {
        guard acceptedLengths.contains(barcode.unicodeScalars.count) else { return false }
        return barcode.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }
}
