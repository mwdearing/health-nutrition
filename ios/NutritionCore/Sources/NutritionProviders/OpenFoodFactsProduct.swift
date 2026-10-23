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

extension OpenFoodFactsBasis {
    private static let massUnits: Set<String> = [
        "g", "gr", "grs", "gram", "grams", "gramm", "kg", "kgs", "kilo", "kilos", "mg", "oz", "ozs", "lb", "lbs",
        "pound", "pounds",
    ]
    private static let volumeUnits: Set<String> = [
        "ml", "mls", "cl", "dl", "l", "lt", "ltr", "litre", "litres", "liter", "liters", "cc", "gal", "gallon",
        "gallons", "qt", "quart", "quarts", "pt", "pint", "pints", "fl",
    ]

    /// Reads the pack quantity ("1 gallon", "400 g", "32 fl oz (946 ml)", "6 x 125 g"). Only a unit
    /// written right after a number counts. Masses only give per 100 g, volumes only per 100 mL, and a
    /// mix of both, or no unit at all, stays unspecified rather than guessed. "fl oz" is a volume: "fl"
    /// follows the number, and the "oz" after it does not.
    static func fromPackQuantity(_ text: String?) -> OpenFoodFactsBasis {
        guard let text else { return .per100Unspecified }
        var tokens: [String] = []
        var current = ""
        var currentIsNumber = false
        for character in text.lowercased() {
            let isNumber = character.isNumber || ((character == "." || character == "," || character == "/") && currentIsNumber)
            if character.isLetter || isNumber {
                if !current.isEmpty && isNumber != currentIsNumber {
                    tokens.append(current)
                    current = ""
                }
                current.append(character)
                currentIsNumber = isNumber
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = ""
                currentIsNumber = false
            }
        }
        if !current.isEmpty { tokens.append(current) }
        var mass = false
        var volume = false
        var previous: String?
        for token in tokens {
            defer { previous = token }
            guard let before = previous else { continue }
            let afterNumber = before.first?.isNumber == true
            if afterNumber && massUnits.contains(token) { mass = true }
            if afterNumber && volumeUnits.contains(token) { volume = true }
        }
        if mass && !volume { return .per100g }
        if volume && !mass { return .per100ml }
        return .per100Unspecified
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

/// Text that may arrive as one string or as a list of strings; a list is joined with ", ".
struct OpenFoodFactsTextList: Decodable {
    let text: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            text = trimmed.isEmpty ? nil : trimmed
        } else if let list = try? container.decode([OpenFoodFactsScalar].self) {
            // Entries that are not text (null, numbers) are skipped rather than losing the whole list.
            let parts = list.compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            text = parts.isEmpty ? nil : parts.joined(separator: ", ")
        } else {
            text = nil
        }
    }
}

/// A reply from the full-text search service. Its index holds names, brands and per-100 figures, but
/// not the serving or whether a product is measured in grams or millilitres.
struct OpenFoodFactsSearchResponse: Decodable {
    /// A field of the wrong shape is read as missing, so one odd hit cannot fail the whole reply.
    struct Hit: Decodable {
        let code: OpenFoodFactsScalar?
        let product_name: OpenFoodFactsScalar?
        let brands: OpenFoodFactsTextList?
        let nutriments: [String: OpenFoodFactsScalar]?
        let last_modified_t: OpenFoodFactsScalar?
        let product_quantity_unit: OpenFoodFactsScalar?
        let quantity: OpenFoodFactsScalar?
        /// True for a product Open Food Facts marks as discontinued or withdrawn; current products omit it.
        let obsolete: Bool

        enum CodingKeys: String, CodingKey {
            case code, product_name, brands, nutriments, last_modified_t, product_quantity_unit, quantity, obsolete
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try? container.decodeIfPresent(OpenFoodFactsScalar.self, forKey: .code)
            product_name = try? container.decodeIfPresent(OpenFoodFactsScalar.self, forKey: .product_name)
            brands = try? container.decodeIfPresent(OpenFoodFactsTextList.self, forKey: .brands)
            nutriments = try? container.decodeIfPresent([String: OpenFoodFactsScalar].self, forKey: .nutriments)
            last_modified_t = try? container.decodeIfPresent(OpenFoodFactsScalar.self, forKey: .last_modified_t)
            product_quantity_unit = try? container.decodeIfPresent(OpenFoodFactsScalar.self, forKey: .product_quantity_unit)
            quantity = try? container.decodeIfPresent(OpenFoodFactsScalar.self, forKey: .quantity)
            if let flag = try? container.decodeIfPresent(Bool.self, forKey: .obsolete) {
                obsolete = flag
            } else if let text = (try? container.decodeIfPresent(OpenFoodFactsScalar.self, forKey: .obsolete))??.text {
                obsolete = ["true", "on", "1", "yes"].contains(text.lowercased())
            } else {
                obsolete = false
            }
        }
    }

    /// One entry of `hits`; an entry that is not an object at all is read as no hit.
    struct Entry: Decodable {
        let hit: Hit?

        init(from decoder: Decoder) throws {
            hit = try? Hit(from: decoder)
        }
    }

    let hits: [Entry]?
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

    /// A search result. The figures are per 100 and there is no serving. Whether that is 100 g or 100 mL comes
    /// from the unit when the index has it, else from the pack quantity, else it stays
    /// unresolved.
    init(hit: OpenFoodFactsSearchResponse.Hit, barcode: String, name: String) {
        let stated = OpenFoodFactsBasis.decide(dataPer: nil, quantityUnit: hit.product_quantity_unit?.text)
        let basis = stated != .per100Unspecified ? stated : OpenFoodFactsBasis.fromPackQuantity(hit.quantity?.text)
        let source = hit.nutriments ?? [:]
        var nutrients: [String: NutrientValue] = [:]
        for entry in Self.mapping {
            nutrients[entry.key] = Self.value(amount: source[entry.source + "_100g"]?.decimal, energy: entry.energy)
        }
        self.init(
            barcode: barcode,
            name: name,
            brands: hit.brands?.text,
            servingSize: nil,
            servingQuantity: nil,
            basis: basis,
            lastModified: hit.last_modified_t?.decimal.map {
                Date(timeIntervalSince1970: NSDecimalNumber(decimal: $0).doubleValue)
            },
            nutrients: nutrients
        )
    }

    /// Open Food Facts normalizes `<key>_100g` and `<key>_serving` to canonical units (kcal for
    /// energy, grams for everything else); `<key>_unit` only describes the entered unit and is ignored.
    private static func value(amount: Decimal?, energy: Bool) -> NutrientValue {
        guard let amount, amount >= 0 else {
            return .unknown
        }
        return .known(amount, energy ? .kcal : .g)
    }
}
