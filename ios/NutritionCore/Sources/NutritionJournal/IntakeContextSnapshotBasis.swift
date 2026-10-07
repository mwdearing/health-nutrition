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

    /// The basis the stored text names, or nil when it names none this encoder can resolve.
    ///
    /// The text is compared with its spaces and underscores removed, because the app stores the same basis in
    /// several shapes: "per 100 g", "per100g", "per_serving" and "Per serving; yield 4 servings" all name a
    /// basis this can scale. An unresolved basis is nil rather than a guess: "per 100 g or mL" says the source
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
        for unit in [MeasureUnit.serving, .scoop, .tablet, .capsule] {
            if compact.contains("per" + unit.symbol.lowercased()) { return .perCount(unit) }
        }
        return nil
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
            guard found else { return nil }
            return total / 100
        case .perCount(let unit):
            let counted = components.filter { $0.unit == unit }
            guard counted.count == 1 else { return nil }
            return counted[0].amount
        }
    }

    /// The factor for a snapshot's basis and the logged components, or nil when the basis is unresolved or the
    /// components cannot answer it.
    ///
    /// Public because the day totals scale the same way the encoder does: a snapshot states its values for the
    /// amount its basis names, so a reader that adds up a day has to scale them to what was logged rather than
    /// count the whole package.
    public static func scalingFactor(labelBasis: String, logged components: [IntakeComponent]) -> Decimal? {
        guard let basis = parse(labelBasis) else { return nil }
        return basis.factor(forLogged: components)
    }
}