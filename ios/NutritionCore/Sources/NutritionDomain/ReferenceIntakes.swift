import Foundation

/// The sex a reference intake is published for. The reference tables have a row for each and no row
/// for neither, so there is no third case here: a screen that has no answer shows no reference.
public enum ReferenceSex: String, Sendable, Hashable, Codable, CaseIterable {
    case female, male
}

/// The adult age bands the reference tables use. Every adult value changes, if it changes at all, at
/// 31, 51 or 71, so these four bands state every adult row exactly.
public enum ReferenceAgeBand: String, Sendable, Hashable, Codable, CaseIterable {
    case years19To30, years31To50, years51To70, years71Plus

    /// The band an age falls in, or nil under 19, which the table does not cover.
    public init?(ageYears: Int) {
        switch ageYears {
        case 19...30: self = .years19To30
        case 31...50: self = .years31To50
        case 51...70: self = .years51To70
        case 71...: self = .years71Plus
        default: return nil
        }
    }

    /// "19 to 30", the words a picker shows.
    public var label: String {
        switch self {
        case .years19To30: return "19 to 30"
        case .years31To50: return "31 to 50"
        case .years51To70: return "51 to 70"
        case .years71Plus: return "71 and over"
        }
    }

    /// The column a row's values are listed in.
    fileprivate var index: Int {
        switch self {
        case .years19To30: return 0
        case .years31To50: return 1
        case .years51To70: return 2
        case .years71Plus: return 3
        }
    }
}

/// Who a set of reference values is for: one published row of the adult tables. Pregnancy,
/// lactation and anyone under 19 have rows of their own that this table does not carry.
public struct ReferenceGroup: Sendable, Hashable, Codable {
    public let sex: ReferenceSex
    public let ageBand: ReferenceAgeBand

    public init(sex: ReferenceSex, ageBand: ReferenceAgeBand) {
        self.sex = sex
        self.ageBand = ageBand
    }

    /// Every group, women first, youngest band first.
    public static let all: [ReferenceGroup] = ReferenceSex.allCases.flatMap { sex in
        ReferenceAgeBand.allCases.map { ReferenceGroup(sex: sex, ageBand: $0) }
    }

    /// "Women 19 to 30", the words a picker shows.
    public var label: String {
        "\(sex == .female ? "Women" : "Men") \(ageBand.label)"
    }
}

/// Which published figure a reference amount is.
public enum ReferenceIntakeKind: String, Sendable, Hashable, Codable {
    /// A Recommended Dietary Allowance: enough for nearly all healthy people in the group.
    case recommendedDietaryAllowance
    /// An Adequate Intake, published where the evidence was not enough to set an allowance.
    case adequateIntake

    /// "RDA" or "AI", as the tables abbreviate it.
    public var abbreviation: String {
        switch self {
        case .recommendedDietaryAllowance: return "RDA"
        case .adequateIntake: return "AI"
        }
    }
}

/// What a Tolerable Upper Intake Level counts. Most count everything eaten and taken, but a few count
/// only some forms, and comparing a whole day's total against one of those would read ordinary food
/// as over a limit that was never set for food.
public enum UpperLimitScope: String, Sendable, Hashable, Codable {
    /// Food, water and supplements together.
    case allSources
    /// Only supplements and medicines, never food or water: the magnesium limit.
    case supplementsAndMedicines
    /// Only the forms added to supplements and fortified foods, never what food holds naturally: the
    /// niacin limit (supplemental niacin) and the vitamin E limit (any supplemental alpha-tocopherol).
    case supplementsAndFortifiedFoods
    /// Only synthetic folic acid from supplements and fortified foods, and in micrograms of folic acid,
    /// not of DFE: the folate limit. The row's allowance and the journal count folate in mcg DFE, and
    /// a microgram of folic acid is 1.667 mcg DFE, so a DFE amount states more micrograms than the folic
    /// acid in it. Comparing a DFE amount against this limit can therefore only warn early, never late,
    /// while a label that states plain folic acid compares exactly.
    case folicAcid
    /// Only preformed vitamin A (retinol and its esters), from animal foods and supplements. Beta
    /// carotene and the other provitamin A carotenoids are not counted.
    case preformedVitaminA
}

/// One nutrient's published adult reference values for one group, in the unit the app counts that
/// nutrient in.
///
/// These are population reference values, not advice for a person: they are what a screen may show
/// beside a day's total so the number has something to be read against.
public struct ReferenceIntake: Sendable, Hashable {
    /// The journal's nutrient key, such as `magnesium`.
    public let nutrient: String
    /// The RDA or AI.
    public let amount: Decimal
    public let kind: ReferenceIntakeKind
    /// The unit `amount` and `upperLimit` are in: the unit the journal and the Apple Health writer
    /// count this nutrient in, so a total can be compared without a conversion it cannot make. The one
    /// exception is a `.folicAcid` limit, which is micrograms of folic acid rather than of DFE.
    public let unit: MeasureUnit
    /// The Tolerable Upper Intake Level, or nil where none was determined. Nil means the tables set no
    /// level, never that any amount is fine.
    public let upperLimit: Decimal?
    /// What `upperLimit` counts. Nil exactly when `upperLimit` is.
    public let upperLimitScope: UpperLimitScope?

    public init(
        nutrient: String, amount: Decimal, kind: ReferenceIntakeKind, unit: MeasureUnit,
        upperLimit: Decimal?, upperLimitScope: UpperLimitScope?
    ) {
        self.nutrient = nutrient
        self.amount = amount
        self.kind = kind
        self.unit = unit
        self.upperLimit = upperLimit
        self.upperLimitScope = upperLimitScope
    }
}

/// The adult Dietary Reference Intakes for the vitamins and minerals the app tracks.
///
/// Values are the Food and Nutrition Board's adult RDAs, AIs and ULs as the NIH Office of Dietary
/// Supplements health-professional fact sheets state them; `docs/reference-intakes.md` lists each
/// source. Units are the app's own for each key: vitamin A is mcg RAE, niacin mg NE, folate mcg DFE
/// and vitamin E mg alpha-tocopherol, which is how labels state them in those units. Copper is the one
/// figure restated: the tables give micrograms and the app counts milligrams, so 900 mcg is 0.9 mg. The
/// folate limit is the one value on another basis, micrograms of folic acid, which its scope says.
///
/// Chloride and sodium are not here. No fact sheet was checked for chloride, and sodium's 2,300 mg is
/// a chronic-disease risk reduction level rather than an upper limit, so it does not fit this shape.
/// Neither is water, energy or a macronutrient: those are goals a person sets.
public enum ReferenceIntakes {
    /// The nutrient keys the table covers, in the order the app lists vitamins and minerals.
    public static var nutrients: [String] { rows.map(\.nutrient) }

    /// The reference values for one nutrient and group, or nil for a key the table does not cover.
    public static func intake(for nutrient: String, group: ReferenceGroup) -> ReferenceIntake? {
        rows.first { $0.nutrient == nutrient }.map { $0.intake(for: group) }
    }

    /// Every nutrient's reference values for one group, in table order.
    public static func intakes(for group: ReferenceGroup) -> [ReferenceIntake] {
        rows.map { $0.intake(for: group) }
    }

    /// One nutrient's published values. Each array is indexed by `ReferenceAgeBand`: 19 to 30,
    /// 31 to 50, 51 to 70, 71 and over. ULs do not differ by sex for adults, so there is one array.
    private struct Row: Sendable {
        let nutrient: String
        let unit: MeasureUnit
        let kind: ReferenceIntakeKind
        let female: [Decimal]
        let male: [Decimal]
        let upperLimit: [Decimal]?
        let upperLimitScope: UpperLimitScope?

        init(
            _ nutrient: String, _ unit: MeasureUnit, _ kind: ReferenceIntakeKind,
            female: [String], male: [String], upperLimit: [String]? = nil, scope: UpperLimitScope? = nil
        ) {
            self.nutrient = nutrient
            self.unit = unit
            self.kind = kind
            self.female = female.map(ReferenceIntakes.decimal)
            self.male = male.map(ReferenceIntakes.decimal)
            self.upperLimit = upperLimit?.map(ReferenceIntakes.decimal)
            self.upperLimitScope = scope
        }

        func intake(for group: ReferenceGroup) -> ReferenceIntake {
            let column = group.ageBand.index
            return ReferenceIntake(
                nutrient: nutrient,
                amount: (group.sex == .female ? female : male)[column],
                kind: kind,
                unit: unit,
                upperLimit: upperLimit?[column],
                upperLimitScope: upperLimit == nil ? nil : upperLimitScope)
        }
    }

    /// Every value is written as text and read as an exact decimal, so `1.3` is 1.3 and not the
    /// nearest binary double.
    private static func decimal(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    }

    private static func same(_ value: String) -> [String] { [value, value, value, value] }

    private static let rda = ReferenceIntakeKind.recommendedDietaryAllowance
    private static let ai = ReferenceIntakeKind.adequateIntake

    private static let rows: [Row] = [
        Row("vitaminA", .mcg, rda, female: same("700"), male: same("900"),
            upperLimit: same("3000"), scope: .preformedVitaminA),
        Row("vitaminB6", .mg, rda, female: ["1.3", "1.3", "1.5", "1.5"], male: ["1.3", "1.3", "1.7", "1.7"],
            upperLimit: same("100"), scope: .allSources),
        Row("vitaminB12", .mcg, rda, female: same("2.4"), male: same("2.4")),
        Row("vitaminC", .mg, rda, female: same("75"), male: same("90"),
            upperLimit: same("2000"), scope: .allSources),
        Row("vitaminD", .mcg, rda, female: ["15", "15", "15", "20"], male: ["15", "15", "15", "20"],
            upperLimit: same("100"), scope: .allSources),
        Row("vitaminE", .mg, rda, female: same("15"), male: same("15"),
            upperLimit: same("1000"), scope: .supplementsAndFortifiedFoods),
        Row("vitaminK", .mcg, ai, female: same("90"), male: same("120")),
        Row("thiamin", .mg, rda, female: same("1.1"), male: same("1.2")),
        Row("riboflavin", .mg, rda, female: same("1.1"), male: same("1.3")),
        Row("niacin", .mg, rda, female: same("14"), male: same("16"),
            upperLimit: same("35"), scope: .supplementsAndFortifiedFoods),
        // The limit is 1,000 mcg of folic acid, not DFE; `.folicAcid` carries that basis.
        Row("folate", .mcg, rda, female: same("400"), male: same("400"),
            upperLimit: same("1000"), scope: .folicAcid),
        Row("biotin", .mcg, ai, female: same("30"), male: same("30")),
        Row("pantothenicAcid", .mg, ai, female: same("5"), male: same("5")),
        Row("calcium", .mg, rda, female: ["1000", "1000", "1200", "1200"], male: ["1000", "1000", "1000", "1200"],
            upperLimit: ["2500", "2500", "2000", "2000"], scope: .allSources),
        Row("iron", .mg, rda, female: ["18", "18", "8", "8"], male: same("8"),
            upperLimit: same("45"), scope: .allSources),
        Row("magnesium", .mg, rda, female: ["310", "320", "320", "320"], male: ["400", "420", "420", "420"],
            upperLimit: same("350"), scope: .supplementsAndMedicines),
        Row("phosphorus", .mg, rda, female: same("700"), male: same("700"),
            upperLimit: ["4000", "4000", "4000", "3000"], scope: .allSources),
        Row("potassium", .mg, ai, female: same("2600"), male: same("3400")),
        Row("zinc", .mg, rda, female: same("8"), male: same("11"),
            upperLimit: same("40"), scope: .allSources),
        Row("chromium", .mcg, ai, female: ["25", "25", "20", "20"], male: ["35", "35", "30", "30"]),
        Row("copper", .mg, rda, female: same("0.9"), male: same("0.9"),
            upperLimit: same("10"), scope: .allSources),
        Row("iodine", .mcg, rda, female: same("150"), male: same("150"),
            upperLimit: same("1100"), scope: .allSources),
        Row("manganese", .mg, ai, female: same("1.8"), male: same("2.3"),
            upperLimit: same("11"), scope: .allSources),
        Row("molybdenum", .mcg, rda, female: same("45"), male: same("45"),
            upperLimit: same("2000"), scope: .allSources),
        Row("selenium", .mcg, rda, female: same("55"), male: same("55"),
            upperLimit: same("400"), scope: .allSources),
    ]
}
