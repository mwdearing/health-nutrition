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
    /// The components this app writes. A component with no row has no catalog code, and the encoder refuses it
    /// instead of inventing one, because the receiver's catalog decides which codes exist.
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

    /// The HealthKit quantity type identifier the contract pairs with a fact's `code`, or nil for a code that
    /// is not a HealthRelay catalog code.
    ///
    /// Water is always `hydration` and lands in `HKQuantityTypeIdentifierDietaryWater`; every `dietary_<name>`
    /// code lands in `HKQuantityTypeIdentifierDietary<Name>` with each part capitalised, so
    /// `dietary_vitamin_b6` is `HKQuantityTypeIdentifierDietaryVitaminB6`. The encoder checks a link's
    /// `healthkit_type` against this, because a link that names another type would not join.
    public static func healthKitTypeIdentifier(forCode code: String) -> String? {
        if code == "hydration" { return "HKQuantityTypeIdentifierDietaryWater" }
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