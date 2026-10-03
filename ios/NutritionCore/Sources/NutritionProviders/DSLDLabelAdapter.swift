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
        let servingSizes = Self.servingSizes(in: root)
        let orders = Self.servingOrders(in: root, sizes: servingSizes)

        // DSLD states every ingredient row once per serving size. The label therefore keeps one set of
        // facts and blends per serving size instead of only the first one, so an amount is never read
        // with the serving size it does not belong to.
        var servings: [DSLDServingFacts] = []
        for order in orders {
            let parsed = try Self.rows(in: rows, labelIdentifier: identifier, servingOrder: order, firstOrder: orders[0])
            servings.append(
                DSLDServingFacts(
                    order: order,
                    servingSize: servingSizes.first { $0.order == order },
                    facts: parsed.facts,
                    blends: parsed.blends
                )
            )
        }
        let primary = servings[0]

        return DSLDSupplementLabel(
            id: identifier,
            fullName: fullName,
            brandName: brandName,
            offMarket: root["offMarket"]?.flagValue ?? false,
            servingSizes: servingSizes,
            facts: primary.facts,
            blends: primary.blends,
            servings: servings
        )
    }

    /// Reads every ingredient row for one serving size.
    private static func rows(
        in rows: [DSLDJSON],
        labelIdentifier: Int,
        servingOrder: Int,
        firstOrder: Int
    ) throws -> (facts: [CompoundFact], blends: [ProprietaryBlend]) {
        var facts: [CompoundFact] = []
        var blends: [ProprietaryBlend] = []
        for row in rows {
            guard let object = row.objectValue else { continue }
            guard let name = Self.text(in: object, "name"), !name.isEmpty else { continue }
            let substanceIdentifier = Self.literalText(in: object, "ingredientId") ?? name
            let amount = Self.amount(from: quantityEntry(in: object, for: servingOrder, firstOrder: firstOrder))
            let formName = Self.formName(in: object)
            let rowOrder = Self.literalText(in: object, "order") ?? "?"

            if let blend = try Self.blend(
                object: object,
                name: name,
                substanceIdentifier: substanceIdentifier,
                rowOrder: rowOrder,
                labelIdentifier: labelIdentifier,
                amount: amount,
                servingOrder: servingOrder
            ) {
                blends.append(blend)
                continue
            }

            facts.append(
                try Self.fact(
                    name: name,
                    substanceIdentifier: substanceIdentifier,
                    formName: formName,
                    amount: amount,
                    provenance: "NIH DSLD label \(labelIdentifier), ingredient row \(rowOrder), serving size \(servingOrder)"
                )
            )

            // A nested row of an ordinary nutrient is a row of its own: the parent stays a fact and the
            // child becomes a fact as well, so no nutrient is lost to blend semantics.
            for nested in object["nestedRows"]?.arrayValue ?? [] {
                guard let member = nested.objectValue else { continue }
                guard let memberName = Self.text(in: member, "name") else { continue }
                facts.append(
                    try Self.fact(
                        name: memberName,
                        substanceIdentifier: Self.literalText(in: member, "ingredientId") ?? memberName,
                        formName: Self.formName(in: member),
                        amount: Self.amount(
                            from: quantityEntry(in: member, for: servingOrder, firstOrder: firstOrder)
                        ),
                        provenance: "NIH DSLD label \(labelIdentifier), ingredient row \(rowOrder), nested row "
                            + (Self.literalText(in: member, "order") ?? "?")
                            + ", serving size \(servingOrder)"
                    )
                )
            }
        }
        return (facts, blends)
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

    /// The text of a field DSLD writes as a JSON number or as a string, for example `ingredientId` and
    /// `order`. A numeric literal keeps its own text, so the identifier stays the DSLD identifier
    /// instead of falling back to a display name.
    private static func literalText(in object: [String: DSLDJSON], _ key: String) -> String? {
        if let text = text(in: object, key) {
            return text
        }
        guard let number = object[key]?.numberText else { return nil }
        return number.isEmpty ? nil : number
    }

    /// A listed ingredient row. DSLD states the amount of the nutrient on the Supplement Facts panel and
    /// gives the source form in `forms`; the form is kept as `chemicalForm` and does not turn the amount
    /// into a compound mass, so active-nutrient totals include ordinary vitamins and minerals.
    private static func fact(
        name: String,
        substanceIdentifier: String,
        formName: String?,
        amount: NutrientValue,
        provenance: String
    ) throws -> CompoundFact {
        try CompoundFact(
            kind: .nutrient,
            substanceIdentifier: substanceIdentifier,
            labelName: name,
            chemicalForm: formName,
            amount: amount,
            basis: .activeNutrientMass,
            role: .contextOnly,
            provenance: provenance
        )
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
            let maximum: Decimal
            if let maximumText = object["maxQuantity"]?.numberText,
               let value = Decimal(string: maximumText, locale: Locale(identifier: "en_US_POSIX")) {
                maximum = value
            } else {
                maximum = minimum
            }
            let unitText = object["unit"]?.stringValue ?? ""
            let unit: MeasureUnit = (try? UnitRegistry.unit(for: unitText)) ?? .serving
            let order = literalText(in: object, "order").flatMap { Int($0) } ?? (sizes.count + 1)
            sizes.append(
                DSLDServingSize(
                    order: order,
                    minimum: Quantity(value: minimum, unit: unit),
                    maximum: Quantity(value: Swift.max(minimum, maximum), unit: unit),
                    unitText: unitText,
                    isFactsPanelServing: object["inSFB"]?.flagValue ?? false
                )
            )
        }
        return sizes
    }

    /// Every serving size the label speaks of, in label order: the ones it lists plus the ones its
    /// quantity entries name. A label with none of either still has one serving size, the first.
    private static func servingOrders(in root: [String: DSLDJSON], sizes: [DSLDServingSize]) -> [Int] {
        var orders: [Int] = []
        for size in sizes {
            if !orders.contains(size.order) {
                orders.append(size.order)
            }
        }
        for row in root["ingredientRows"]?.arrayValue ?? [] {
            guard let object = row.objectValue else { continue }
            for entry in quantityEntries(of: object) + nestedQuantityEntries(of: object) {
                guard let text = entry["servingSizeOrder"]?.numberText, let order = Int(text) else { continue }
                if !orders.contains(order) {
                    orders.append(order)
                }
            }
        }
        return orders.isEmpty ? [1] : orders.sorted()
    }

    private static func quantityEntries(of object: [String: DSLDJSON]) -> [[String: DSLDJSON]] {
        (object["quantity"]?.arrayValue ?? []).compactMap { $0.objectValue }
    }

    private static func nestedQuantityEntries(of object: [String: DSLDJSON]) -> [[String: DSLDJSON]] {
        var entries: [[String: DSLDJSON]] = []
        for nested in object["nestedRows"]?.arrayValue ?? [] {
            guard let member = nested.objectValue else { continue }
            entries.append(contentsOf: quantityEntries(of: member))
        }
        return entries
    }

    // MARK: - Ingredient rows

    /// The quantity entry of a row for one serving size.
    ///
    /// DSLD repeats the amount of a row once per serving size and names the serving size in
    /// `servingSizeOrder`. An entry that names no serving size belongs to the label's first one. A row
    /// that states no entry for the serving size being read has no amount for it, which is unknown and
    /// never the amount of another serving size.
    private static func quantityEntry(
        in object: [String: DSLDJSON],
        for order: Int,
        firstOrder: Int
    ) -> [String: DSLDJSON]? {
        let entries = quantityEntries(of: object)
        guard !entries.isEmpty else { return nil }
        for entry in entries {
            guard let text = entry["servingSizeOrder"]?.numberText, Int(text) == order else { continue }
            return entry
        }
        return order == firstOrder ? entries[0] : nil
    }

    /// A proprietary blend is a row DSLD marks as a blend: `category` is "blend" or the row is named as a
    /// proprietary blend. Nesting alone is not blend metadata: DSLD also uses `nestedRows` to present a
    /// nutrient with its own breakdown, such as Folate with Folic Acid or Calories with Calories from Fat,
    /// and those rows stay facts.
    private static func blend(
        object: [String: DSLDJSON],
        name: String,
        substanceIdentifier: String,
        rowOrder: String,
        labelIdentifier: Int,
        amount: NutrientValue,
        servingOrder: Int
    ) throws -> ProprietaryBlend? {
        let category = text(in: object, "category")?.lowercased()
        let group = text(in: object, "ingredientGroup")?.lowercased()
        let isBlend = category == "blend"
            || name.lowercased().contains("proprietary blend")
            || (group?.contains("proprietary blend") ?? false)
        guard isBlend else { return nil }
        var members: [BlendMember] = []
        for entry in object["nestedRows"]?.arrayValue ?? [] {
            guard let member = entry.objectValue else { continue }
            guard let memberName = text(in: member, "name") else { continue }
            members.append(
                BlendMember(
                    labelName: memberName,
                    substanceIdentifier: literalText(in: member, "ingredientId"),
                    amount: Self.amount(from: Self.servingQuantity(in: member))
                )
            )
        }
        return try ProprietaryBlend(
            identifier: "dsld-\(labelIdentifier)-\(substanceIdentifier)",
            labelName: name,
            total: amount,
            basis: .compoundMass,
            members: members,
            provenance: "NIH DSLD label \(labelIdentifier), proprietary blend row \(rowOrder), serving size \(servingOrder)"
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
    ///   `.belowReportingThreshold` when its unit is one the table covers and `.unknown` otherwise, and any
    ///   other operator becomes `.unknown`, so a bound never becomes a known exact amount. A missing
    ///   operator is unknown too; it is never assumed to be "=".
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
            // A bound only carries meaning with a unit the app can interpret; without one it is unknown,
            // because a threshold with no dimension states nothing.
            guard let symbol, let thresholdUnit = unit(for: symbol) else { return .unknown }
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