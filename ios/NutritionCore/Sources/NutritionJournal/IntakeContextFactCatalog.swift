import Foundation
import NutritionDomain

/// One member of a proprietary blend, as the label prints it.
///
/// The amount and unit appear only when the label discloses them. An undisclosed member keeps its name and
/// nothing else, because the contract forbids inventing member amounts or splitting the blend total evenly.
public struct IntakeContextBlendMember: Sendable, Hashable {
    public let labelName: String
    /// Exact decimal text; nil when the label does not disclose the member's amount.
    public let amount: String?
    public let unit: String?

    public init(labelName: String, amount: String? = nil, unit: String? = nil) {
        self.labelName = labelName
        self.amount = amount
        self.unit = unit
    }
}

/// What one journal component means to the intake-context contract.
///
/// The journal stores a component as an id, a printed name, an amount and a unit. The contract asks for more:
/// whether the component is a nutrient, a compound or a blend total, the catalog code the receiver knows it
/// by, the basis a compound amount measures, where the value came from, and, for a blend, its members. This
/// descriptor is that missing part, so it lives in one table instead of being guessed per call site: a
/// component without a row has no contract code and is refused rather than given an invented one.
public struct IntakeContextComponentDescriptor: Sendable, Hashable {
    /// Nutrient, compound or blend total.
    public let kind: FactKind
    /// The catalog code, for example `hydration`, `dietary_caffeine` or `creatine_monohydrate`.
    public let code: String
    /// The journal nutrient key a product snapshot states this component under, when it has one. A compound
    /// and a blend are not nutrients, so they have no key a snapshot would state.
    public let nutrientKey: String?
    /// What a compound amount measures. The contract requires it on a compound and allows it elsewhere.
    public let quantityBasis: QuantityBasis
    /// Where the value came from: `user_confirmed`, `label_confirmed` and the rest of the contract's list.
    public let provenance: String
    /// Blend members, in label order. Only a blend uses them, and a blend needs at least one.
    public let blendMembers: [IntakeContextBlendMember]

    public init(
        kind: FactKind,
        code: String,
        nutrientKey: String? = nil,
        quantityBasis: QuantityBasis = .activeNutrientMass,
        provenance: String,
        blendMembers: [IntakeContextBlendMember] = []
    ) {
        self.kind = kind
        self.code = code
        self.nutrientKey = nutrientKey
        self.quantityBasis = quantityBasis
        self.provenance = provenance
        self.blendMembers = blendMembers
    }

    /// The aggregation role the contract fixes for each kind: a nutrient takes part in no total, a compound is
    /// a measurement, and only a blend's stated total is ever counted.
    public var aggregationRole: AggregationRole {
        switch kind {
        case .nutrient: return .contextOnly
        case .compound: return .compoundMeasurement
        case .blend: return .blendTotalOnly
        }
    }
}

/// The catalog the encoder maps journal components through.
///
/// It is the intake-context counterpart of `HealthKitWritePlanner.mappings`: both are tables the app keeps so
/// that the same journal component always names the same contract concept, whatever the caller does.
public enum IntakeContextFactCatalog {
    /// The code water is always written under, whatever the component that holds the water is called.
    public static let hydrationCode = "hydration"
    /// The prefix every inferred nutrient code carries, so it names itself as a dietary nutrient.
    public static let dietaryCodePrefix = "dietary_"
    /// The catalog origin a recipe-built snapshot carries. Its values were calculated from the recipe's
    /// ingredients rather than read off a label.
    public static let recipeCalculatedOrigin = "recipe_calculated"
    /// The provenance of a value the user recorded with no product behind it.
    public static let userConfirmedProvenance = "user_confirmed"
    /// The provenance of a value read from a product catalog.
    public static let catalogReferenceProvenance = "catalog_reference"
    /// The provenance of a value calculated from a recipe's ingredients.
    public static let recipeCalculatedProvenance = "recipe_calculated"

    /// The components whose contract concept is not derivable from what they measure: a compound states a
    /// basis, a blend states members. Everything else is a nutrient under its own name, so a food or a recipe
    /// component needs no row here.
    public static let components: [String: IntakeContextComponentDescriptor] = [
        "water": IntakeContextComponentDescriptor(
            kind: .nutrient,
            code: "hydration",
            nutrientKey: "water",
            provenance: "user_confirmed"),
        "caffeine": IntakeContextComponentDescriptor(
            kind: .nutrient,
            code: "dietary_caffeine",
            nutrientKey: "caffeine",
            provenance: "label_confirmed"),
        "creatine-monohydrate": IntakeContextComponentDescriptor(
            kind: .compound,
            code: "creatine_monohydrate",
            quantityBasis: .compoundMass,
            provenance: "label_confirmed"),
        // A proprietary blend is one fact with the label's stated total, never a set of member amounts: the
        // members below are named and no amount is written, because the label discloses none. The contract
        // fixture `valid_proprietary_blend.json` carries exactly this synthetic blend.
        "energy-blend": IntakeContextComponentDescriptor(
            kind: .blend,
            code: "proprietary_energy_blend",
            quantityBasis: .compoundMass,
            provenance: "label_confirmed",
            blendMembers: [
                IntakeContextBlendMember(labelName: "Taurine"),
                IntakeContextBlendMember(labelName: "Guarana extract"),
                IntakeContextBlendMember(labelName: "Ginseng root extract"),
            ]),
        // Energy is kept apart from the blend above, so an undisclosed energy value is its own unknown fact
        // instead of being read off the blend total.
        "energy-kcal": IntakeContextComponentDescriptor(
            kind: .nutrient,
            code: "dietary_energy_consumed",
            nutrientKey: "energy",
            provenance: "label_confirmed"),
    ]

    /// The descriptor for a component id, or nil when the catalog has no row for it.
    public static func descriptor(for componentID: String) -> IntakeContextComponentDescriptor? {
        components[componentID]
    }

    /// The code for a component or a snapshot nutrient that names itself: `dietary_<its own name>`.
    ///
    /// The schema caps a slug at 64 characters and the journal will accept a component id that fills all of
    /// them, so a longer name is shortened rather than sent: a code the schema rejects fails the whole
    /// operation. The name is only a label for the value - the fact's identity is its `component_id`, which is
    /// never touched - so the prefix is always kept and the truncation is deterministic.
    public static func dietaryCode(named name: String) -> String {
        let room = 64 - dietaryCodePrefix.count
        let shortened = name.count > room ? String(name.prefix(room)) : name
        return dietaryCodePrefix + shortened
    }

    /// The slug a journal nutrient key becomes: canonical first, then camel case split into lower-case words,
    /// so `energyKcal` is the canonical `energy` and `vitaminD` is `vitamin-d`.
    public static func nutrientSlug(for key: String) -> String {
        let canonical = HealthKitWritePlanner.canonicalKey(for: key)
        var slug = ""
        for character in canonical {
            if character.isUppercase, !slug.isEmpty { slug.append("-") }
            slug.append(contentsOf: String(character).lowercased())
        }
        return slug
    }

    /// The contract code for a nutrient the journal names by key.
    ///
    /// The slug is the fact's identity, but the code is what names the value to the receiver and to HealthKit,
    /// and for some nutrients the two differ: energy is `dietary_energy_consumed`, which is what
    /// `HKQuantityTypeIdentifierDietaryEnergyConsumed` follows from and what the contract's own blend fixture
    /// writes, so a fact coded `dietary_energy` would name a type HealthKit does not have. A key a catalog row
    /// covers uses that row's code, and anything the app maps to a dietary quantity type gets the code that type
    /// implies; only a key the app does not map falls back to its own name.
    public static func code(forNutrientKey key: String) -> String {
        let canonical = HealthKitWritePlanner.canonicalKey(for: key)
        if let row = components.values.first(where: { $0.nutrientKey == canonical }) {
            return row.code
        }
        if let mapping = HealthKitWritePlanner.mappings.first(where: { $0.nutrientKey == canonical }) {
            let identifier = mapping.quantityTypeIdentifier
            let prefix = "HKQuantityTypeIdentifierDietary"
            if identifier.hasPrefix(prefix) {
                return dietaryCodePrefix + identifier.dropFirst(prefix.count).lowercased()
            }
        }
        return dietaryCode(named: nutrientSlug(for: canonical))
    }

    /// The provenance of a value taken from a product snapshot, or of one recorded with no product behind it.
    ///
    /// A snapshot a recipe built was calculated from that recipe's ingredients, and the contract records that
    /// as `recipe_calculated`: a consumer must not read calculated values as catalog-sourced.
    public static func provenance(for product: ProductDefinition?) -> String {
        guard let product else { return userConfirmedProvenance }
        return product.catalogOrigin == recipeCalculatedOrigin
            ? recipeCalculatedProvenance
            : catalogReferenceProvenance
    }

    /// Whether the text is one of the contract's slugs, which every code and every component id must be.
    public static func isSlug(_ text: String) -> Bool {
        text.range(of: "\\A[a-z0-9][a-z0-9._-]{0,63}\\z", options: .regularExpression) != nil
    }

    /// Whether the text is a `producer_id`: a slug, and the producer is registered under exactly this spelling.
    public static func isProducerID(_ text: String) -> Bool {
        isSlug(text)
    }

    /// Whether the text is a `writer_bundle_id`: the contract's own pattern for a bundle identifier.
    public static func isWriterBundleID(_ text: String) -> Bool {
        text.range(of: "\\A[A-Za-z0-9][A-Za-z0-9.-]{0,254}\\z", options: .regularExpression) != nil
    }

    /// The HealthKit quantity type identifier the contract pairs with a fact's `code`, or nil for a code that
    /// is not a HealthRelay catalog code.
    ///
    /// Water is always `hydration` and lands in `HKQuantityTypeIdentifierDietaryWater`; every `dietary_<name>`
    /// code lands in `HKQuantityTypeIdentifierDietary<Name>` with each part capitalised, so
    /// `dietary_vitamin_b6` is `HKQuantityTypeIdentifierDietaryVitaminB6`. The encoder checks a link's
    /// `healthkit_type` against this, because a link that names another type would not join.
    public static func healthKitTypeIdentifier(forCode code: String) -> String? {
        if code == hydrationCode { return "HKQuantityTypeIdentifierDietaryWater" }
        guard code.hasPrefix("dietary_") else { return nil }
        let name = code.dropFirst("dietary_".count)
        let parts = name.split(separator: "_").map { part -> String in
            guard let first = part.first else { return String(part) }
            return first.uppercased() + part.dropFirst()
        }
        return "HKQuantityTypeIdentifierDietary" + parts.joined()
    }
}

extension QuantityBasis {
    /// The contract spells a basis in snake case, unlike the camel-case raw value the journal uses.
    var intakeContextValue: String {
        switch self {
        case .compoundMass: return "compound_mass"
        case .activeNutrientMass: return "active_nutrient_mass"
        case .unknown: return "unknown"
        }
    }
}

extension AggregationRole {
    /// The contract spells a role in snake case.
    var intakeContextValue: String {
        switch self {
        case .contextOnly: return "context_only"
        case .compoundMeasurement: return "compound_measurement"
        case .blendTotalOnly: return "blend_total_only"
        }
    }
}

extension NutrientValue {
    /// The contract's spelling of a value state. Unknown is its own state: it is never written as a zero.
    var intakeContextValueState: String {
        switch self {
        case .known: return "known"
        case .unknown: return "unknown"
        case .notApplicable: return "not_applicable"
        case .belowReportingThreshold: return "below_reporting_threshold"
        }
    }
}