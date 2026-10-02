import Foundation
import NutritionDomain

public enum OpenFoodFactsBasis: String, Sendable, Hashable {
    case per100g
    case perServing
}

public struct OpenFoodFactsProduct: Sendable, Hashable {
    public static let energyKcal = "energyKcal"
    public static let protein = "protein"
    public static let carbohydrates = "carbohydrates"
    public static let sugars = "sugars"
    public static let fat = "fat"
    public static let saturatedFat = "saturatedFat"
    public static let fiber = "fiber"
    public static let sodium = "sodium"
    public static let salt = "salt"

    public let barcode: String
    public let name: String?
    public let brands: String?
    public let servingSize: String?
    public let servingQuantity: Decimal?
    public let basis: OpenFoodFactsBasis
    public let lastModified: Date?
    /// Always holds every key above; a nutriment the source does not give is `.unknown`, never zero.
    public let nutrients: [String: NutrientValue]

    public init(
        barcode: String,
        name: String?,
        brands: String?,
        servingSize: String?,
        servingQuantity: Decimal?,
        basis: OpenFoodFactsBasis,
        lastModified: Date?,
        nutrients: [String: NutrientValue]
    ) {
        self.barcode = barcode
        self.name = name
        self.brands = brands
        self.servingSize = servingSize
        self.servingQuantity = servingQuantity
        self.basis = basis
        self.lastModified = lastModified
        self.nutrients = nutrients
    }
}

public enum OpenFoodFactsOutcome: Sendable, Equatable {
    case found(OpenFoodFactsProduct)
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case invalidBarcode
    case transport(String)
}

// MARK: - Decoding

/// A JSON scalar that may arrive as a number or as text. Numbers are read as Decimal, never as Double.
struct OpenFoodFactsScalar: Decodable {
    let text: String?
    let decimal: Decimal?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string
            decimal = OpenFoodFactsScalar.parse(string)
        } else if let number = try? container.decode(Decimal.self) {
            text = nil
            decimal = number
        } else {
            text = nil
            decimal = nil
        }
    }

    private static func parse(_ raw: String) -> Decimal? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ "0123456789.-+".contains($0) }),
              trimmed.filter({ $0 == "." }).count <= 1
        else {
            return nil
        }
        return Decimal(string: trimmed, locale: nil)
    }
}

struct OpenFoodFactsResponse: Decodable {
    struct Result: Decodable {
        let id: String?
    }

    struct Body: Decodable {
        let code: OpenFoodFactsScalar?
        let product_name: OpenFoodFactsScalar?
        let brands: OpenFoodFactsScalar?
        let serving_size: OpenFoodFactsScalar?
        let serving_quantity: OpenFoodFactsScalar?
        let nutrition_data_per: OpenFoodFactsScalar?
        let nutriments: [String: OpenFoodFactsScalar]?
        let last_modified_t: OpenFoodFactsScalar?
    }

    let result: Result?
    let product: Body?
}

extension OpenFoodFactsProduct {
    private static let mapping: [(key: String, source: String, energy: Bool)] = [
        (energyKcal, "energy-kcal", true),
        (protein, "proteins", false),
        (carbohydrates, "carbohydrates", false),
        (sugars, "sugars", false),
        (fat, "fat", false),
        (saturatedFat, "saturated-fat", false),
        (fiber, "fiber", false),
        (sodium, "sodium", false),
        (salt, "salt", false),
    ]

    init(body: OpenFoodFactsResponse.Body, requestedBarcode: String) {
        let basis: OpenFoodFactsBasis = body.nutrition_data_per?.text == "serving" ? .perServing : .per100g
        let suffix = basis == .perServing ? "_serving" : "_100g"
        let source = body.nutriments ?? [:]
        var nutrients: [String: NutrientValue] = [:]
        for entry in Self.mapping {
            nutrients[entry.key] = Self.value(
                amount: source[entry.source + suffix]?.decimal,
                unitText: source[entry.source + "_unit"]?.text,
                energy: entry.energy
            )
        }
        let modified: Date? = body.last_modified_t?.decimal.map {
            Date(timeIntervalSince1970: NSDecimalNumber(decimal: $0).doubleValue)
        }
        self.init(
            barcode: body.code?.text ?? requestedBarcode,
            name: body.product_name?.text,
            brands: body.brands?.text,
            servingSize: body.serving_size?.text,
            servingQuantity: body.serving_quantity?.decimal,
            basis: basis,
            lastModified: modified,
            nutrients: nutrients
        )
    }

    private static func value(amount: Decimal?, unitText: String?, energy: Bool) -> NutrientValue {
        guard let amount, amount >= 0 else {
            return .unknown
        }
        let unit: MeasureUnit
        if let unitText {
            guard let resolved = resolve(unitText) else {
                return .unknown
            }
            unit = resolved
        } else if energy {
            unit = .kcal
        } else {
            return .unknown
        }
        let expected: UnitDimension = energy ? .energy : .mass
        guard unit.dimension == expected else {
            return .unknown
        }
        return .known(amount, unit)
    }

    private static func resolve(_ text: String) -> MeasureUnit? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "\u{00B5}g", "\u{03BC}g", "mcg", "ug":
            return .mcg
        default:
            return try? UnitRegistry.unit(for: trimmed.lowercased())
        }
    }
}
