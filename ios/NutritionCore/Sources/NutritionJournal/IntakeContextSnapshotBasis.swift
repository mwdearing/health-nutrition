import Foundation
import NutritionDomain

/// What a product snapshot's stated nutrient values are given on, read from the `labelBasis` text the journal
/// stores with the snapshot.
///
/// A snapshot states the values for the product, on the basis its source named: 13 g of protein per 100 g, or
/// 24 g of protein per serving. The facts of an intake are the amount that was actually logged, so those
/// values have to be scaled before they are hashed. Sending them unscaled would state the whole package rather
/// than the portion eaten, which is the same reason `JournalSnapshotTotals` scales a snapshot with
/// this factor rather than carrying the stated value.
///
/// The type is public because a third caller needs the same factor the encoder and the HealthKit totals
/// use: the daily totals in `NutritionUI` sum a day's snapshot nutrients, and summing the product's own
/// stated values would state the whole package rather than the portion eaten. Nothing else about the
/// basis changed.
public enum IntakeContextSnapshotBasis: Equatable {
    /// Per 100 of the given unit, the shape a barcode lookup states.
    case perHundred(MeasureUnit)
    /// Per one of a counted unit, the shape a recipe states: one serving, one scoop.
    case perCount(MeasureUnit)
    /// Per one of a mass or volume unit, the shape a recipe states with a total yield: "Per kg; yield 0.8 kg"
    /// holds the value of one kilogram of the batch, because the recipe divides its totals by the yield.
    case perUnit(MeasureUnit)

    /// The basis the stored text names, or nil when it names none this encoder can resolve.
    ///
    /// The text is compared with its spaces and underscores removed, because the app stores the same basis in
    /// several shapes: "per 100 g", "per100g", "per_serving", "Per serving; yield 4 servings" and the total-yield
    /// recipe shape "Per kg; yield 0.8 kg" all name a basis this can scale. An unresolved basis is nil rather than a guess: "per 100 g or mL" says the source
    /// did not resolve its own dimension, and "per 100 kcal" is not a quantity the journal records.
    public static func parse(_ labelBasis: String) -> IntakeContextSnapshotBasis? {
        var compact = ""
        for character in labelBasis.lowercased() {
            if character == " " || character == "_" || character == "-" { continue }
            compact.append(character)
        }
        // The ambiguous spelling is checked first, because it contains both of the specific ones.
        if compact.contains("per100gorml") { return nil }
        if compact.contains("per100ml") { return .perHundred(.mL) }
        if compact.contains("per100g") { return .perHundred(.g) }
        // Any other "per 100 <something>" is a basis the journal cannot resolve against a logged quantity.
        if compact.contains("per100") { return nil }
        // `piece` and `gummy` are counted units like the rest, so "per gummy" scales exactly as
        // "per serving" does. They are checked after the ambiguous spellings above, which none of them
        // contains.
        for unit in [MeasureUnit.serving, .scoop, .tablet, .capsule, .piece, .gummy] {
            if compact.contains("per" + unit.symbol.lowercased()) { return .perCount(unit) }
        }
        // A recipe with a total yield states "Per <unit>; yield <amount> <unit>", the same unit on both sides.
        for unit in UnitRegistry.units(in: .mass) + UnitRegistry.units(in: .volume) {
            if isTotalYieldBasis(compact, unit: unit) { return .perUnit(unit) }
        }
        return nil
    }

    /// Whether the compacted text is exactly "per<unit>;yield<amount><unit>" with a positive amount, which is
    /// the text `RecipeLogger.basisText` writes for a total yield. Anchored at both ends, so "per kg" and
    /// "per kg; yield 0.8 L" and "per mL; yield 1 L" do not match, and a unit inside another unit's name
    /// ("per g" in "per gummy") cannot match either.
    private static func isTotalYieldBasis(_ compact: String, unit: MeasureUnit) -> Bool {
        let symbol = compactSymbol(unit.symbol)
        let head = "per" + symbol + ";yield"
        guard compact.hasPrefix(head), compact.hasSuffix(symbol), compact.count > head.count + symbol.count
        else { return false }
        let amount = String(compact.dropFirst(head.count).dropLast(symbol.count))
        guard DecimalText.isValidDecimalText(amount), let value = DecimalText.decode(amount), value > 0
        else { return false }
        return true
    }

    /// A unit symbol in the form the basis text is compacted to: lowercase, with the spaces removed, so "fl oz"
    /// is "floz".
    private static func compactSymbol(_ symbol: String) -> String {
        String(symbol.lowercased().filter { $0 != " " })
    }

    /// The factor that turns a stated value into the logged amount, or nil when the logged components cannot
    /// answer this basis.
    ///
    /// A per-100 basis is the logged quantity in that unit over 100: 40 g logged of a product stated per 100 g
    /// is 0.4 of it, which carries 5.2 g out of 13 g. A per-count basis is the number logged, and only when
    /// exactly one component was counted in that unit, so two servings multiply a per-serving value.
    public func factor(forLogged components: [IntakeComponent]) -> Decimal? {
        switch self {
        case .perHundred(let unit):
            guard let total = Self.loggedAmount(components, in: unit) else { return nil }
            return total / 100
        case .perUnit(let unit):
            // A recipe's values are per one unit of its yield, so the logged amount in that unit is the factor
            // with nothing to divide by. 250 mL logged of a "Per L; yield 1 L" recipe is 0.25.
            return Self.loggedAmount(components, in: unit)
        case .perCount(let unit):
            let counted = components.filter { $0.unit == unit }
            guard counted.count == 1 else { return nil }
            return counted[0].amount
        }
    }

    /// The logged components that are in the unit's dimension, converted to the unit and summed, or nil when
    /// none of them is in that dimension. A logged amount in another dimension cannot answer the basis.
    private static func loggedAmount(_ components: [IntakeComponent], in unit: MeasureUnit) -> Decimal? {
        var total = Decimal(0)
        var found = false
        for component in components {
            guard component.unit.dimension == unit.dimension,
                  let converted = try? Quantity(
                    value: component.amount, unit: component.unit).converted(to: unit)
            else { continue }
            total += converted.value
            found = true
        }
        return found ? total : nil
    }

    /// The factor for a snapshot's basis and the logged components, or nil when the basis is unresolved or the
    /// components cannot answer it.
    ///
    /// Public because the day totals scale the same way the encoder does: a snapshot states its values for the
    /// amount its basis names, so a reader that adds up a day has to scale them to what was logged rather than
    /// count the whole package.
    public static func scalingFactor(labelBasis: String, logged components: [IntakeComponent]) -> Decimal? {
        guard let basis = parse(labelBasis) else { return nil }
        if let factor = basis.factor(forLogged: components) { return factor }
        return countedServingFactor(labelBasis: labelBasis, basis: basis, logged: components)
    }

    /// The factor for a per-count basis whose serving is stated as a count of the thing logged, and the
    /// entry records that thing rather than a serving: "per serving (3 gummy)" with six gummies logged is
    /// two servings. A label that says "Serving size 3 gummies" is stored in this shape.
    ///
    /// Only the one counted component, in the unit the serving is stated in, scales, so the factor is exact.
    /// An entry that records another count beside it ("six gummies and a tablet") does not say how many
    /// servings were eaten, so it is nil. A serving stated in weight or volume ("per serving (30 g)") is not
    /// answered here, because the encoder and the HealthKit totals do not say how much was eaten from a
    /// weight the entry does not record in that dimension. A serving with no quantity
    /// ("per serving (1 large biscuit)") is nil.
    private static func countedServingFactor(
        labelBasis: String, basis: IntakeContextSnapshotBasis, logged components: [IntakeComponent]
    ) -> Decimal? {
        guard case .perCount = basis,
              let serving = statedServingQuantity(labelBasis),
              serving.unit.dimension == .count
        else { return nil }
        let counts = components.filter { $0.unit.dimension == .count }
        guard counts.count == 1, counts[0].unit == serving.unit else { return nil }
        return counts[0].amount / serving.value
    }

    /// The quantity one serving is, from a basis that states it: "per serving (30 g)" is 30 g and
    /// "per serving (3 gummy)" is 3 gummy.
    ///
    /// A household measure can carry its weight in brackets of its own, "per serving (1 bar (30 g))", so
    /// the innermost brackets are read: the last "(" and the first ")" after it.
    ///
    /// Only a number and a registry unit are read. A serving stated any other way, "1 large biscuit" or
    /// "a handful", is nil, because nothing in it says how big one serving is.
    public static func statedServingQuantity(
        _ labelBasis: String
    ) -> (value: Decimal, unit: MeasureUnit)? {
        guard let open = labelBasis.lastIndex(of: "("),
            let close = labelBasis[labelBasis.index(after: open)...].firstIndex(of: ")")
        else { return nil }
        let stated = String(labelBasis[labelBasis.index(after: open)..<close])
            .trimmingCharacters(in: .whitespaces)
        let digits = stated.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        let symbol = stated.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        // A number with two points, "1.2.3", is not a quantity; the amount parser the totals always used refuses it.
        guard digits.filter({ $0 == "." }).count <= 1,
            let amount = DecimalText.decode(String(digits)), amount > 0,
            let unit = try? UnitRegistry.unit(for: symbol)
        else { return nil }
        return (amount, unit)
    }
}