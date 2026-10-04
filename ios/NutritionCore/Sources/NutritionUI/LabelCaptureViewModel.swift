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
    /// The value and what the user has done about it. Both are mutable because a row is a value type
    /// in the view model's array: confirming or correcting one writes through `rows[index]`, which is
    /// also what republishes the array for the screen.
    public var value: NutrientValue
    public var status: Status

    /// Written out rather than left as the memberwise initializer, so the order of the fields is not
    /// the order of the arguments and adding a field later cannot silently reorder a call site.
    public init(key: NutritionFactKey, value: NutrientValue, reasons: Set<ParsedValueReview.Reason>, status: Status) {
        self.key = key
        self.value = value
        self.reasons = reasons
        self.status = status
    }

    public var id: String { key.rawValue }
    public var name: String { LabelCaptureRow.displayNames[key] ?? key.rawValue }
    public var isFlagged: Bool { !reasons.isEmpty }
    public var needsConfirmation: Bool { status == .needsConfirmation }
    /// The row still waits for the user, so nothing may be saved yet.
    public var isPending: Bool { status == .needsConfirmation }

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
        guard isFlagged else { return "" }
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
    /// One row per nutrient the journal names, in panel order. Every row is present from the first
    /// load, so the review screen shows a nutrient the panel omits as unknown rather than hiding it.
    @Published public private(set) var rows: [LabelCaptureRow] = []
    /// The serving size as the panel printed it, and the measure it stated when it stated one.
    @Published public private(set) var servingText: String?
    @Published public private(set) var servingQuantity: Quantity?
    @Published public private(set) var servingsPerContainer: Decimal?
    /// The parser had to correct the serving size, so the user is asked about it like any other value.
    @Published public private(set) var servingNeedsReview = false
    @Published public private(set) var isServingConfirmed = false
    /// The panel stated no amount at all, so there is nothing to review.
    @Published public private(set) var isUnreadable = false
    @Published public private(set) var hasPanel = false
    /// Why the last correction was refused, or nil when the last one was accepted.
    @Published public private(set) var correctionError: String?

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
        var loaded: [LabelCaptureRow] = []
        for key in NutritionFactKey.allCases {
            loaded.append(
                LabelCaptureRow(
                    key: key,
                    value: panel.value(for: key),
                    reasons: panel.valuesNeedingReview[key.rawValue]?.reasons ?? [],
                    status: panel.needsReview(key) ? .needsConfirmation : .read
                )
            )
        }
        rows = loaded
        servingText = panel.servingSize?.text
        servingQuantity = panel.servingSize?.quantity
        servingsPerContainer = panel.servingsPerContainer
        servingNeedsReview = panel.servingSize?.review != nil
        isServingConfirmed = false
        isUnreadable = panel.isUnreadable
        hasPanel = true
        correctionError = nil
    }

    /// Forgets the panel on screen so the capture session can read another one.
    public func retake() {
        rows = []
        servingText = nil
        servingQuantity = nil
        servingsPerContainer = nil
        servingNeedsReview = false
        isServingConfirmed = false
        isUnreadable = false
        hasPanel = false
        correctionError = nil
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

    /// The user accepts the serving size the parser corrected.
    public func confirmServing() {
        guard servingNeedsReview else { return }
        isServingConfirmed = true
        correctionError = nil
    }

    /// Replaces a value with one the user typed, in the unit the panel printed.
    ///
    /// The text is checked with the same amount parser the intake form uses, so a correction is never
    /// stored as something the form would have refused. Text it does not accept changes nothing and
    /// returns false; the row keeps waiting for the user either way.
    @discardableResult
    public func correct(key: NutritionFactKey, text: String) -> Bool {
        guard let index = rows.firstIndex(where: { $0.key == key }) else { return false }
        guard let amount = AmountParser.parse(text) else {
            correctionError = "Enter an amount greater than zero, using digits and a point."
            return false
        }
        let unit = Self.unit(of: rows[index].value, for: key)
        rows[index].value = .known(amount, unit)
        rows[index].status = .corrected
        correctionError = nil
        return true
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

    /// How many values are still waiting for the user: the flagged rows they have not answered, plus
    /// a flagged serving size.
    public var pendingCount: Int {
        rows.filter(\.isPending).count + (servingNeedsReview && !isServingConfirmed ? 1 : 0)
    }

    /// Whether the captured values may be used. False while a value the parser was unsure about is
    /// unanswered, and false for a panel that stated no amount at all.
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
        let rowsPhrase = pending == 1 ? "1 value needs your confirmation" : "\(pending) values need your confirmation"
        return "\(rowsPhrase) before these values can be used."
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
        for row in rows where row.value != .unknown && !row.isPending {
            nutrients[row.key.rawValue] = row.value
        }
        let basis = Self.labelBasis(servingText: servingText, quantity: servingQuantity)
        var signature = basis
        if let servingsPerContainer {
            signature += "|servings=" + "\(NSDecimalNumber(decimal: servingsPerContainer).stringValue)"
        }
        for row in rows {
            signature += "|" + row.key.rawValue + "=" + LabelCaptureRow.describe(row.value)
        }
        return ProductDefinition(
            snapshotID: "label-" + AddIntakeViewModel.slug(signature) + "-" + LookedUpProduct.checksum(signature),
            productID: Self.catalogOrigin,
            name: "",
            labelBasis: basis,
            catalogOrigin: Self.catalogOrigin,
            catalogVersion: "unknown",
            nutrients: nutrients
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
