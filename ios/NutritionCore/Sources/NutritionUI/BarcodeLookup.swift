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

/// Where a displayed value came from. The wording and the link are carried in, never assumed: a
/// source with licence obligations to meet supplies both, and the UI shows them as given. Nothing
/// here names any particular data source.
public struct ProductAttribution: Sendable, Hashable {
    /// A stable identifier for the catalog, stored with an entry so a later reader can tell where
    /// its values came from.
    public let source: String
    /// The sentence a licence requires next to the values.
    public let text: String
    /// Where a reader can read the licence; shown as a link.
    public let url: String

    public init(source: String, text: String, url: String) {
        self.source = source
        self.text = text
        self.url = url
    }
}

/// What one serving is, for values given per serving. Without it "per serving" leaves the numbers
/// ambiguous, because a serving may be 30 g or 250 mL.
///
/// A source may give the size only as text ("1 biscuit"), so the text is enough on its own; the
/// quantity and unit are filled in when the source states them.
public struct ServingDefinition: Sendable, Hashable {
    /// The quantity of one serving, when the source gives a number.
    public let quantity: Decimal?
    public let unit: MeasureUnit?
    /// The source's own wording, such as "30 g" or "1 biscuit", used when it gives one.
    public let text: String?

    public init(quantity: Decimal?, unit: MeasureUnit?, text: String? = nil) {
        self.quantity = quantity
        self.unit = unit
        self.text = text
    }

    /// The source's wording when it has one, otherwise the quantity with its unit. Empty when the
    /// source said nothing at all; an unusable definition is then not shown rather than faked.
    public var label: String {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        guard let quantity else { return "" }
        guard let unit else { return "\(quantity)" }
        return "\(quantity) \(unit.symbol)"
    }

    public var isEmpty: Bool { label.isEmpty }
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
    /// Required attribution for the values above, when the source has any.
    public let attribution: ProductAttribution?
    /// What one serving is; only meaningful when the basis is per serving.
    public let serving: ServingDefinition?
    /// The source's own version or last-modified marker, stored with an entry so a later reader can
    /// tell how fresh the values were.
    public let version: String?

    public init(
        barcode: String, name: String?, brand: String?, basis: BarcodeLookupBasis,
        nutrients: [String: NutrientValue], attribution: ProductAttribution? = nil,
        serving: ServingDefinition? = nil, version: String? = nil
    ) {
        self.barcode = barcode
        self.name = name
        self.brand = brand
        self.basis = basis
        self.attribution = attribution
        self.serving = serving
        self.version = version
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

    /// A stable id for a snapshot of this product. It covers every field that gets stored, including
    /// the name and brand the user settled on, so saving the same product twice under two different
    /// names gives two different ids and neither is mistaken for the other.
    public func snapshotIdentity(name: String, brand: String?, kind: ProductKind = .food) -> String {
        var signature = barcode + "|" + basis.rawValue + "|" + (version ?? "")
        signature += "|name=" + name
        signature += "|brand=" + (brand ?? "")
        signature += "|kind=" + kind.rawValue
        if let serving {
            signature += "|serving=" + serving.label
        }
        if let attribution {
            signature += "|source=" + attribution.source
        }
        for key in Self.standardKeys {
            signature += "|" + key + "=" + Self.describe(value(for: key))
        }
        return "lookup-" + AddIntakeViewModel.slug(signature) + "-" + Self.checksum(signature)
    }

    /// The basis as it is stored with an entry, with the serving spelled out when there is one, so a
    /// reader of the journal sees "per serving (30 g)" rather than a bare "per serving".
    public var labelBasis: String {
        guard basis == .perServing, let serving else { return basis.label }
        return "\(basis.label) (\(serving.label))"
    }

    /// One line per nutrient for the form and for a stable signature. Unknown is spelled out, never
    /// rendered as zero.
    static func describe(_ value: NutrientValue) -> String {
        switch value {
        case .known(let amount, let unit):
            return "\(NSDecimalNumber(decimal: amount).stringValue) \(unit.symbol)"
        case .unknown:
            return "unknown"
        case .notApplicable:
            return "not applicable"
        case .belowReportingThreshold(let unit):
            return "below reporting threshold" + (unit.map { " \($0.symbol)" } ?? "")
        }
    }

    /// FNV-1a over the signature, as eight lowercase hex digits. A checksum only has to keep two
    /// different products apart; it is not a security or integrity measure.
    static func checksum(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(text.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        let folded = (hash & 0xffff_ffff) ^ (hash >> 32)
        let value = folded & 0xffff_ffff
        let digits = "0123456789abcdef"
        var out = ""
        for shift in stride(from: 28, through: 0, by: -4) {
            out.append(digits[digits.index(digits.startIndex, offsetBy: Int((value >> UInt64(shift)) & 0xf))])
        }
        return out
    }
}

/// The outcome of one lookup. `rateLimited` carries how long the source asked the caller to wait, so
/// the user is not told to retry before the source will answer.
public enum BarcodeLookupResult: Sendable, Equatable {
    case found(LookedUpProduct)
    case notFound
    case rateLimited(retryAfterSeconds: Int?)
    case failed(String)
}

/// Digit, length and GS1 check digit check for the barcode field: EAN-8, UPC-A or EAN-13, nothing
/// else. This is the same rule the provider applies, so a barcode rejected here would have been
/// rejected there too, and the user is told so before any request is attempted.
public enum BarcodeShape {
    public static let acceptedLengths = [8, 12, 13]

    public static func isValid(_ barcode: String) -> Bool {
        let digits = barcode.unicodeScalars.map { Int($0.value) - 48 }
        guard acceptedLengths.contains(digits.count) else { return false }
        guard digits.allSatisfy({ $0 >= 0 && $0 <= 9 }) else { return false }
        // Weight 3, 1, 3, 1... from the rightmost digit before the check digit.
        var sum = 0
        for (offset, digit) in digits.dropLast().reversed().enumerated() {
            sum += digit * (offset.isMultiple(of: 2) ? 3 : 1)
        }
        return (10 - sum % 10) % 10 == digits[digits.count - 1]
    }

    /// Whether two codes stand for the same product. A UPC-A of 12 digits is written as a GTIN-13
    /// with a leading zero, and a source may answer with that 13-digit form for a 12-digit request;
    /// leading zeros are therefore not part of a code's identity.
    public static func areEquivalent(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        return normalize(left) == normalize(right)
    }

    /// The code without leading zeros, so "0500011263796" and "500011263796" are the same code.
    public static func normalize(_ barcode: String) -> String {
        var digits = Substring(barcode)
        while digits.count > 1, digits.first == "0" {
            digits = digits.dropFirst()
        }
        return String(digits)
    }
}
