import Foundation
import NutritionDomain

public enum OpenFoodFactsBasis: String, Sendable, Hashable {
    case per100g
    case per100ml
    /// 100 g or 100 ml, the source does not say.
    case per100Unspecified
    case perServing

    /// `nutrition_data_per == "serving"` means per serving. Otherwise only `product_quantity_unit`
    /// decides: "ml" gives per 100 ml, "g" gives per 100 g, anything else or missing is unspecified.
    static func decide(dataPer: String?, quantityUnit: String?) -> OpenFoodFactsBasis {
        if dataPer == "serving" {
            return .perServing
        }
        switch quantityUnit?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "ml":
            return .per100ml
        case "g":
            return .per100g
        default:
            return .per100Unspecified
        }
    }
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
        var complete = nutrients
        for key in Self.standardKeys where complete[key] == nil {
            complete[key] = .unknown
        }
        self.nutrients = complete
    }

    public static let standardKeys = [
        energyKcal, protein, carbohydrates, sugars, fat, saturatedFat, fiber, sodium, salt,
    ]
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

    /// Accepts only [+-]?digits(.digits)?; anything else is nil.
    static func parse(_ raw: String) -> Decimal? {
        var scalars = Array(raw.unicodeScalars)
        if let first = scalars.first, first == "+" || first == "-" {
            scalars.removeFirst()
        }
        func isDigit(_ scalar: Unicode.Scalar) -> Bool {
            scalar.value >= 48 && scalar.value <= 57
        }
        let parts = scalars.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard scalars.filter({ $0 == "." }).count <= 1,
              !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isDigit) })
        else {
            return nil
        }
        return Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX"))
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
        let product_quantity_unit: OpenFoodFactsScalar?
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
        let basis = OpenFoodFactsBasis.decide(dataPer: body.nutrition_data_per?.text, quantityUnit: body.product_quantity_unit?.text)
        let suffix = basis == .perServing ? "_serving" : "_100g"
        let source = body.nutriments ?? [:]
        var nutrients: [String: NutrientValue] = [:]
        for entry in Self.mapping {
            nutrients[entry.key] = Self.value(
                amount: source[entry.source + suffix]?.decimal,
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

    /// Open Food Facts normalises `<key>_100g` and `<key>_serving` to canonical units (kcal for
    /// energy, grams for everything else); `<key>_unit` only describes the entered unit and is ignored.
    private static func value(amount: Decimal?, energy: Bool) -> NutrientValue {
        guard let amount, amount >= 0 else {
            return .unknown
        }
        return .known(amount, energy ? .kcal : .g)
    }
}
