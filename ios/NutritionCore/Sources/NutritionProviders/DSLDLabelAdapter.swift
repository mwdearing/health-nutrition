import Foundation
import NutritionDomain

public enum DSLDAdapterError: Error, Sendable, Equatable {
    /// The bytes are not well-formed JSON.
    case malformedJSON(reason: String, offset: Int)
    /// The document is well-formed JSON but not a JSON object.
    case notAnObject
    /// The label has no usable identifier.
    case missingIdentifier
    /// The label has no `ingredientRows` array.
    case missingIngredientRows
}

/// Turns a recorded NIH DSLD label response into `DSLDSupplementLabel` values.
///
/// The adapter is pure parsing: `Data` in, a label out, no networking. Every amount is read from the
/// literal text of the JSON number it came from and turned into a `Decimal` with `Decimal(string:)`,
/// so no amount ever passes through a binary floating point type.
public struct DSLDLabelAdapter: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> DSLDSupplementLabel {
        let document = try DSLDJSONReader.read(data)
        guard let root = document.objectValue else {
            throw DSLDAdapterError.notAnObject
        }
        guard let identifier = Self.identifier(in: root) else {
            throw DSLDAdapterError.missingIdentifier
        }
        guard let rows = root["ingredientRows"]?.arrayValue else {
            throw DSLDAdapterError.missingIngredientRows
        }

        let brandName = Self.text(in: root, "brandName") ?? ""
        let fullName = Self.text(in: root, "fullName") ?? brandName
        var facts: [CompoundFact] = []
        var blends: [ProprietaryBlend] = []

        for row in rows {
            guard let object = row.objectValue else { continue }
            guard let name = Self.text(in: object, "name"), !name.isEmpty else { continue }
            let substanceIdentifier = Self.text(in: object, "ingredientId") ?? name
            let quantity = Self.servingQuantity(in: object)
            let amount = Self.amount(from: quantity)
            let formName = Self.formName(in: object)
            let rowOrder = Self.text(in: object, "order") ?? "?"

            if let blend = try Self.blend(
                object: object,
                name: name,
                substanceIdentifier: substanceIdentifier,
                rowOrder: rowOrder,
                labelIdentifier: identifier,
                amount: amount
            ) {
                blends.append(blend)
                continue
            }

            // A row that states a form and a mass measures the compound itself; anything else reads as
            // the active nutrient. International units are never treated as a compound mass.
            let isMass = Self.unit(for: Self.unitSymbol(in: quantity))?.dimension == .mass
            let fact = try CompoundFact(
                kind: isMass && formName != nil ? .compound : .nutrient,
                substanceIdentifier: substanceIdentifier,
                labelName: name,
                chemicalForm: formName,
                amount: amount,
                basis: isMass && formName != nil ? .compoundMass : .activeNutrientMass,
                role: isMass && formName != nil ? .compoundMeasurement : .contextOnly,
                provenance: "NIH DSLD label \(identifier), ingredient row \(rowOrder)"
            )
            facts.append(fact)
        }

        return DSLDSupplementLabel(
            id: identifier,
            fullName: fullName,
            brandName: brandName,
            offMarket: root["offMarket"]?.flagValue ?? false,
            servingSizes: Self.servingSizes(in: root),
            facts: facts,
            blends: blends
        )
    }

    // MARK: - Identifier and text

    private static func identifier(in root: [String: DSLDJSON]) -> Int? {
        if let text = root["id"]?.stringValue, let value = Int(text) {
            return value
        }
        if let text = root["id"]?.numberText, let value = Int(text) {
            return value
        }
        return nil
    }

    private static func text(in object: [String: DSLDJSON], _ key: String) -> String? {
        guard let value = object[key]?.stringValue else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func formName(in object: [String: DSLDJSON]) -> String? {
        guard let forms = object["forms"]?.arrayValue else { return nil }
        for form in forms {
            guard let members = form.objectValue, let name = text(in: members, "name") else { continue }
            return name
        }
        return nil
    }

    // MARK: - Serving sizes

    private static func servingSizes(in root: [String: DSLDJSON]) -> [DSLDServingSize] {
        guard let entries = root["servingSizes"]?.arrayValue else { return [] }
        var sizes: [DSLDServingSize] = []
        for entry in entries {
            guard let object = entry.objectValue else { continue }
            guard let minimumText = object["minQuantity"]?.numberText,
                  let minimum = Decimal(string: minimumText, locale: Locale(identifier: "en_US_POSIX")),
                  minimum > 0
            else { continue }
            let maximumText = object["maxQuantity"]?.numberText
            let maximum = maximumText.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) } ?? minimum
            let unitText = object["unit"]?.stringValue ?? ""
            let unit: MeasureUnit = (try? UnitRegistry.unit(for: unitText)) ?? .serving
            sizes.append(
                DSLDServingSize(
                    minimum: Quantity(value: minimum, unit: unit),
                    maximum: Quantity(value: Swift.max(minimum, maximum), unit: unit),
                    unitText: unitText,
                    isFactsPanelServing: object["inSFB"]?.flagValue ?? false
                )
            )
        }
        return sizes
    }

    // MARK: - Ingredient rows

    /// A row repeats its amount once per serving size. The adapter reads the entry for the first
    /// serving size, falling back to the first entry the row carries.
    private static func servingQuantity(in object: [String: DSLDJSON]) -> [String: DSLDJSON]? {
        guard let entries = object["quantity"]?.arrayValue, !entries.isEmpty else { return nil }
        let first = entries[0].objectValue
        let firstOrder = first?["servingSizeOrder"]?.numberText
        if let firstOrder, firstOrder != "1" {
            for entry in entries {
                if entry.objectValue?["servingSizeOrder"]?.numberText == "1" {
                    return entry.objectValue
                }
            }
        }
        return first
    }

    private static func blend(
        object: [String: DSLDJSON],
        name: String,
        substanceIdentifier: String,
        rowOrder: String,
        labelIdentifier: Int,
        amount: NutrientValue
    ) throws -> ProprietaryBlend? {
        let nested = object["nestedRows"]?.arrayValue ?? []
        let isNamedBlend = name.lowercased().contains("proprietary blend")
        guard isNamedBlend || !nested.isEmpty else { return nil }
        var members: [BlendMember] = []
        for entry in nested {
            guard let member = entry.objectValue else { continue }
            guard let memberName = text(in: member, "name") else { continue }
            members.append(
                BlendMember(
                    labelName: memberName,
                    substanceIdentifier: text(in: member, "ingredientId"),
                    amount: amount(from: servingQuantity(in: member))
                )
            )
        }
        return try ProprietaryBlend(
            identifier: "dsld-\(labelIdentifier)-\(substanceIdentifier)",
            labelName: name,
            total: amount,
            basis: .compoundMass,
            members: members,
            provenance: "NIH DSLD label \(labelIdentifier), proprietary blend row \(rowOrder)"
        )
    }

    // MARK: - Amounts

    private static func unitSymbol(in quantity: [String: DSLDJSON]?) -> String? {
        guard let symbol = quantity?["unit"]?.stringValue else { return nil }
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Reads one quantity entry.
    ///
    /// - A missing entry, a missing number, a number of zero and a unit the registry does not carry are
    ///   all `.unknown`. Unknown is never zero: a label that states no amount does not state that the
    ///   amount is nil.
    /// - Only the `=` operator states an exact amount. "less than" becomes
    ///   `.belowReportingThreshold` and any other operator becomes `.unknown`, so a bound never becomes a
    ///   known exact amount. A missing operator is unknown too; it is never assumed to be "=".
    private static func amount(from quantity: [String: DSLDJSON]?) -> NutrientValue {
        guard let quantity else { return .unknown }
        let operatorSymbol = quantity["operator"]?.stringValue
        let symbol = unitSymbol(in: quantity)
        guard let text = quantity["quantity"]?.numberText,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              value > 0
        else { return .unknown }
        if operatorSymbol == "=" {
            guard let symbol, let unit = unit(for: symbol) else { return .unknown }
            return .known(value, unit)
        }
        if operatorSymbol == "<" {
            let thresholdUnit: MeasureUnit? = symbol.flatMap { unit(for: $0) }
            return .belowReportingThreshold(thresholdUnit)
        }
        return .unknown
    }

    /// The units the adapter reads, and nothing else. IU is kept as an international unit: the domain
    /// never converts an international unit to a mass, and this adapter never does either.
    /// Every other unit text DSLD writes, for example "NP", "Gram(s)" or "mcg DFE", has no canonical
    /// registry unit and is read as `.unknown` rather than guessed into one.
    private static func unit(for symbol: String) -> MeasureUnit? {
        let unit: MeasureUnit?
        switch symbol {
        case "mg": unit = .mg
        case "mcg", "\u{00B5}g", "\u{03BC}g": unit = .mcg
        case "g": unit = .g
        case "IU": unit = .iu
        default: unit = nil
        }
        guard let unit, unit.dimension == .mass || unit.dimension == .internationalUnit else { return nil }
        return unit
    }
}