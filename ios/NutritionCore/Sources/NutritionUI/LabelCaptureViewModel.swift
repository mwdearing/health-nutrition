import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders

/// The origins a product snapshot can name. A captured panel records `label_capture`, so a later
/// reader can tell that its values came from a panel the user read on their own device rather than
/// from a catalog.
///
/// The stored spelling keeps its underscore because it is a value written into an entry, not a name
/// shown on screen.
public enum ProductOrigin {
    public static let label_capture = "label_capture"
}

/// One nutrient row of a captured panel, as the review screen shows it.
///
/// The row carries the value the parser read, the reasons it read that value with less than full
/// confidence, and what the user has done about it. Nothing here decides a value is right: a row the
/// parser flagged stays `.needsConfirmation` until the user confirms it or types one of their own.
public struct LabelCaptureRow: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable, Equatable {
        /// Read exactly as printed, so there is nothing to ask about.
        case read
        /// The parser read this with less than full confidence. It has to be confirmed or corrected.
        case needsConfirmation
        /// The user confirmed the value the parser read.
        case confirmed
        /// The user replaced the value with one they typed.
        case corrected
    }

    /// How the fifteen panel rows are named on screen. These are the labels a US panel prints.
    public static let displayNames: [NutritionFactKey: String] = [
        .calories: "Calories", .fat: "Total fat", .saturatedFat: "Saturated fat", .transFat: "Trans fat",
        .cholesterol: "Cholesterol", .sodium: "Sodium", .carbohydrates: "Total carbohydrate",
        .fiber: "Dietary fiber", .sugars: "Total sugars", .addedSugars: "Included added sugars",
        .protein: "Protein", .vitaminD: "Vitamin D", .calcium: "Calcium", .iron: "Iron",
        .potassium: "Potassium",
    ]

    /// The nutrient this row is, and why the parser asked about it. Both are read from the panel and
    /// never change afterwards.
    public let key: NutritionFactKey
    /// Why the parser asked about this value; empty when it read the row exactly as printed.
    public let reasons: Set<ParsedValueReview.Reason>
    /// The name the panel printed when it stated a chemical form with the nutrient, as `Calcium
    /// Citrate` for calcium, or nil when the panel named the nutrient plainly. It is shown instead of
    /// the journal's own name so the screen keeps the words the label used.
    public let displayName: String?
    /// The value and what the user has done about it. Both are mutable because a row is a value type
    /// in the view model's array: confirming or correcting one writes through `rows[index]`, which is
    /// also what republishes the array for the screen.
    public var value: NutrientValue
    public var status: Status

    /// Written out rather than left as the memberwise initializer, so the order of the fields is not
    /// the order of the arguments and adding a field later cannot silently reorder a call site.
    public init(
        key: NutritionFactKey, value: NutrientValue, reasons: Set<ParsedValueReview.Reason>,
        status: Status, displayName: String? = nil
    ) {
        self.key = key
        self.value = value
        self.reasons = reasons
        self.status = status
        self.displayName = displayName
    }

    public var id: String { key.rawValue }
    public var name: String { displayName ?? LabelCaptureRow.displayNames[key] ?? key.rawValue }
    public var isFlagged: Bool { !reasons.isEmpty }
    public var needsConfirmation: Bool { status == .needsConfirmation }
    /// The row still waits for the user, so nothing may be saved yet.
    public var isPending: Bool { status == .needsConfirmation }
    /// Whether the row carries an amount the user may replace.
    ///
    /// Every row the parser read an amount for qualifies, flagged or not: recognition can turn one
    /// valid number into another valid one, and the parser has no reason to flag that, so the user has
    /// to be able to correct it anyway. A row the panel said nothing about has no amount to correct,
    /// and a bound is a limit rather than a number, so neither offers the correction control.
    public var canBeCorrected: Bool {
        switch value {
        case .known: return true
        case .unknown, .notApplicable, .belowReportingThreshold: return false
        }
    }

    /// The value as the screen shows it. An unknown row reads as "not on the panel", never as zero.
    public var valueText: String {
        LabelCaptureRow.describe(value)
    }

    /// One sentence for VoiceOver: the value, and whether it still needs the user's answer.
    public var accessibilityLabel: String {
        var parts = ["\(name), \(valueText)"]
        switch status {
        case .read:
            break
        case .needsConfirmation:
            parts.append("needs checking")
        case .confirmed:
            parts.append("confirmed")
        case .corrected:
            parts.append("corrected by you")
        }
        return parts.joined(separator: ", ")
    }

    /// The reasons the parser gave, in words a user can act on.
    public var reviewSummary: String {
        LabelCaptureRow.summarize(reasons, name: name)
    }

    /// The reasons a row was flagged, in words a user can act on. Shared with the compound rows, which
    /// are flagged by the same parser and have to read the same way on the screen.
    static func summarize(_ reasons: Set<ParsedValueReview.Reason>, name: String) -> String {
        guard !reasons.isEmpty else { return "" }
        var sentences: [String] = []
        if reasons.contains(.correctedLetterO) {
            sentences.append("a letter O was read as a zero")
        }
        if reasons.contains(.unexpectedUnit) {
            sentences.append("the unit is not the one this row usually carries")
        }
        if reasons.contains(.normalisedMicrogramSymbol) {
            sentences.append("the microgram symbol was normalised")
        }
        return "Check this value: " + sentences.joined(separator: ", ") + "."
    }

    /// One line per value for a stable signature: unknown is spelled out, never rendered as zero.
    static func describe(_ value: NutrientValue) -> String {
        switch value {
        case .known(let amount, let unit):
            return "\(NSDecimalNumber(decimal: amount).stringValue) \(unit.symbol)"
        case .unknown:
            return "not on the panel"
        case .notApplicable:
            return "not applicable"
        case .belowReportingThreshold(let unit):
            return "below reporting threshold" + (unit.map { " \($0.symbol)" } ?? "")
        }
    }
}

/// One row of a captured panel that the fifteen journal nutrients do not name, as the review screen
/// shows it.
///
/// A supplement states its own compounds, and they are the reason anyone scans one, so the row is shown
/// under the name the label printed rather than dropped. It carries the key the value is stored under —
/// a slug of that name — so the confirmation the user gives reaches the snapshot under the same key the
/// journal stores it by.
public struct LabelCaptureAdditionalRow: Identifiable, Equatable, Sendable {
    /// The key the value is stored under: `creatine-monohydrate` for `Creatine Monohydrate`.
    public let key: String
    /// The name the label printed for the compound, which is what the screen shows.
    public let name: String
    /// Why the parser asked about this value; empty when it read the row exactly as printed.
    public let reasons: Set<ParsedValueReview.Reason>
    public var value: NutrientValue
    public var status: LabelCaptureRow.Status

    public init(
        key: String, name: String, value: NutrientValue, reasons: Set<ParsedValueReview.Reason>,
        status: LabelCaptureRow.Status
    ) {
        self.key = key
        self.name = name
        self.reasons = reasons
        self.value = value
        self.status = status
    }

    public var id: String { key }
    public var isFlagged: Bool { !reasons.isEmpty }
    /// The row still waits for the user, so nothing may be saved yet.
    public var isPending: Bool { status == .needsConfirmation }
    public var needsConfirmation: Bool { status == .needsConfirmation }
    /// Whether the row carries an amount the user may replace. Recognition can turn one valid number
    /// into another valid one, and the parser has no reason to flag that, so a compound the user can
    /// read is as much theirs to change as any nutrient row.
    public var canBeCorrected: Bool {
        switch value {
        case .known: return true
        case .unknown, .notApplicable, .belowReportingThreshold: return false
        }
    }

    public var valueText: String { LabelCaptureRow.describe(value) }

    /// One sentence for VoiceOver: the value, and whether it still needs the user's answer.
    public var accessibilityLabel: String {
        var parts = ["\(name), \(valueText)"]
        switch status {
        case .read:
            break
        case .needsConfirmation:
            parts.append("needs checking")
        case .confirmed:
            parts.append("confirmed")
        case .corrected:
            parts.append("corrected by you")
        }
        return parts.joined(separator: ", ")
    }

    /// The reasons the parser gave, in the words the nutrient rows use.
    public var reviewSummary: String { LabelCaptureRow.summarize(reasons, name: name) }
}

/// Reads the amount a user types to correct one captured row.
///
/// This is deliberately not `AmountParser`: that parser reads what someone ate, where zero is not an
/// entry, while a Nutrition Facts row states zero often and legitimately — a label that printed
/// `Total Fat 0g` means what it says. The rules here differ on exactly that one point.
///
/// Everything else is as strict as the intake form: digits with at most one point, no sign, no locale
/// and no grouping, so a correction is never stored as something the form would have refused. The unit
/// is optional: text that states no unit keeps the unit the panel printed, and text that states one is
/// read as that unit, so `0 g` is a correction of a row printed in grams and `0` is the same correction
/// with the unit left as the panel had it.
public enum NutrientAmountParser {
    public static let locale = Locale(identifier: "en_US_POSIX")

    /// One amount as the user typed it: the number, and the unit the text named when it named one.
    public struct Amount: Equatable, Sendable {
        public let value: Decimal
        public let unit: MeasureUnit?

        public init(value: Decimal, unit: MeasureUnit?) {
            self.value = value
            self.unit = unit
        }
    }

    /// Returns the amount the text states, or nil for anything else. Zero is a value; a negative or
    /// unreadable amount is not.
    public static func parse(_ text: String) -> Amount? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard let value = decimal(parts[0]) else { return nil }
        guard parts.count == 1 else {
            // A unit the registry does not carry is not resolved into one it does, so the text is
            // refused rather than stored as an amount in a unit nobody printed. A counted unit is the
            // one exception: the registry carries the singular symbol, while a label states the plural
            // ("3 gummies", "2 pieces"), and the correction path reads the same words the capture path
            // does rather than making the person restate them in the registry's spelling.
            let symbol = parts[1].trimmingCharacters(in: .whitespaces)
            guard let unit = (try? MeasureUnit(symbol: symbol))
                ?? NutritionFactsParser.countedUnit(for: symbol)
            else { return nil }
            return Amount(value: value, unit: unit)
        }
        return Amount(value: value, unit: nil)
    }

    /// A non-negative decimal written with digits and at most one point, and no sign.
    private static func decimal(_ text: String) -> Decimal? {
        guard !text.isEmpty else { return nil }
        var dots = 0
        var digits = 0
        for character in text {
            if character == "." {
                dots += 1
            } else if character.isASCII, character.isNumber {
                digits += 1
            } else {
                return nil
            }
        }
        guard dots <= 1, digits > 0 else { return nil }
        guard let value = Decimal(string: text, locale: locale), !value.isNaN, value >= 0 else { return nil }
        return value
    }
}

/// Turns the text lines of a captured Nutrition Facts panel into a product the intake form can use.
///
/// This is the whole of the capture flow on the UI side, and it is deliberately free of any camera:
/// the app target owns VisionKit, hands over the lines it read, and gets back a `ProductDefinition`
/// only once the user has seen every value the parser was unsure about. Nothing here stores an image
/// and nothing leaves the device — the only input is text.
///
/// What it will not do:
///
/// - A row the panel does not state stays `.unknown`, never `.known(0, _)`.
/// - A value the parser flagged is not saved until the user confirms it or types one of their own.
/// - A panel with no amount at all is not turned into a product: it says so and offers another look.
@MainActor
public final class LabelCaptureViewModel: ObservableObject {
    /// This capture's own identity, so the sheet can be bound to the model rather than to a flag beside
    /// it. It is per instance, so a fresh capture is always a new sheet and a re-presented one is the
    /// same panel.
    public nonisolated let captureID = UUID()
    /// One row per nutrient the journal names, in panel order. Every row is present from the first
    /// load, so the review screen shows a nutrient the panel omits as unknown rather than hiding it.
    @Published public private(set) var rows: [LabelCaptureRow] = []
    /// One row per compound the panel states that the fifteen journal nutrients do not name, in the
    /// order the panel printed them. Shown under its own heading, because these rows are why anyone
    /// scans a supplement panel at all.
    @Published public private(set) var additionalRows: [LabelCaptureAdditionalRow] = []
    /// The serving size as the panel printed it, and the measure it stated when it stated one.
    @Published public private(set) var servingText: String?
    @Published public private(set) var servingQuantity: Quantity?
    @Published public private(set) var servingsPerContainer: Decimal?
    /// The parser had to correct the serving size, so the user is asked about it like any other value.
    @Published public private(set) var servingNeedsReview = false
    @Published public private(set) var isServingConfirmed = false
    /// The panel stated no serving size at all, so the values are per something the user has to name
    /// before they can be used. A serving the panel printed as words is shown as printed instead.
    @Published public private(set) var servingIsMissing = false
    /// Why a serving size the user typed was refused, or nil when the last one was accepted.
    @Published public private(set) var servingSizeError: String?
    /// The panel stated no amount at all, so there is nothing to review.
    @Published public private(set) var isUnreadable = false
    @Published public private(set) var hasPanel = false
    /// Why the last correction was refused, or nil when the last one was accepted.
    @Published public private(set) var correctionError: String?

    /// The nutrient row whose correction field is open, or nil when none is. One row at a time,
    /// because there is one keyboard: opening a compound row's editor closes this one and the other
    /// way round.
    @Published public private(set) var editingKey: NutritionFactKey?
    /// The compound row whose correction field is open, or nil when none is.
    @Published public private(set) var editingAdditionalKey: String?

    /// What kind of product this capture is recorded as, read off the panel's own heading.
    ///
    /// A Supplement Facts panel makes a supplement and anything else a food, which is the whole of what
    /// the heading decides: the rows are read the same way either way. The user can change it on the
    /// review screen, because the two cases the heading cannot see are real — a drink prints a Nutrition
    /// Facts panel, and a heading cropped out of the frame reads as a food — and a wrong kind is what
    /// puts an entry into a coverage count it does not belong in.
    @Published public var kind: ProductKind = .food

    /// The one sentence under the kind row: what the chosen kind does to the day's coverage, said where
    /// the choice is made rather than where its consequences are read.
    public var kindExplanation: String {
        kind == .supplement
            ? "A supplement is left out of the day's food coverage. What it states still counts towards the day's totals."
            : "Foods and drinks are counted in the day's food coverage."
    }

    /// The origin every captured product is stored with, so a later reader can tell that its values
    /// came from a panel the user read on their own device rather than from a catalog.
    public static let catalogOrigin = ProductOrigin.label_capture

    /// The unit a row usually carries, used when a correction is typed for a row the panel printed no
    /// unit for. A correction never changes the unit the panel printed.
    static let usualUnits: [NutritionFactKey: MeasureUnit] = [
        .calories: .kcal, .fat: .g, .saturatedFat: .g, .transFat: .g, .cholesterol: .mg, .sodium: .mg,
        .carbohydrates: .g, .fiber: .g, .sugars: .g, .addedSugars: .g, .protein: .g, .vitaminD: .mcg,
        .calcium: .mg, .iron: .mg, .potassium: .mg,
    ]

    public init() {}

    // MARK: Loading a panel

    /// Reads the lines a capture session produced. Anything already on screen is replaced, because a
    /// second capture is a different panel and the values of the first one are not still true.
    public func load(lines: [String]) {
        let panel = NutritionFactsParser.parse(lines: lines)
        // The heading decides the kind and nothing else does: the rows either way are read as carefully.
        kind = panel.panelKind.productKind
        var loaded: [LabelCaptureRow] = []
        for key in NutritionFactKey.allCases {
            loaded.append(
                LabelCaptureRow(
                    key: key,
                    value: panel.value(for: key),
                    reasons: panel.valuesNeedingReview[key.rawValue]?.reasons ?? [],
                    status: panel.needsReview(key) ? .needsConfirmation : .read,
                    displayName: panel.displayName(for: key)
                )
            )
        }
        rows = loaded
        additionalRows = panel.additionalNutrients.map {
            LabelCaptureAdditionalRow(
                key: $0.key, name: $0.name, value: $0.value, reasons: $0.review?.reasons ?? [],
                status: $0.review == nil ? .read : .needsConfirmation)
        }
        servingText = panel.servingSize?.text
        servingQuantity = panel.servingSize?.quantity
        servingsPerContainer = panel.servingsPerContainer
        servingNeedsReview = panel.servingSize?.review != nil
        isServingConfirmed = false
        // Only a serving size the panel never stated is asked for. One it printed as words is shown as
        // printed: the panel's own words are what the user checks, and the basis carries them.
        servingIsMissing = panel.servingSize == nil
        servingSizeError = nil
        isUnreadable = panel.isUnreadable
        hasPanel = true
        correctionError = nil
        editingKey = nil
        editingAdditionalKey = nil
    }

    /// Forgets the panel on screen so the capture session can read another one.
    public func retake() {
        rows = []
        additionalRows = []
        kind = .food
        servingText = nil
        servingQuantity = nil
        servingsPerContainer = nil
        servingNeedsReview = false
        isServingConfirmed = false
        servingIsMissing = false
        servingSizeError = nil
        isUnreadable = false
        hasPanel = false
        correctionError = nil
        editingKey = nil
        editingAdditionalKey = nil
    }

    // MARK: Reviewing

    public func row(for key: NutritionFactKey) -> LabelCaptureRow? {
        rows.first { $0.key == key }
    }

    /// The user agrees with a value the parser flagged.
    public func confirm(_ key: NutritionFactKey) {
        guard let index = rows.firstIndex(where: { $0.key == key }) else { return }
        guard rows[index].isFlagged else { return }
        rows[index].status = .confirmed
        correctionError = nil
    }

    /// The compound row the panel printed under `key`, under the name the label used for it, or nil
    /// when the panel stated no such row.
    public func additionalNutrient(for key: String) -> LabelCaptureAdditionalRow? {
        additionalRows.first { $0.key == key }
    }

    /// The user agrees with a compound row the parser flagged. Returns whether the row was there to
    /// answer, so a caller can tell a real confirmation from a key the panel never printed.
    @discardableResult
    public func confirmAdditional(key: String) -> Bool {
        guard let index = additionalRows.firstIndex(where: { $0.key == key }) else { return false }
        additionalRows[index].status = .confirmed
        correctionError = nil
        return true
    }

    /// The units a compound correction may be stated in: the mass units and the international unit a
    /// supplement states a compound in. The screen offers them as a picker beside the decimal field,
    /// so a compound correction never relies on letters typed into the amount.
    public static let additionalUnits: [MeasureUnit] = [.g, .mg, .mcg, .iu]

    /// The unit a compound correction starts on: the one the label printed.
    public func additionalUnit(for key: String) -> MeasureUnit {
        guard let row = additionalRows.first(where: { $0.key == key }) else { return .g }
        return Self.unit(of: row.value)
    }

    /// The user replaces a compound's amount with one they typed, in the unit the picker states.
    ///
    /// Read and checked like a nutrient correction, with one difference: a compound has no usual unit to
    /// fall back on, so the unit is chosen rather than typed. A unit of another dimension than the one
    /// the label printed is refused, because nothing downstream could interpret the value.
    @discardableResult
    public func correctAdditional(key: String, text: String, unit chosen: MeasureUnit) -> Bool {
        guard let index = additionalRows.firstIndex(where: { $0.key == key }) else { return false }
        guard additionalRows[index].canBeCorrected else { return false }
        guard let parsed = NutrientAmountParser.parse(text) else {
            correctionError = "Enter zero or more, using digits and a point."
            return false
        }
        let printed = Self.unit(of: additionalRows[index].value)
        guard chosen.dimension == printed.dimension else {
            correctionError =
                "\(additionalRows[index].name) is measured \(Self.describe(printed.dimension)), so the amount has to be in a unit of that kind."
            return false
        }
        additionalRows[index].value = .known(parsed.value, chosen)
        additionalRows[index].status = .corrected
        correctionError = nil
        return true
    }

    /// Opens a nutrient row's correction field, closing a compound row's field beside it: there is one
    /// keyboard, so only one editor is open at a time.
    public func beginCorrection(for key: NutritionFactKey) {
        correctionError = nil
        editingAdditionalKey = nil
        editingKey = key
    }

    /// Opens a compound row's correction field, closing a nutrient row's field beside it.
    public func beginCorrection(forAdditional key: String) {
        correctionError = nil
        editingKey = nil
        editingAdditionalKey = key
    }

    /// Closes whichever correction field is open, so the screen shows the row's controls again.
    public func endCorrection() {
        editingKey = nil
        editingAdditionalKey = nil
    }

    /// Puts away the message from a correction that was refused.
    ///
    /// The error belongs to the correction the user just cancelled or moved away from, so it is not left
    /// standing under the next row's amount field: a validation failure that belongs to one row must not
    /// greet the user in another one before they have typed anything there.
    public func clearCorrectionError() {
        correctionError = nil
    }

    /// The user accepts the serving size the parser corrected.
    ///
    /// Confirming resolves the flag as well as recording the answer, so the serving size stops counting
    /// as pending and the screen stops asking about it. The flag describes a question the parser raised
    /// and the user has now answered; leaving it standing would keep `canApply` false for a serving size
    /// nobody is being asked about any more.
    public func confirmServing() {
        guard servingNeedsReview else { return }
        isServingConfirmed = true
        servingNeedsReview = false
        correctionError = nil
    }

    /// The user states what one serving is, because the panel did not say.
    ///
    /// A serving the panel printed has nothing to enter and is replaced with `correctServingSize(text:)`
    /// instead; this is only for the case where there is nothing on screen to correct.
    @discardableResult
    public func enterServingSize(text: String) -> Bool {
        guard servingIsMissing else { return false }
        return applyServingSize(text)
    }

    /// The user replaces a serving size the panel printed. The printed line is read text like any other,
    /// so it is as easy to misread as a nutrient row, and it scales every value below it besides.
    ///
    /// There is no dimension to check here, unlike a nutrient: a serving may be weighed, poured or counted,
    /// so mass, volume and count units are all one serving of something.
    @discardableResult
    public func correctServingSize(text: String) -> Bool {
        guard !servingIsMissing, servingText != nil else { return false }
        guard applyServingSize(text) else { return false }
        // Replacing the printed serving size is an answer, not a question left standing.
        servingNeedsReview = false
        return true
    }

    /// Whether the screen offers to correct the serving size, which it does whenever the panel stated one:
    /// a serving that was never stated is entered, not corrected.
    public var servingCanBeCorrected: Bool { !servingIsMissing && servingText != nil }

    /// Takes one serving as the user stated it.
    ///
    /// An amount with its unit is required, and a unit is required with it: a serving stated as a household
    /// word alone ("a biscuit") leaves every amount on the panel as ambiguous as it was, and a per-serving
    /// value nobody can scale is not worth storing. A serving of zero is refused for the same reason an
    /// intake of zero is: it says nothing. Text that does not state an amount changes nothing and says why.
    private func applyServingSize(_ text: String) -> Bool {
        guard let parsed = NutrientAmountParser.parse(text), parsed.value > 0, let unit = parsed.unit else {
            servingSizeError = "Enter what one serving is, as an amount with its unit, for example 30 g or 240 mL."
            return false
        }
        servingText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        servingQuantity = Quantity(value: parsed.value, unit: unit)
        servingIsMissing = false
        isServingConfirmed = true
        servingSizeError = nil
        return true
    }

    /// Replaces a value with one the user typed, in the unit the text named or in the unit the panel
    /// printed.
    ///
    /// The text is read with `NutrientAmountParser`, so a correction is never stored as something the
    /// intake form would have refused, and a stated zero is a correction rather than a mistake: a panel
    /// says `0g` often. Text the parser does not accept changes nothing and returns false, and says why;
    /// the row keeps waiting for the user either way.
    ///
    /// Any row the parser read an amount for can be corrected, not only a flagged one: recognition can
    /// read one valid number as another valid one, and then nothing is flagged while the value on screen
    /// is still wrong.
    @discardableResult
    public func correct(key: NutritionFactKey, text: String) -> Bool {
        guard let index = rows.firstIndex(where: { $0.key == key }) else { return false }
        guard rows[index].canBeCorrected else { return false }
        guard let parsed = NutrientAmountParser.parse(text) else {
            correctionError = "Enter zero or more, using digits and a point, and add the unit if you want a different one."
            return false
        }
        // A unit of another dimension is refused rather than stored: a litre of sodium or a gram of
        // calories cannot be interpreted by anything downstream, which would drop the value in silence.
        // Another unit of the same dimension is fine, so mg may be restated as g.
        let dimension = Self.expectedDimension(for: key)
        if let named = parsed.unit, named.dimension != dimension {
            correctionError =
                "\(rows[index].name) is measured \(Self.describe(dimension)), so the amount has to be in a unit of that kind."
            return false
        }
        let unit = parsed.unit ?? Self.unit(of: rows[index].value, for: key)
        rows[index].value = .known(parsed.value, unit)
        rows[index].status = .corrected
        correctionError = nil
        return true
    }

    /// The dimension a nutrient is measured in, which is what a correction's own unit has to agree with.
    ///
    /// It is the nutrient's expected dimension rather than the one a particular capture happened to read.
    /// The unit on the panel is sometimes the reason a row was flagged in the first place, so trusting it
    /// would let a correction follow the capture into a dimension nothing downstream can interpret — and
    /// a value silently dropped later is worse than a refused correction here.
    static func expectedDimension(for key: NutritionFactKey) -> UnitDimension {
        usualUnits[key]?.dimension ?? .mass
    }

    /// How a dimension is named in a sentence about it.
    static func describe(_ dimension: UnitDimension) -> String {
        switch dimension {
        case .mass: return "by weight"
        case .volume: return "by volume"
        case .energy: return "in energy units"
        case .count: return "in counts"
        case .internationalUnit: return "in international units"
        }
    }

    /// The unit a corrected value keeps: the one the panel printed, or the one this row usually
    /// carries when the panel printed none. A correction never moves a value between units.
    static func unit(of value: NutrientValue, for key: NutritionFactKey) -> MeasureUnit {
        switch value {
        case .known(_, let unit):
            return unit
        case .belowReportingThreshold(let unit):
            if let unit { return unit }
        case .unknown, .notApplicable:
            break
        }
        return usualUnits[key] ?? .g
    }

    /// The unit a value already carries, or grams when it carries none. A compound is stored with the
    /// unit the label printed, so this is the unit its corrections keep.
    static func unit(of value: NutrientValue) -> MeasureUnit {
        switch value {
        case .known(_, let unit):
            return unit
        case .belowReportingThreshold(let unit):
            return unit ?? .g
        case .unknown, .notApplicable:
            return .g
        }
    }

    /// How many values are still waiting for the user: the flagged rows they have not answered, a
    /// serving size the parser corrected or the panel left out, and nothing else.
    public var pendingCount: Int {
        var pending = rows.filter(\.isPending).count
        pending += additionalRows.filter(\.isPending).count
        if servingIsMissing || (servingNeedsReview && !isServingConfirmed) { pending += 1 }
        return pending
    }

    /// Whether the captured values may be used. False while a value the parser was unsure about is
    /// unanswered, false for a panel that stated no amount at all, and false while one serving is still
    /// unstated: per-serving numbers that cannot be scaled are not worth saving.
    public var canApply: Bool {
        hasPanel && !isUnreadable && !rows.isEmpty && pendingCount == 0
    }

    /// Whether the screen can offer another look at the panel. There is nothing to look at again until
    /// a capture has been loaded, whether that capture was readable or not.
    public var canRetake: Bool { hasPanel }

    /// One line for the screen: why nothing can be used yet, or what is left to check.
    public var statusMessage: String? {
        if isUnreadable {
            return "That panel could not be read. Nothing was scanned in, so nothing is saved. Try again with the panel flat and the text in focus."
        }
        guard hasPanel else { return nil }
        let pending = pendingCount
        if pending == 0 {
            let known = rows.filter { $0.value != .unknown }.count
            return "Read \(known) of \(rows.count) rows. A nutrient the panel does not state stays unknown."
        }
        let pendingRows = rows.filter(\.isPending).count + additionalRows.filter(\.isPending).count
        var parts: [String] = []
        if pendingRows == 1 {
            parts.append("1 value needs your confirmation")
        } else if pendingRows > 1 {
            parts.append("\(pendingRows) values need your confirmation")
        }
        if servingIsMissing {
            parts.append("the panel's serving size was not read, so enter what one serving is")
        } else if servingNeedsReview && !isServingConfirmed {
            parts.append("the serving size needs your confirmation")
        }
        return parts.joined(separator: ", ") + " before these values can be used."
    }

    /// The prompt above the serving-size field, or nil when there is nothing to ask for: a serving the
    /// panel printed is either fine or, when the parser corrected it, answered by confirming it.
    public var servingPrompt: String? {
        if servingIsMissing {
            return "The serving size was not read from that shot. Enter what one serving is, so the values below can be scaled to how much you actually have."
        }
        if servingNeedsReview && !isServingConfirmed {
            return "The parser had to correct this serving size. Confirm it, or scan the panel again."
        }
        return nil
    }

    // MARK: The product

    /// The product these reviewed values make, or nil while the panel is unreadable or a flagged value
    /// is still unanswered.
    ///
    /// The snapshot records where the values came from (`label_capture`), that they are per serving
    /// with the serving spelled out when the panel stated one, and only the values that are known and
    /// answered. A nutrient the panel did not state is left out rather than stored as zero, and
    /// `ProductDefinition.value(for:)` reads it back as unknown.
    public func makeProduct() -> ProductDefinition? {
        guard canApply else { return nil }
        var nutrients: [String: NutrientValue] = [:]
        var displayNames: [String: String] = [:]
        for row in rows where row.value != .unknown && !row.isPending {
            nutrients[row.key.rawValue] = row.value
            // The panel may have printed a chemical form for a named nutrient (`Calcium Citrate`),
            // which is kept as that row's display name so the screens keep the label's own words.
            if let name = row.displayName { displayNames[row.key.rawValue] = name }
        }
        // A compound the panel printed and the user answered is stored under its own slug, beside the
        // fifteen named nutrients: it has no key in the journal's own table, and dropping it would
        // lose the reason anyone scanned a supplement panel. The label's own words travel with it, so
        // a slug that does not spell back to them (`dha` -> `DHA`) still reads right.
        for row in additionalRows where row.value != .unknown && !row.isPending {
            nutrients[row.key] = row.value
            displayNames[row.key] = row.name
        }
        let basis = Self.labelBasis(servingText: servingText, quantity: servingQuantity)
        var signature = basis
        // The kind is part of what this panel is, so two captures of the same rows that mean different
        // things are two products: a drink and a food state the same panel, and a snapshot id that could
        // name both would make the second save of it a conflict rather than a second record.
        signature += "|kind=" + kind.rawValue
        if let servingsPerContainer {
            signature += "|servings=" + "\(NSDecimalNumber(decimal: servingsPerContainer).stringValue)"
        }
        for row in rows {
            signature += "|" + row.key.rawValue + "=" + LabelCaptureRow.describe(row.value)
            if let name = row.displayName { signature += "|name:" + row.key.rawValue + "=" + name }
        }
        for row in additionalRows {
            signature += "|extra:" + row.key + "=" + LabelCaptureRow.describe(row.value)
            signature += "|extra-name:" + row.key + "=" + row.name
        }
        return ProductDefinition(
            snapshotID: "label-" + AddIntakeViewModel.slug(signature) + "-" + LookedUpProduct.checksum(signature),
            productID: Self.catalogOrigin,
            name: "",
            labelBasis: basis,
            catalogOrigin: Self.catalogOrigin,
            catalogVersion: "unknown",
            kind: kind,
            nutrients: nutrients,
            nutrientDisplayNames: displayNames
        )
    }

    /// The basis as it is stored: per serving, with the serving spelled out when the panel stated one,
    /// so a reader of the journal sees "per serving (240 mL)" rather than a bare "per serving".
    public static func labelBasis(servingText: String?, quantity: Quantity?) -> String {
        let basis = BarcodeLookupBasis.perServing.label
        if let quantity {
            return "\(basis) (\(NSDecimalNumber(decimal: quantity.value).stringValue) \(quantity.unit.symbol))"
        }
        let trimmed = servingText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return "\(basis) (\(trimmed))"
        }
        return basis
    }
}

/// The sheet that presents a capture is bound to the view model itself rather than to a flag beside it,
/// so the model has to say which capture it is: one panel is on screen at a time, and a second capture
/// is a different one.
extension LabelCaptureViewModel: Identifiable {
    public var id: UUID { captureID }
}
