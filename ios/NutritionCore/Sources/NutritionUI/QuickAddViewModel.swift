import CryptoKit
import Foundation
import NutritionDomain
import NutritionJournal

/// The amounts-only way to log: calories and macros typed straight in, with no product looked up.
///
/// What is saved is the same shape every other entry has, so nothing downstream needs to know about
/// it: one intake holding one serving, with a product snapshot that states the typed values per
/// serving. Today, the journal, the export and the Apple Health plan read it like any label.
///
/// A field left empty is left out of the snapshot, which reads as unknown and never as zero. A typed
/// zero is a real zero and is stored as one.
@MainActor
public final class QuickAddViewModel: ObservableObject, Identifiable {
    public enum Field: String, CaseIterable, Sendable {
        case calories, protein, carbohydrates, fat

        public var label: String {
            switch self {
            case .calories: return "Calories"
            case .protein: return "Protein"
            case .carbohydrates: return "Carbs"
            case .fat: return "Fat"
            }
        }

        public var unit: MeasureUnit { self == .calories ? .kcal : .g }

        /// The key the snapshot stores the value under, the same one a label or barcode snapshot uses.
        var nutrientKey: String {
            switch self {
            case .calories: return LookedUpProduct.energyKcal
            case .protein: return LookedUpProduct.protein
            case .carbohydrates: return LookedUpProduct.carbohydrates
            case .fat: return LookedUpProduct.fat
            }
        }

        /// The most one entry may state. Far above any real meal, and small enough that a slip of the
        /// finger cannot put a day's totals out of reach.
        var maximum: Decimal { self == .calories ? 20_000 : 5_000 }
    }

    enum Parsed: Equatable {
        case blank
        case value(Decimal)
        case invalid
    }

    public static let defaultName = "Quick add"
    /// The one component's id, whatever the entry is called. A slug of the typed name could spell a nutrient
    /// (`Protein` is `protein`), and the relay encoder would then take the serving for that nutrient's fact
    /// and drop the typed value; this id is never a nutrient slug.
    static let componentID = "quick-add"
    public static let nameLimit = 120

    public let id = UUID()
    @Published public var name = ""
    @Published public var caloriesText = ""
    @Published public var proteinText = ""
    @Published public var carbohydratesText = ""
    @Published public var fatText = ""
    @Published public var meal: MealLabel?
    @Published public private(set) var saveError: String?

    private let store: JournalStore
    private let now: () -> Date
    private let timeZoneIdentifier: () -> String
    private let makeID: () -> String

    public init(
        store: JournalStore, meal: MealLabel? = nil,
        now: @escaping () -> Date = { Date() },
        timeZoneIdentifier: @escaping () -> String = { TimeZone.current.identifier },
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.meal = meal
        self.now = now
        self.timeZoneIdentifier = timeZoneIdentifier
        self.makeID = makeID
    }

    public func text(for field: Field) -> String {
        switch field {
        case .calories: return caloriesText
        case .protein: return proteinText
        case .carbohydrates: return carbohydratesText
        case .fat: return fatText
        }
    }

    /// What is wrong with one field, or nil. An empty field is never an error.
    public func error(for field: Field) -> String? {
        guard Self.parse(text(for: field), field: field) == .invalid else { return nil }
        return "Enter a number from 0 to \(DecimalFormatting.text(field.maximum))."
    }

    /// True once every filled field reads as a number and at least one of them is above zero.
    public var canSave: Bool {
        var hasPositive = false
        for field in Field.allCases {
            switch Self.parse(text(for: field), field: field) {
            case .invalid: return false
            case .value(let value): if value > 0 { hasPositive = true }
            case .blank: break
            }
        }
        return hasPositive
    }

    /// Writes one entry and returns the token an undo toast needs, or nil when nothing was written.
    @discardableResult
    public func save() -> AddUndoToken? {
        saveError = nil
        guard canSave else { return nil }
        var nutrients: [String: NutrientValue] = [:]
        for field in Field.allCases {
            guard case .value(let value) = Self.parse(text(for: field), field: field) else { continue }
            nutrients[field.nutrientKey] = .known(value, field.unit)
        }
        let entryName = storedName
        let identity = Self.snapshotIdentity(name: entryName, nutrients: nutrients)
        let date = now()
        let intake = Intake(
            id: makeID(), category: ProductKind.food.rawValue, occurredAt: date,
            timeZoneIdentifier: timeZoneIdentifier(), meal: meal?.rawValue)
        let component = IntakeComponent(
            componentID: Self.componentID, name: entryName, amount: 1, unit: .serving)
        let product = ProductDefinition(
            snapshotID: identity, productID: identity, name: entryName, brand: nil,
            labelBasis: "per serving", catalogOrigin: IntakeContextFactCatalog.quickAddOrigin, catalogVersion: "1",
            kind: .food,
            nutrients: nutrients)
        do {
            try store.create(intake, components: [component], product: product, now: date)
        } catch {
            saveError = "Could not save the entry."
            return nil
        }
        return AddUndoToken(
            intakeID: intake.id, message: "Added \(entryName), \(Self.summary(of: nutrients))",
            expiresAt: date.addingTimeInterval(10))
    }

    /// The typed amounts in field order, such as "250 kcal, 32 g protein". Every quick add is one serving of
    /// its own name, so this is what tells two of them apart wherever they are listed.
    nonisolated static func summary(of nutrients: [String: NutrientValue]) -> String {
        Field.allCases.compactMap { field -> String? in
            guard case .known(let value, let unit) = nutrients[field.nutrientKey] else { return nil }
            let amount = "\(DecimalFormatting.text(value)) \(unit.symbol)"
            return field == .calories ? amount : amount + " " + field.label.lowercased()
        }.joined(separator: ", ")
    }

    /// The snapshot id for one name and set of values. Everything the snapshot states is part of it, so
    /// two quick adds that differ in any way are two products and one id never stands for two contents.
    /// Each field is length-prefixed, so no typed name can read as another field, and the id is a
    /// SHA-256 of that encoding rather than a short checksum.
    static func snapshotIdentity(name: String, nutrients: [String: NutrientValue]) -> String {
        var fields = ["quick-add", name]
        for key in nutrients.keys.sorted() {
            fields.append(key)
            fields.append(LookedUpProduct.describe(nutrients[key] ?? .unknown))
        }
        let encoded = fields.map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(encoded.utf8))
        return "quick-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The typed name, trimmed and capped, or the default when none was typed.
    var storedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultName : String(trimmed.prefix(Self.nameLimit))
    }

    /// Reads one field: digits with at most one separator, zero allowed, never above the field's cap.
    ///
    /// The decimal pad types the region's own digits and separator, so both are read: any decimal digit
    /// (Arabic-Indic `٢` is 2) and the region's separator when it is the only one in the text (`٫` where
    /// that is the separator). A point is accepted everywhere; the comma rule is `AmountParser`'s.
    static func parse(
        _ text: String, field: Field, decimalSeparator: String? = Locale.current.decimalSeparator
    ) -> Parsed {
        var raw = ""
        for scalar in text.trimmingCharacters(in: .whitespaces).unicodeScalars {
            if scalar.properties.numericType == .decimal, let number = scalar.properties.numericValue,
               let digit = Int(exactly: number), (0...9).contains(digit) {
                raw += String(digit)
            } else {
                raw.unicodeScalars.append(scalar)
            }
        }
        if let separator = decimalSeparator, !separator.isEmpty, separator != ".", separator != ",",
           !raw.contains("."), raw.components(separatedBy: separator).count == 2 {
            raw = raw.replacingOccurrences(of: separator, with: ".")
        }
        let typed = AmountParser.normalizedTyped(raw, decimalSeparator: decimalSeparator)
        guard !typed.isEmpty else { return .blank }
        guard typed.count <= 12 else { return .invalid }
        var dots = 0
        var digits = 0
        for character in typed {
            if character == "." {
                dots += 1
            } else if character.isASCII, character.isNumber {
                digits += 1
            } else {
                return .invalid
            }
        }
        guard dots <= 1, digits > 0 else { return .invalid }
        guard let value = Decimal(string: typed, locale: AmountParser.locale), !value.isNaN,
              value >= 0, value <= field.maximum
        else { return .invalid }
        return .value(value)
    }
}
