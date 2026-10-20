import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders

/// Parses amount text with a fixed POSIX format: digits with at most one ".", no locale, no sign.
public enum AmountParser {
    public static let locale = Locale(identifier: "en_US_POSIX")

    /// Returns a positive Decimal, or nil for anything else.
    public static func parse(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var dots = 0
        var digits = 0
        for character in trimmed {
            if character == "." {
                dots += 1
            } else if character.isASCII, character.isNumber {
                digits += 1
            } else {
                return nil
            }
        }
        guard dots <= 1, digits > 0 else { return nil }
        guard let value = Decimal(string: trimmed, locale: locale), !value.isNaN, value > 0 else { return nil }
        return value
    }

    /// Reads an amount a person typed into a field.
    ///
    /// The decimal pad offers the separator of the device's region, so where that is a comma a typed
    /// "2,5" means two and a half. It is read as such only there, and only when it is the one separator
    /// in the text: "1,000" typed where the separator is a point is refused as before rather than read
    /// as one, and "1.234,5" is refused everywhere. A point is accepted in every region. Stored text is
    /// never read through this; it goes through `parse`, which stays independent of the region.
    public static func parseTyped(
        _ text: String, decimalSeparator: String? = Locale.current.decimalSeparator
    ) -> Decimal? {
        parse(normalizedTyped(text, decimalSeparator: decimalSeparator))
    }

    /// Typed text with the region's comma rewritten as a point, under the rule `parseTyped` states, and
    /// otherwise as typed. For the fields whose own parser allows more than `parse` does, such as a zero
    /// or a unit after the number.
    public static func normalizedTyped(
        _ text: String, decimalSeparator: String? = Locale.current.decimalSeparator
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard decimalSeparator == ",", !trimmed.contains("."),
            trimmed.filter({ $0 == "," }).count == 1
        else { return trimmed }
        return trimmed.replacingOccurrences(of: ",", with: ".")
    }
}

/// Where the last barcode lookup stands. A lookup only ever starts from an explicit user action,
/// so there is no state that changes while the user types.
public enum BarcodeLookupState: Sendable, Equatable {
    case idle
    case loading
    case found(LookedUpProduct)
    case notFound
    case invalidBarcode
    /// How long the source asked the caller to wait, when it said.
    case rateLimited(retryAfterSeconds: Int?)
    case failed(String)
    /// The request could not reach the source: no connection, or a network that dropped it.
    case offline

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

public struct ThisAddsLine: Equatable {
    public let key: String
    public let displayName: String
    public let value: NutrientValue?
    /// The product states this nutrient, but the logged amount cannot be scaled to its basis.
    public let cannotScale: Bool
    public var text: String {
        cannotScale ? LookedUpProduct.cannotScaleText : LookedUpProduct.shownScaledText(value ?? .unknown)
    }
}

extension LookedUpProduct {
    /// The line for a nutrient the product states when the logged amount cannot be scaled to its basis.
    static let cannotScaleText = "Can't be worked out for this amount"

    /// Whether a value says something the label printed: an amount, or a bound.
    static func statesAmount(_ value: NutrientValue) -> Bool {
        switch value {
        case .known, .belowReportingThreshold: return true
        case .unknown, .notApplicable: return false
        }
    }

    /// The words a person sees for a value. `describe` keeps the stored words, which are hashed into
    /// snapshot ids and must never change; this is for text on screen only, so a figure longer than a label
    /// prints is read as `AmountDisplay.stated` reads it.
    static func shownText(_ value: NutrientValue) -> String {
        switch value {
        case .known(let amount, let unit): return AmountDisplay.stated(amount, unit: unit).text
        case .unknown: return "Not on the label"
        case .notApplicable: return "Does not apply"
        case .belowReportingThreshold(let unit):
            return "Less than the label reports" + (unit.map { " (\($0.screenSymbol))" } ?? "")
        }
    }

    /// A label value scaled to the amount logged, in words. Scaling can leave every digit a `Decimal`
    /// holds, so an amount is rounded the way Today rounds a total; anything else reads as `shownText`.
    static func shownScaledText(_ value: NutrientValue) -> String {
        guard case .known(let amount, let unit) = value else { return shownText(value) }
        return AmountDisplay.nutrient(amount, unit: unit).text
    }
}

/// A volume typed in cups, tablespoons or teaspoons, stored as grams from the typical density of the food
/// the name matched. The name is the catalog's, which is what the form shows.
public struct DensityConversion: Equatable, Sendable {
    public let grams: Decimal
    public let ingredientName: String
}

/// The fields of the Add form that can carry an error.
public enum AddIntakeField: Sendable, Hashable {
    case name
    case amount
}

@MainActor
public final class AddIntakeViewModel: ObservableObject {
    /// This form's own identity, so the sheet can be bound to the model rather than to a flag beside
    /// it. It is per instance, so a second add is always a new sheet.
    public nonisolated let formID = UUID()
    @Published public private(set) var customProduct: CustomProductRevision?
    public var isCustomProduct: Bool { customProduct != nil }
    @Published public var name: String = "" {
        didSet { editedFields.insert(.name) }
    }
    @Published public var brand: String = ""
    @Published public var barcode: String = ""
    @Published public var amountText: String = "" {
        didSet {
            editedFields.insert(.amount)
            if !isPrefilling && !isSettingServings,
               AmountParser.parseTyped(amountText, decimalSeparator: countDecimalSeparator) != nil {
                unitNotice = nil
            }
            // A figure written by anything but the prefill no longer stands for the stored amount.
            if !isPrefilling { prefillBacking = nil }
            // An amount typed by hand no longer equals a count of servings.
            if !isPrefilling && !isSettingServings {
                servingCount = ""
                amountFromServings = false
            }
        }
    }
    /// How many servings the amount stands for, when the picked product gave a serving size. Typing a
    /// count writes the amount; typing an amount clears the count.
    @Published public private(set) var servingCount: String = ""
    /// The serving size the source gave, kept whatever the basis, so the amount can open on one serving.
    @Published public private(set) var servingOption: ServingDefinition?
    private var isSettingServings = false
    /// The separator a typed count is read with: the device's, unless a test sets another.
    private let countDecimalSeparator: String?
    /// Grams for one cup, tablespoon or teaspoon, as the picked food's own record lists them. Empty when none is listed.
    @Published public private(set) var listedPortions: [MeasureUnit: Decimal] = [:]
    private let portionLookup: (any HouseholdPortionLookup)?
    /// Whether the picked food's measures have been asked for, so focusing the amount again sends nothing new.
    private var portionsAsked = false
    /// Whether the asked-for measures have come back, or the request has failed.
    private var portionsLoaded = false
    /// True while the amount is the one a count of servings set, so an emptied Servings field can clear it.
    private var amountFromServings = false
    /// Why a typed amount was cleared when a pick came in with a unit it cannot total in. Nil otherwise; it
    /// goes once the person types an amount.
    @Published public private(set) var unitNotice: String?
    @Published public var unit: MeasureUnit = .g {
        didSet {
            // A count of servings was for the unit it was typed against; a different unit clears it.
            if !isPrefilling && !isSettingServings {
                servingCount = ""
                amountFromServings = false
            }
        }
    }
    @Published public var category: String = "food"
    @Published public var occurredAt: Date
    /// Which meal of the day this entry was eaten at. Nil by default and never inferred from the
    /// hour: the label is the person's own answer, and guessing one for them would put a word in
    /// their record that they never gave.
    @Published public var meal: MealLabel?
    /// What kind of thing this entry is: a food, a drink or a supplement. Food unless something says
    /// otherwise, which is the honest default for a form that is mostly typed by hand.
    ///
    /// The kind is written onto the product snapshot the entry carries, so a scanned drink or a typed
    /// supplement keeps it; and the day's coverage counts only the kinds that are foods and drinks. An
    /// typed non-food entry carries a minimal manual snapshot so its kind survives saving.
    /// A typed food without a snapshot keeps the existing food default.
    @Published public var kind: ProductKind = .food {
        didSet { hasChosenKind = true }
    }
    private var hasChosenKind = false
    @Published public private(set) var saveError: String?
    /// Why the last tap of Save did nothing, or nil when it is not blocked: the sentence that points at the
    /// marked fields, never a repeat of their errors, since each error is shown under its own field.
    ///
    /// It is derived from the current fields, so it goes as soon as both are right, without another tap of
    /// Save. A long form scrolls, so the sentence sits beside the Save button, where a Save that silently
    /// refused would otherwise look like a button that is broken.
    public var saveBlockedMessage: String? {
        hasAttemptedSave && (nameError != nil || amountError != nil) ? Self.fixFieldsMessage : nil
    }

    /// Whether this entry's product can be kept in Library > Products or left out: a barcode, label or search
    /// product, not a typed-in or quick-add entry. Only these show the "Save to Library" switch.
    public var canChooseLibrary: Bool {
        guard let product = productSnapshot() else { return false }
        return !Self.libraryLeftOutOrigins.contains(product.catalogOrigin)
    }

    /// The origins Library > Products leaves out (`LibraryViewModel.foods()`): typed-in, quick-add and recipe entries.
    private static let libraryLeftOutOrigins: Set<String> = [
        "manual", IntakeContextFactCatalog.quickAddOrigin, RecipeLogger.catalogOrigin,
    ]

    /// What Save does beyond the Diary entry, shown above the Save button. A product from a barcode, a label or a
    /// search is also saved to Library > Products unless "Save to Library" is off; a typed-in or quick-add entry
    /// is not. When Share labels is on, a captured label is also sent to the community catalog.
    public var saveScopeMessage: String {
        let savedToProducts = canChooseLibrary && savesToLibrary
        var sentences = [savedToProducts
            ? "Adds one entry to your Diary. The product is also saved to Library > Products."
            : "Adds one entry to your Diary only."]
        // The same checks the save path uses to send a label, so the line promises only an upload that will happen.
        if prefilledFromCapture, labelValues != nil, storedProduct == nil, labelSubmitter != nil, isSharingAllowed(),
           communitySubmission() != nil {
            sentences.append("Share labels is on, so saving this label also sends its product name, brand, barcode, serving text and nutrient amounts to the community catalog.")
        }
        return sentences.joined(separator: " ")
    }
    /// Whether a tap of Save has been made on this form. Once it has, every field that is wrong shows its error.
    @Published public private(set) var hasAttemptedSave = false
    /// The fields edited so far, and the fields focus has left since. An error shows under a field once
    /// both are true, so a person is not told a field is wrong while they are still typing in it.
    private var editedFields: Set<AddIntakeField> = []
    /// What a prefilled amount stands for: the figure shown in the reader's unit, and the exact stored amount
    /// behind it. Saving the form untouched writes the stored amount, so a rounded reading never restates it.
    private var isPrefilling = false
    private var prefillBacking: (shownAmount: Decimal, shownUnit: MeasureUnit, storedAmount: Decimal, storedUnit: MeasureUnit)?

    /// Shows a stored amount in the reader's unit while keeping the exact stored quantity behind it.
    func prefillAmount(_ component: IntakeComponent, system: UnitSystem, loggedUnit: MeasureUnit? = nil) {
        isPrefilling = true
        defer { isPrefilling = false }
        // An amount logged by the spoon opens in that spoon, with the exact stored milliliters behind it.
        let shown = component.unit == .mL
            ? loggedUnit.flatMap { AmountDisplay.reading(milliliters: component.amount, loggedAs: $0) }
                ?? AmountDisplay.display(component, system: system, roundsStoredUnit: true)
            : AmountDisplay.display(component, system: system, roundsStoredUnit: true)
        guard !shown.isBelowSmallest, !component.amount.isNaN else {
            amountText = DecimalFormatting.text(component.amount)
            unit = component.unit
            prefillBacking = nil
            return
        }
        amountText = DecimalFormatting.text(shown.amount)
        unit = shown.unit
        prefillBacking = (shown.amount, shown.unit, component.amount, component.unit)
    }
    private var leftFields: Set<AddIntakeField> = []
    /// The volume units whose typed amount is stored as milliliters and worth reading back as typed.
    static let loggedVolumeUnits: Set<MeasureUnit> = [.teaspoon, .tablespoon, .cup, .flOz]
    @Published public private(set) var lookupState: BarcodeLookupState = .idle
    /// Nutrients prefilled from the last successful lookup; a nutrient the source did not give
    /// stays `.unknown` and is never stored as zero.
    @Published public private(set) var prefilledNutrients: [String: NutrientValue] = [:]
    @Published public private(set) var lookupBasis: BarcodeLookupBasis?
    /// The basis of a label the camera captured, so the amount preview can scale it like a looked-up product.
    @Published private(set) var capturedLabelBasis: String?
    /// What one serving is, when the values are per serving.
    @Published public private(set) var serving: ServingDefinition?
    /// The attribution the source requires next to its values.
    @Published public private(set) var attribution: ProductAttribution?
    /// The product the prefilled values came from, written as a snapshot on save. Nil until a lookup
    /// succeeds, so an entry typed by hand stays exactly as it was, and nil again as soon as a later
    /// lookup finds nothing.
    @Published public private(set) var lookedUp: LookedUpProduct?
    /// The product the values came from when the user captured a Nutrition Facts panel instead of
    /// looking a barcode up. It is written as the snapshot on save, with `catalogOrigin` naming the
    /// capture, and it is nil again as soon as anything else puts values into the form.
    @Published public private(set) var labelValues: ProductDefinition?
    /// Whether `labelValues` was handed over by the label capture itself. A panel reused from an entry or a
    /// Library repeat arrives through the same method but is not a capture, so it is never shared.
    private var prefilledFromCapture = false
    private var storedProduct: ProductDefinition?
    /// The name and brand the last successful lookup filled in, so a later lookup can tell an edited
    /// field from one it filled itself.
    private var filledName: String?
    private var filledBrand: String?

    /// The zone a new entry is stamped with. Read at save, through the same resolver the Diary uses (#539).
    private let zoneID: () -> String
    public var timeZoneIdentifier: String { zoneID() }
    /// The units the picker offers, read through so a preference changed on another screen is
    /// honored the next time this form is opened. Metric offers the whole registry; the US system
    /// puts ounces, fluid ounces, cups, tablespoons and teaspoons first.
    public var units: [MeasureUnit] { UnitSelection.offered(for: preferences.unitSystem) }
    /// The unit system the offered list is built from.
    public var unitSystem: UnitSystem { preferences.unitSystem }

    /// The units the Unit menu offers. A product stated per 100 g or per 100 mL can only be totalled in the
    /// dimension it is stated in; a "serving" or a count logged against it saves unknown values for the day.
    public var unitOptions: [MeasureUnit] {
        switch lookedUp?.basis {
        case .per100g?: return units.filter { $0.dimension == .mass || listedPortions[$0] != nil }
        case .per100ml?: return units.filter { $0.dimension == .volume }
        default: return units
        }
    }

    private let store: JournalStore
    private let preferences: DisplayPreferences
    private let makeID: () -> String
    private let lookup: BarcodeProductLookup?
    /// Where a label the person captured is sent for the community catalog. Nil means nothing is sent.
    private let labelSubmitter: CommunityLabelSubmitting?
    /// Whether the person has sharing on at this moment. It is asked after each save, never remembered.
    private let isSharingAllowed: @MainActor () -> Bool
    /// The upload started by the last save, when one was. The form never waits for it; tests do.
    private(set) var uploadTask: Task<Void, Never>?
    /// Whether this device can scan a label. The wording that points a person at the scanner depends on it.
    public let labelScannerAvailable: Bool
    /// Counts the lookups this form has started. A reply is applied only if it is still the newest
    /// one and the field still holds the barcode that was asked for.
    private var lookupGeneration = 0

    public var canLookUpBarcode: Bool { lookup != nil }

    public init(
        store: JournalStore,
        now: Date,
        timeZoneIdentifier: String? = nil,
        timeZoneProvider: @escaping () -> String = { DiaryZone.identifier() },
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() },
        lookup: BarcodeProductLookup? = nil,
        preferences: DisplayPreferences = InMemoryDisplayPreferences(),
        labelScannerAvailable: Bool = true,
        labelSubmitter: CommunityLabelSubmitting? = nil,
        isSharingAllowed: @escaping @MainActor () -> Bool = { false },
        countDecimalSeparator: String? = Locale.current.decimalSeparator,
        portionLookup: (any HouseholdPortionLookup)? = nil
    ) {
        self.store = store
        self.countDecimalSeparator = countDecimalSeparator
        self.portionLookup = portionLookup
        self.occurredAt = now
        self.zoneID = IntakeRepeater.resolver(override: timeZoneIdentifier, provider: timeZoneProvider)
        self.makeID = makeID
        self.lookup = lookup
        self.preferences = preferences
        self.labelScannerAvailable = labelScannerAvailable
        self.labelSubmitter = labelSubmitter
        self.isSharingAllowed = isSharingAllowed
        // A new entry starts in the unit system's weight unit: ounces under US units, grams under metric.
        self.unit = AmountDisplay.massUnit(for: preferences.unitSystem)
    }

    private var prefilledProduct: ProductDefinition? { storedProduct ?? labelValues }

    public var hasPrefilledValues: Bool { prefilledNutrients.values.contains { LookedUpProduct.statesAmount($0) } }

    public var sourceLine: String? {
        if storedProduct != nil { return "From your Library" }
        if let lookedUp { return "From the barcode, \(lookedUp.labelBasis)." }
        if let labelValues { return "From the label, \(labelValues.labelBasis)." }
        return nil
    }

    public var servingHint: String? {
        guard let serving, !serving.isEmpty else { return nil }
        return "1 serving = \(serving.label)"
    }

    public var attributionTitle: String? { attribution?.text }

    public func prefilledValue(for key: String) -> NutrientValue {
        for accepted in HealthKitWritePlanner.acceptedKeys(for: key) {
            if let value = prefilledNutrients[accepted], value != .unknown { return value }
        }
        return .unknown
    }

    static let thisAddsKeys: [String] = {
        var keys = LookedUpProduct.standardKeys
        var covered = Set(keys.flatMap { HealthKitWritePlanner.acceptedKeys(for: $0) })
        for key in TodayViewModel.defaultTrackedNutrients {
            let accepted = HealthKitWritePlanner.acceptedKeys(for: key)
            guard covered.isDisjoint(with: accepted) else { continue }
            keys.append(key)
            covered.formUnion(accepted)
        }
        for key in HealthKitWritePlanner.micronutrientKeys {
            let accepted = HealthKitWritePlanner.acceptedKeys(for: key)
            guard covered.isDisjoint(with: accepted) else { continue }
            keys.append(key)
            covered.formUnion(accepted)
        }
        return keys
    }()

    /// The name as it is saved: trimmed, so the density lookup and the saved entry read the same text.
    private var typedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The sentence beside Save when a tap of it was refused, because the fields it names carry their errors.
    public static let fixFieldsMessage = "Fix the fields marked above."
    private static let amountMessage = "Enter an amount greater than zero, using digits and a point."

    /// Why the name will not save, whether or not its field shows that yet.
    public var nameError: String? { typedName.isEmpty ? "Enter a name." : nil }

    /// Why the amount will not save, whether or not its field shows that yet.
    public var amountError: String? {
        AmountParser.parseTyped(amountText) == nil ? Self.amountMessage : nil
    }

    /// The name's error as its field shows it: after a Save attempt, or once the name was edited and left.
    public var visibleNameError: String? { showsError(for: .name) ? nameError : nil }

    /// The amount's error as its field shows it: after a Save attempt, or once the amount was edited and left.
    public var visibleAmountError: String? { showsError(for: .amount) ? amountError : nil }

    private func showsError(for field: AddIntakeField) -> Bool {
        hasAttemptedSave || (editedFields.contains(field) && leftFields.contains(field))
    }

    /// Called when focus leaves a field, so that an error the person was typing through shows once they are done.
    public func fieldDidEnd(_ field: AddIntakeField) {
        // The form reads the visible errors as values, so the change has to be announced for it to redraw.
        objectWillChange.send()
        leftFields.insert(field)
    }

    /// Called when focus enters a field: a new edit starts, so its error waits until the person leaves again.
    public func fieldDidBegin(_ field: AddIntakeField) {
        objectWillChange.send()
        leftFields.remove(field)
        // The household measures are asked for only once the person starts an amount, not when a food is picked.
        if field == .amount, !portionsAsked, portionLookup != nil {
            portionsAsked = true
            Task { await loadListedPortions() }
        }
    }

    /// Asks the source for the cup, tablespoon and teaspoon weights a USDA food lists. A failed or slow request
    /// means those units are not offered; nothing else waits on it.
    public func loadListedPortions() async {
        guard let lookup = portionLookup, let picked = lookedUp, picked.basis == .per100g,
              let sourceID = picked.sourceID, let fdcId = Int(sourceID)
        else { return }
        // Settled however the request ends, so the density notes wait for it and then say what is true.
        defer { if lookedUp?.sourceID == sourceID { portionsLoaded = true } }
        let portions = await lookup.listedPortions(fdcId: fdcId)
        // A later pick may have replaced this food while the request ran; its portions are not this food's.
        guard lookedUp?.sourceID == sourceID else { return }
        listedPortions = portions
    }

    /// True while a USDA food's listed measures are still being asked for. The density notes wait for it, so
    /// they never say a cup cannot be measured when the food does list one.
    private var portionsPending: Bool {
        portionLookup != nil && lookedUp?.basis == .per100g && lookedUp?.sourceID != nil
            && portionsAsked && !portionsLoaded
    }

    /// Clears the attempted save and the per-field history, for when the form is reset.
    public func resetFieldErrors() {
        hasAttemptedSave = false
        editedFields = []
        leftFields = []
    }

    /// The grams a volume typed in a cup, tablespoon or teaspoon is stored as, when a typical density
    /// applies to the food named. Nil when it does not, and the amount then stays in milliliters.
    public var volumeToMass: DensityConversion? {
        guard let amount = AmountParser.parseTyped(amountText) else { return nil }
        return densityConversion(amount: amount, unit: unit, name: typedName)
    }

    /// The line under the amount when a typical density converts the volume: the grams and the food
    /// whose density gave them. Nil when no conversion applies.
    public var densityNote: String? {
        // A measure the food lists converts through its own gram weight, so no density is described for it.
        guard listedPortions[unit] == nil, !portionsPending, let conversion = volumeToMass else { return nil }
        return "About \(DecimalFormatting.text(conversion.grams)) g, using a typical density for "
            + "\(conversion.ingredientName)."
    }

    /// The line shown when a volume is chosen for a food the catalog does not name, so the amount is saved in
    /// milliliters. Nil for a mass, or for a volume the density rule does not reach.
    public var densityUnavailableNote: String? {
        guard listedPortions[unit] == nil, !portionsPending, UnitSelection.typedVolumes.contains(unit), densityApplies,
            !typedName.isEmpty, IngredientDensityCatalog.match(typedName) == nil
        else { return nil }
        return "No typical density is known for this food, so it is saved in mL."
    }

    /// Whether a typical density may stand for a typed volume. It may when the entry has no label basis,
    /// which is a food typed by hand, or when the basis states a mass. A volume label, a per-serving
    /// label and a basis that does not resolve stay in milliliters.
    private var densityApplies: Bool {
        guard let basis = lookedUp?.labelBasis ?? prefilledProduct?.labelBasis else { return true }
        guard let parsed = IntakeContextSnapshotBasis.parse(basis) else { return false }
        switch parsed {
        case .perHundred(let measured), .perUnit(let measured): return measured.dimension == .mass
        case .perCount: return false
        }
    }

    /// The density conversion for an amount typed in `unit` of the food `name`, or nil when the unit is not a
    /// typed volume, no density applies, or the name matches no catalog row or more than one.
    private func densityConversion(amount: Decimal, unit: MeasureUnit, name: String) -> DensityConversion? {
        guard UnitSelection.typedVolumes.contains(unit), densityApplies,
            let row = IngredientDensityCatalog.match(name)
        else { return nil }
        let milliliters = Self.storedMetric(amount: amount, unit: unit).amount
        return DensityConversion(grams: row.grams(forMilliliters: milliliters), ingredientName: row.name)
    }

    /// What is stored for an amount typed in `unit` of the food `name`: grams from a typical density when one
    /// applies, otherwise the metric amount `storedMetric` gives.
    private func storedQuantity(
        amount: Decimal, unit: MeasureUnit, name: String
    ) -> (amount: Decimal, unit: MeasureUnit) {
        // An amount shown rounded in the reader's unit and left alone is saved as the exact stored quantity.
        if let backing = prefillBacking, backing.shownAmount == amount, backing.shownUnit == unit {
            return (backing.storedAmount, backing.storedUnit)
        }
        // A household measure the food lists converts through its own gram weight, which wins over any density.
        if let gramsPerUnit = listedPortions[unit] {
            return (amount * gramsPerUnit, .g)
        }
        if let conversion = densityConversion(amount: amount, unit: unit, name: name) {
            return (conversion.grams, .g)
        }
        return Self.storedMetric(amount: amount, unit: unit)
    }

    /// Recomputed from the same metric components and basis rules used for the saved total.
    /// The heading over the nutrient list. Once an amount exists it says what the entry adds; before that
    /// the list shows the product's own values, so it is titled with their basis rather than as an addition.
    public var thisAddsTitle: String {
        if AmountParser.parseTyped(amountText) != nil { return "This adds" }
        guard let label = (lookupBasis ?? lookedUp?.basis)?.label else { return "Imported values" }
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    public var thisAdds: [ThisAddsLine] {
        guard hasPrefilledValues else { return [] }
        // Until a usable amount exists, the imported values stand as the product states them, so the
        // section never shows a column of "can't be worked out" for an empty field.
        guard let amount = AmountParser.parseTyped(amountText),
            let basis = lookedUp?.labelBasis ?? prefilledProduct?.labelBasis
        else {
            return Self.thisAddsKeys.compactMap { key in
                let value = self.prefilledValue(for: key)
                guard value != .unknown else { return nil }
                return ThisAddsLine(
                    key: key, displayName: LookedUpProduct.displayNames[key] ?? NutrientNames.displayName(for: key),
                    value: value, cannotScale: false)
            }
        }
        let stored = storedQuantity(amount: amount, unit: unit, name: typedName)
        let components = [IntakeComponent(
            componentID: Self.componentID(forFoodNamed: typedName, unit: stored.unit),
            name: typedName, amount: stored.amount, unit: stored.unit)]
        let factor = DailyTotalsBuilder.scalingFactor(labelBasis: basis, logged: components)
        return Self.thisAddsKeys.compactMap { key in
            let value = self.prefilledValue(for: key)
            guard value != .unknown else { return nil }
            return ThisAddsLine(
                key: key, displayName: LookedUpProduct.displayNames[key] ?? NutrientNames.displayName(for: key),
                value: factor.map { value.scaled(by: $0) } ?? (value == .notApplicable ? .notApplicable : .unknown),
                cannotScale: factor == nil && LookedUpProduct.statesAmount(value))
        }
    }

    /// One line explaining the last lookup, or nil when there is nothing to say.
    public var lookupMessage: String? {
        switch lookupState {
        case .idle:
            return nil
        case .loading:
            return "Looking up the barcode…"
        case .found(let product):
            return "Filled in from the barcode (\(product.labelBasis)). Check the amount, then save."
        case .notFound:
            return "No product found for that barcode. Fill in the details yourself."
        case .invalidBarcode:
            return "A barcode has 8, 12 or 13 digits and a correct check digit. Nothing was looked up."
        case .rateLimited(let retryAfterSeconds):
            return Self.rateLimitMessage(retryAfterSeconds: retryAfterSeconds)
        case .failed:
            return "The lookup did not finish. Try again in a moment."
        case .offline:
            return "No internet connection. Try again when you're online."
        }
    }

    /// Whether the product the last lookup found states no nutrition facts at all: every standard key
    /// is unknown, so there is nothing on the form to show a figure for.
    ///
    /// A column of nine "unknown" rows reads as a broken lookup. The one sentence below says what
    /// actually happened and what to do instead, and the form shows it in place of the rows.
    public var statesNoNutrients: Bool {
        guard case .found(let product) = lookupState else { return false }
        return LookedUpProduct.standardKeys.allSatisfy { product.value(for: $0) == .unknown }
    }

    /// What is said in place of the nutrient rows when a lookup found a product that states none.
    ///
    /// It names the catalog because that is the one source this build looks barcodes up in, while the
    /// values themselves and their attribution stay source-agnostic and are shown as the source gave them.
    public static let noStatedNutrientsMessage =
        "Open Food Facts lists this product but states no nutrition facts; scan the label instead."

    /// The same sentence for a device with no label scanner: the fact stays and the instruction goes.
    public static let noStatedNutrientsMessageWithoutScanner =
        "Open Food Facts lists this product but states no nutrition facts."

    /// The sentence the form shows for this device: it tells the person to scan only when a label can be scanned.
    public var noStatedNutrientsSentence: String {
        labelScannerAvailable ? Self.noStatedNutrientsMessage : Self.noStatedNutrientsMessageWithoutScanner
    }

    /// The compound rows a captured panel states that the fifteen journal nutrients do not name, in a
    /// stable order. The form shows them under "Also on the label" so a compound the panel printed is
    /// visible and, saved with the snapshot, is not lost between the review screen and the journal.
    ///
    /// Only a row the panel stated is listed: a known amount, or a bound such as "<1 mg". A key a barcode
    /// snapshot completed as unknown (its `salt`, say) is not a row the label stated and never appears here.
    public var additionalLabelNutrients: [String] {
        guard let captured = prefilledProduct else { return [] }
        var excluded = Set<String>()
        for key in NutritionFactKey.allCases.map(\.rawValue) + LookedUpProduct.standardKeys {
            excluded.insert(key)
            excluded.formUnion(HealthKitWritePlanner.acceptedKeys(for: key))
        }
        return captured.nutrients
            .filter {
                LookedUpProduct.statesAmount($0.value) && !excluded.contains($0.key)
                    && excluded.isDisjoint(with: HealthKitWritePlanner.acceptedKeys(for: $0.key))
            }
            .map(\.key)
            .sorted()
    }

    /// The name a captured panel row is shown under: the words the label printed for it when the
    /// snapshot carries them, otherwise the name the key itself spells out.
    public func displayName(forCaptured key: String) -> String {
        if let printed = prefilledProduct?.displayName(for: key) { return printed }
        guard let fact = NutritionFactKey(rawValue: key) else { return key }
        return LabelCaptureRow.displayNames[fact] ?? LookedUpProduct.displayNames[key] ?? key
    }

    /// The name a compound row is shown under, preferring the words the label printed for it.
    public func displayName(forAdditional key: String) -> String {
        if let printed = prefilledProduct?.displayName(for: key) { return printed }
        return key.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// One line explaining the values a captured panel filled in, or nil when there are none.
    public var labelMessage: String? {
        guard let product = labelValues else { return nil }
        return "Filled in from the Nutrition Facts panel (\(product.labelBasis)). Enter the name, check the amount, then save."
    }

    /// Tells the user how long the source asked them to wait, rather than always one minute: a
    /// source that asked for longer would rate-limit an eager retry straight away.
    static func rateLimitMessage(retryAfterSeconds: Int?) -> String {
        guard let seconds = retryAfterSeconds, seconds > 0 else {
            return "Too many lookups just now. Try again in a minute."
        }
        if seconds < 60 {
            return "Too many lookups just now. Try again in \(seconds) seconds."
        }
        let minutes = (seconds + 59) / 60
        return "Too many lookups just now. Try again in about \(minutes) minute\(minutes == 1 ? "" : "s")."
    }

    /// Looks up the barcode the user typed, after checking its shape and check digit. An invalid
    /// barcode is reported without calling the lookup at all.
    ///
    /// A reply is applied only when it is still the newest lookup this form started and the field
    /// still holds the barcode that was asked for, so a slow reply can never fill the form with
    /// another product's values.
    public func lookUpBarcode() async {
        guard let lookup else { return }
        let trimmed = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BarcodeShape.isValid(trimmed) else {
            lookupState = .invalidBarcode
            return
        }
        barcode = trimmed
        lookupGeneration += 1
        let generation = lookupGeneration
        // Starting the lookup is the user saying this form is about to describe a different product, so
        // whatever was on it goes now rather than when the reply lands. Leaving it until then would keep
        // Save enabled for the whole request, and on a slow one the user could tap Look up and then Save
        // and store the previous product's values, or its captured panel, under the new barcode.
        invalidateLookup()
        lookupState = .loading
        let result = await lookup.lookUp(barcode: trimmed)
        guard generation == lookupGeneration, barcode == trimmed else { return }
        switch result {
        case .found(let product):
            // A source may answer with a different spelling of the same code (a UPC-A padded to 13
            // digits), but an answer for a genuinely different product must not fill this form.
            guard BarcodeShape.areEquivalent(product.barcode, trimmed) else { return }
            apply(product)
            lookupState = .found(product)
        case .notFound:
            invalidateLookup()
            lookupState = .notFound
        case .rateLimited(let retryAfterSeconds):
            invalidateLookup()
            lookupState = .rateLimited(retryAfterSeconds: retryAfterSeconds)
        case .failed(let reason):
            invalidateLookup()
            lookupState = .failed(reason)
        case .offline:
            invalidateLookup()
            lookupState = .offline
        }
    }

    /// Puts a scanned code in the field, dropping everything an earlier lookup put into the form.
    ///
    /// This is the path a lookup that finds nothing takes. A different code means every value on the
    /// form belongs to another product, so the scanned value goes through the same invalidation: the
    /// name, brand and nutrients the lookup filled in, the attribution and the product snapshot all
    /// go with it. Writing the field alone would keep them, and saving then would store the previous
    /// product's snapshot under the code now on screen. A reply still on its way is answered for the
    /// code it was asked about and is dropped by the generation check.
    public func setScannedBarcode(_ scanned: String) {
        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        // Scanning the code already on the field changes nothing, so the values that code filled in
        // stay where they are.
        guard trimmed != barcode.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        lookupGeneration += 1
        invalidateLookup()
        lookupState = .idle
        barcode = trimmed
    }

    /// Fills the form from a product the person picked in a name search, the way a barcode lookup fills
    /// it: the code, the values, the attribution and the snapshot all come from that one product.
    public func applyLookedUp(_ product: LookedUpProduct) {
        // A name-search row has no barcode (USDA has none), so an empty one is accepted; any other value must be valid.
        guard product.barcode.isEmpty || BarcodeValidator.isValid(product.barcode) else { return }
        lookupGeneration += 1
        invalidateLookup()
        barcode = product.barcode
        apply(product)
        // A row with no barcode was not a barcode lookup, so the form does not say it was.
        lookupState = product.barcode.isEmpty ? .idle : .found(product)
    }

    /// Fills the form from a panel the user captured and confirmed, the way a barcode lookup fills it.
    ///
    /// The name is left for the user: a panel states nutrients, not what the food is called. The values
    /// and the product snapshot are attached, so saving writes the values with the origin the capture
    /// recorded. A later lookup or another capture replaces them through the same invalidation as a
    /// failed lookup, because a value from one product must never be stored under another.
    ///
    /// Only the label capture passes `fromLabelCapture: true`. Any other caller, such as a repeat of an entry
    /// with several parts, fills the form the same way but its values are never sent to the community catalog.
    public func applyLabelProduct(_ product: ProductDefinition, fromLabelCapture: Bool = false) {
        lookupGeneration += 1
        invalidateLookup()
        lookupState = .idle
        labelValues = product
        prefilledFromCapture = fromLabelCapture
        fillProductValues(product)
        // The captured panel's serving and basis feed the Servings control and the amount preview, the same
        // as a looked-up product's. Form state only; the stored values are not changed.
        // Only a label capture sets the Servings control. The captured basis still drives the amount preview for
        // every caller, so a repeated per-serving product keeps its preview.
        servingOption = fromLabelCapture ? Self.capturedServing(of: product) : nil
        capturedLabelBasis = product.labelBasis
    }

    /// Prefills a Library product without changing its saved snapshot identity.
    public func applyStoredProduct(_ product: ProductDefinition) {
        lookupGeneration += 1
        invalidateLookup()
        lookupState = .idle
        storedProduct = product
        name = product.name
        brand = product.brand ?? ""
        filledName = nil
        filledBrand = nil
        fillProductValues(product)
    }

    /// A standalone/imported revision opens consumption details without creating history or publishing.
    public func applyCustomProduct(_ revision: CustomProductRevision) throws {
        applyStoredProduct(try CustomProductMapping.snapshot(for: revision))
        customProduct = revision
        kind = revision.content.kind
        category = revision.content.kind.rawValue
        amountText = ""
        prefillBacking = nil
        switch revision.content.basis {
        case .per100g: unit = .g
        case .per100mL: unit = .mL
        case .perServing: unit = revision.content.serving?.unit ?? .serving
        }
    }

    private func fillProductValues(_ product: ProductDefinition) {
        // The panel already said what it is: a Supplement Facts panel is a supplement. The review
        // screen lets the user change it before the product reaches this form at all.
        if !hasChosenKind {
            kind = product.kind
            hasChosenKind = false
        }
        // Every panel row is filled in, so a nutrient the panel did not state reads as unknown on the
        // form rather than missing from it. A known zero is never written for a missing row.
        var filled: [String: NutrientValue] = [:]
        for fact in NutritionFactKey.allCases {
            filled[fact.rawValue] = product.nutrients[fact.rawValue] ?? .unknown
        }
        prefilledNutrients = filled.merging(product.nutrients) { given, _ in given }
        serving = Self.capturedServing(of: product)
    }

    /// What one serving is, read back out of the basis a captured product stored. A panel states its
    /// serving as text ("1 large biscuit") as often as as a measure, so the text is kept either way
    /// and the measure is filled in when the stored basis spells one out.
    static func capturedServing(of product: ProductDefinition) -> ServingDefinition? {
        let prefix = BarcodeLookupBasis.perServing.label
        guard product.labelBasis.hasPrefix(prefix) else { return nil }
        let open = prefix + " ("
        // A basis with no serving spelled out carries nothing to show, so no row is shown either: the
        // section heading already says the values are per serving.
        guard product.labelBasis.hasPrefix(open), product.labelBasis.hasSuffix(")") else { return nil }
        let text = String(product.labelBasis.dropFirst(open.count).dropLast())
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let amount = AmountParser.parse(parts[0]),
              let unit = try? MeasureUnit(symbol: parts[1])
        else {
            return ServingDefinition(quantity: nil, unit: nil, text: text)
        }
        return ServingDefinition(quantity: amount, unit: unit, text: text)
    }

    /// Drops everything an earlier lookup or capture put into the form, so a failed or empty lookup for
    /// a second barcode cannot leave the first product's values, or its snapshot, attached to the next
    /// entry.
    ///
    /// A field the user has since edited is left alone: only what the lookup or the capture itself
    /// filled in is cleared, so typing over a looked-up name and then getting a rate limit does not
    /// lose the typing.
    func invalidateLookup() {
        if let filledName, name == filledName { name = "" }
        if let filledBrand, brand == filledBrand { brand = "" }
        filledName = nil
        filledBrand = nil
        prefilledNutrients = [:]
        lookupBasis = nil
        serving = nil
        attribution = nil
        lookedUp = nil
        // A serving from an earlier product must not stay on the Servings control or count the next entry.
        servingOption = nil
        capturedLabelBasis = nil
        listedPortions = [:]
        portionsAsked = false
        portionsLoaded = false
        unitNotice = nil
        servingCount = ""
        amountFromServings = false
        prefillBacking = nil
        labelValues = nil
        prefilledFromCapture = false
        storedProduct = nil
    }

    /// Fills the form from a looked-up product. The amount is left alone: the user confirms how much
    /// they actually ate.
    private func apply(_ product: LookedUpProduct) {
        labelValues = nil
        // The source has no kind. Only a source-derived default may be replaced; an explicit
        // selection made before or during the request stays the user's.
        if !hasChosenKind {
            kind = .food
            hasChosenKind = false
        }
        if let productName = product.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !productName.isEmpty
        {
            name = productName
            filledName = productName
        }
        if let productBrand = product.brand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !productBrand.isEmpty
        {
            brand = productBrand
            filledBrand = productBrand
        }
        var filled: [String: NutrientValue] = [:]
        for key in LookedUpProduct.standardKeys {
            filled[key] = product.nutrients[key] ?? .unknown
        }
        prefilledNutrients = filled
        lookupBasis = product.basis
        serving = product.basis == .perServing ? product.serving : nil
        attribution = product.attribution
        lookedUp = product
        servingOption = product.serving
        // A unit chosen before this pick may not total against this product. The typed figure was in that unit,
        // so it cannot be carried over: the unit moves to one that totals and the amount is cleared to be re-entered.
        if !unitOptions.contains(unit), let first = unitOptions.first {
            let typed = unit
            // The notice is for a typed amount that was cleared; an empty field only changes the unit.
            let hadAmount = AmountParser.parseTyped(amountText) != nil
            unit = first
            amountText = ""
            if hadAmount {
                unitNotice = "Amount cleared. This food can't be measured in \(typed.screenSymbol)."
            }
        }
        // An amount the person typed before the lookup is theirs and stays; the serving only opens an empty field.
        if AmountParser.parseTyped(amountText, decimalSeparator: countDecimalSeparator) == nil { openOnOneServing() }
    }

    /// Opens the amount on one serving when the source gave its weight. The person still confirms the
    /// amount; this only starts it on a serving they can count up from.
    private func openOnOneServing() {
        guard let display = servingInDisplayUnit else {
            servingCount = ""
            // A backing from an earlier product must not carry over to this one.
            prefillBacking = nil
            return
        }
        isPrefilling = true
        amountText = DecimalFormatting.text(display.quantity)
        unit = display.unit
        isPrefilling = false
        servingCount = "1"
        // The opened amount is the serving, so emptying the Servings field later clears it.
        amountFromServings = true
        // Saved as the exact serving the source gave, so the rounded figure shown never restates it.
        if let servingOption, let shown = AmountParser.parseTyped(amountText) {
            prefillBacking = (shown, display.unit, servingOption.quantity ?? shown, servingOption.unit ?? display.unit)
        }
    }

    /// The serving in the person's mass unit: ounces under US units, grams under metric. The amount that
    /// is stored is the same mass either way; only the figure shown changes.
    private var servingInDisplayUnit: (quantity: Decimal, unit: MeasureUnit)? {
        guard let quantity = servingOption?.quantity, quantity > 0,
              let servingUnit = servingOption?.unit, servingUnit.dimension == .mass,
              lookedUp?.basis != .per100ml
        else { return nil }
        let target = AmountDisplay.massUnit(for: preferences.unitSystem)
        guard let converted = try? Quantity(value: quantity, unit: servingUnit).converted(to: target)
        else { return (quantity, servingUnit) }
        return (converted.value, target)
    }

    /// Whether the picked product has a serving weight the servings count can use: a mass, given as a
    /// number. A volume or a count serving does not, so the count is not offered for it.
    public var canCountServings: Bool {
        guard let quantity = servingOption?.quantity, quantity > 0, let servingUnit = servingOption?.unit,
              lookedUp?.basis != .per100ml
        else { return false }
        return servingUnit.dimension == .mass
    }

    /// Sets the amount to a count of servings: the count times one serving, in the serving's unit.
    public func setServingCount(_ text: String) {
        guard canCountServings, let display = servingInDisplayUnit else { return }
        servingCount = text
        isSettingServings = true
        defer { isSettingServings = false }
        // While the count is a draft, only a complete positive number changes the amount. Anything else
        // ("", "0", "0.", "0.0", "0,") is still being typed and leaves the amount alone; commitServingCount
        // settles it when the edit commits.
        guard let count = AmountParser.parseTyped(text, decimalSeparator: countDecimalSeparator) else { return }
        amountText = DecimalFormatting.text(count * display.quantity)
        amountFromServings = true
        unit = display.unit
        if let servingOption, let quantity = servingOption.quantity, let servingUnit = servingOption.unit,
           let shown = AmountParser.parseTyped(amountText) {
            prefillBacking = (shown, display.unit, count * quantity, servingUnit)
        }
    }

    /// Called when the Servings edit commits: on save, or when focus leaves the field. A count that is
    /// empty or zero then clears the amount, since nothing is left to finish typing.
    public func commitServingCount() {
        let trimmed = servingCount.trimmingCharacters(in: .whitespaces)
        // An emptied Servings field clears the amount it had set, and only that; a typed amount stays.
        guard !trimmed.isEmpty else {
            if amountFromServings {
                isSettingServings = true
                defer { isSettingServings = false }
                amountText = ""
                amountFromServings = false
            }
            return
        }
        let isZero = Decimal(
            string: AmountParser.normalizedTyped(trimmed, decimalSeparator: countDecimalSeparator),
            locale: AmountParser.locale) == 0
        if isZero {
            isSettingServings = true
            defer { isSettingServings = false }
            amountText = ""
            amountFromServings = false
            return
        }
        // A draft that still ends in a separator ("1.", "3,") settles to the number it spells when the edit commits.
        let settled = trimmed.hasSuffix(".") || trimmed.hasSuffix(",") ? String(trimmed.dropLast()) : trimmed
        guard let count = AmountParser.parseTyped(settled, decimalSeparator: countDecimalSeparator),
              let display = servingInDisplayUnit else { return }
        isSettingServings = true
        defer { isSettingServings = false }
        amountText = DecimalFormatting.text(count * display.quantity)
        amountFromServings = true
        unit = display.unit
        // The same exact-backing rule setServingCount applies, so a settled count saves the stored serving, not a rounded figure.
        if let servingOption, let quantity = servingOption.quantity, let servingUnit = servingOption.unit,
           let shown = AmountParser.parseTyped(amountText, decimalSeparator: countDecimalSeparator) {
            prefillBacking = (shown, display.unit, count * quantity, servingUnit)
        }
    }

    /// Calories and macros for the amount as typed, from per-100 g values. Nil when the amount is not a
    /// mass or the values are not per 100 g; per-serving values are not scaled here.
    public var amountPreview: AmountPreview? {
        if let basis = lookupBasis ?? lookedUp?.basis {
            return AmountPreview.make(nutrients: prefilledNutrients, basis: basis, amountText: amountText, unit: unit)
        }
        guard let labelBasis = capturedLabelBasis else { return nil }
        return capturedPreview(labelBasis: labelBasis)
    }

    /// The preview for a captured panel. A per-serving panel scales the same way the "This adds" lines and the
    /// save path do: IntakeContextSnapshotBasis's scaling factor for the stored label basis and the amount typed.
    /// Only a mass amount is scaled, so a volume or count amount shows no preview.
    private func capturedPreview(labelBasis: String) -> AmountPreview? {
        guard let amount = AmountParser.parseTyped(amountText), unit.dimension == .mass,
              let converted = try? Quantity(value: amount, unit: unit).converted(to: .g)
        else { return nil }
        let component = IntakeComponent(componentID: "preview", name: name, amount: amount, unit: unit)
        guard let factor = DailyTotalsBuilder.scalingFactor(labelBasis: labelBasis, logged: [component]) else {
            return nil
        }
        func scaled(_ key: String, in expected: MeasureUnit) -> Decimal? {
            guard case .known(let value, let stated) = prefilledNutrients[key] ?? .unknown, stated == expected else {
                return nil
            }
            return value * factor
        }
        return AmountPreview(
            grams: converted.value,
            kcal: scaled(LookedUpProduct.energyKcal, in: .kcal),
            protein: scaled(LookedUpProduct.protein, in: .g),
            carbohydrates: scaled(LookedUpProduct.carbohydrates, in: .g),
            fat: scaled(LookedUpProduct.fat, in: .g))
    }

    /// The "Save to Library" switch. It starts on every time the form opens, so no earlier choice carries over.
    @Published public var savesToLibrary = true

    /// The water share of a drink, 0 to 100. Set by picking a drink type (its preset) or edited by hand; a
    /// drink saves the share it shows, and nil falls back to `defaultDrinkHydrationPercent`.
    @Published public var waterSharePercent: Decimal? = nil
    /// The drink type the share was prefilled from. Only the share is stored.
    @Published public var drinkType: DrinkType? = nil {
        didSet { if let drinkType { waterSharePercent = drinkType.hydrationPercent } }
    }

    /// Validates and writes one intake. Invalid input sets field errors and writes nothing.
    @discardableResult
    public func save(now: Date) -> Bool {
        hasAttemptedSave = true
        commitServingCount()
        let trimmedName = typedName
        let amount = AmountParser.parseTyped(amountText)
        saveError = nil
        guard nameError == nil, let amount else {
            // The sentence beside the Save button points at the marked fields rather than repeating them, so the
            // same words are not on the screen twice. It is derived from the fields, so it clears itself.
            return false
        }

        let intake = Intake(
            id: makeID(), category: category, occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier,
            meal: meal?.rawValue)
        let (storedAmount, storedUnit) = storedQuantity(amount: amount, unit: unit, name: trimmedName)
        let snapshot = productSnapshot()
        let component = IntakeComponent(
            componentID: Self.componentID(
                forFoodNamed: trimmedName, unit: storedUnit,
                snapshotNutrientKeys: snapshot.map { Array($0.nutrients.keys) } ?? []),
            name: trimmedName, amount: storedAmount, unit: storedUnit,
            hydrationPercent: kind == .drink ? (waterSharePercent ?? IntakeComponent.defaultDrinkHydrationPercent) : nil)
        // The exclusion is written first: if it fails nothing is saved, and a retry cannot make a second entry.
        let keepsOutOfLibrary = canChooseLibrary && !savesToLibrary
        // A volume typed in a spoon, a cup or fluid ounces is stored as milliliters; the unit it was typed in is
        // recorded beside it so a supplement reads back as it was logged. Written first, like the choice above.
        let loggedUnit: MeasureUnit? = storedUnit == .mL && Self.loggedVolumeUnits.contains(unit) ? unit : nil
        do {
            if let loggedUnit, let units = store as? JournalLoggedUnits {
                try units.recordLoggedUnit(JournalLoggedUnit(
                    intakeID: intake.id, componentID: component.componentID, unit: loggedUnit))
            }
            if keepsOutOfLibrary {
                guard let exclusions = store as? JournalLibraryExclusions else {
                    saveError = "Could not save the entry."
                    return false
                }
                try exclusions.keepOutOfLibrary(intakeID: intake.id)
            }
            try store.create(intake, components: [component], product: snapshot, now: now)
        } catch {
            saveError = "Could not save the entry."
            return false
        }
        submitLabelIfShared()
        return true
    }

    /// Sends a captured label to the community catalog once it is saved, when sharing is on and the label
    /// qualifies. The upload runs in a task that holds the submitter and the payload, never the form, and its
    /// outcome is not read, so it can neither delay nor fail the save.
    private func submitLabelIfShared() {
        guard let labelSubmitter, isSharingAllowed(), let submission = communitySubmission() else { return }
        uploadTask = Task { await labelSubmitter.submit(submission) }
    }

    /// The upload for the captured label in the form, or nil. A Library entry, a repeat and a barcode lookup
    /// are never uploaded, and neither is a label whose barcode fails the shape check.
    private func communitySubmission() -> CommunityLabelSubmission? {
        guard customProduct == nil, prefilledFromCapture, lookedUp == nil, storedProduct == nil, let captured = labelValues else {
            return nil
        }
        let code = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BarcodeShape.isValid(code) else { return nil }
        return CommunityLabelUpload.submission(
            for: captured, barcode: code, name: typedName, brand: brand, kind: kind, serving: serving)
    }

    /// What is actually stored for an amount entered in `unit` when no density applies: ounces, cups and
    /// spoons become the metric unit they stand for, everything else is stored as entered.
    ///
    /// The ounces and the typed volumes are INPUT and DISPLAY units only. One ounce is exactly 28.349523125 g,
    /// one fluid ounce 29.5735295625 mL, one cup 236.5882365 mL, one tablespoon 14.78676478125 mL and one
    /// teaspoon 4.92892159375 mL, so each multiplication is exact in a `Decimal` and nothing is lost. Storage,
    /// the journal export, the digests and the relay encoder therefore never see those units, and an entry
    /// logged in them exports as the same amount a metric entry would.
    static func storedMetric(amount: Decimal, unit: MeasureUnit) -> (amount: Decimal, unit: MeasureUnit) {
        switch unit {
        case .oz: return (amount * Decimal(string: "28.349523125", locale: AmountParser.locale)!, .g)
        case .flOz: return (amount * Decimal(string: "29.5735295625", locale: AmountParser.locale)!, .mL)
        case .cup: return (amount * Decimal(string: "236.5882365", locale: AmountParser.locale)!, .mL)
        case .tablespoon: return (amount * Decimal(string: "14.78676478125", locale: AmountParser.locale)!, .mL)
        case .teaspoon: return (amount * Decimal(string: "4.92892159375", locale: AmountParser.locale)!, .mL)
        default: return (amount, unit)
        }
    }

    /// The product snapshot to store with the entry, or nil for an entry typed by hand.
    ///
    /// Everything the snapshot carries is carried here, including the attribution source, the
    /// source's own version and the nutrient values the lookup gave, so a later reader can resolve
    /// the values for this entry without asking the source again. The values are the source's own,
    /// on the basis `labelBasis` names; a nutrient the source did not give stays `.unknown`.
    ///
    /// A captured panel is stored the same way: the values and the origin the capture recorded, with
    /// the name and brand the user settled on. The snapshot id is rebuilt from those, so two captures
    /// of the same panel under two names stay two different records.
    func productSnapshot() -> ProductDefinition? {
        if let customProduct { return try? CustomProductMapping.snapshot(for: customProduct) }
        if let stored = storedProduct,
           name.trimmingCharacters(in: .whitespacesAndNewlines) == stored.name,
           brand.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty == stored.brand,
           kind == stored.kind {
            return stored
        }
        if let captured = storedProduct ?? labelValues {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            var signature = captured.labelBasis + "|origin=" + captured.catalogOrigin
            if let storedProduct {
                signature += "|storedSnapshot=" + storedProduct.snapshotID
            }
            signature += "|name=" + trimmedName
            signature += "|brand=" + (trimmedBrand ?? "")
            // The kind is part of what the capture recorded, so the same panel saved once as a drink and
            // once as a food is two products rather than one snapshot id reused with other content.
            signature += "|kind=" + kind.rawValue
            for key in captured.nutrients.keys.sorted() {
                signature += "|" + key + "=" + LookedUpProduct.describe(captured.nutrients[key] ?? .unknown)
            }
            // The printed spelling is part of what the capture recorded, so two panels that state the
            // same values under the same keys but print one of them differently are two products. The
            // snapshot id has to say so, or the second save collides with the first.
            for key in captured.nutrientDisplayNames.keys.sorted() {
                signature += "|display:" + key + "=" + (captured.nutrientDisplayNames[key] ?? "")
            }
            return ProductDefinition(
                snapshotID: "label-" + Self.slug(signature) + "-" + LookedUpProduct.checksum(signature),
                productID: captured.productID,
                name: trimmedName,
                brand: trimmedBrand,
                barcode: captured.barcode,
                labelBasis: captured.labelBasis,
                catalogOrigin: captured.catalogOrigin,
                catalogVersion: captured.catalogVersion,
                kind: kind,
                nutrients: captured.nutrients,
                nutrientDisplayNames: captured.nutrientDisplayNames
            )
        }
        guard let lookedUp else {
            guard kind != .food else { return nil }
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let signature = "manual|name=" + trimmedName + "|brand=" + (trimmedBrand ?? "") + "|kind=" + kind.rawValue
            let identity = "manual-" + Self.slug(signature) + "-" + LookedUpProduct.checksum(signature)
            return ProductDefinition(
                snapshotID: identity, productID: identity, name: trimmedName, brand: trimmedBrand,
                labelBasis: "per serving", catalogOrigin: "manual", catalogVersion: "1", kind: kind)
        }
        // The name and brand are the ones in the form, not the source's: the user may have corrected
        // or cleared them, and the snapshot has to say what was actually recorded.
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return ProductDefinition(
            snapshotID: lookedUp.snapshotIdentity(name: trimmedName, brand: trimmedBrand, kind: kind),
            // A row with no barcode gets an identity derived from its content, prefixed so it can never read as a barcode.
            productID: lookedUp.barcode.isEmpty
                ? "search-" + lookedUp.snapshotIdentity(name: trimmedName, brand: trimmedBrand, kind: kind)
                : lookedUp.barcode,
            name: trimmedName,
            brand: trimmedBrand,
            barcode: lookedUp.barcode,
            labelBasis: lookedUp.labelBasis,
            catalogOrigin: lookedUp.attribution?.source ?? "unknown",
            catalogVersion: lookedUp.version ?? "unknown",
            kind: kind,
            nutrients: lookedUp.nutrients
        )
    }

    /// Component ids are slugs: `[a-z0-9][a-z0-9._-]{0,63}`. A pure function, so it is callable
    /// from outside the main actor (the snapshot identity in `BarcodeLookup.swift` needs it). The
    /// spelling itself is `Slug`, which the label parser reads a compound's name into as well.
    nonisolated static func slug(_ text: String) -> String {
        Slug.make(text)
    }

    /// The component id for a food the user named. The name's slug, unless the catalog reserves it or the
    /// entry's own product snapshot states a nutrient under it, in which case it is namespaced so the food
    /// keeps its own meaning and the snapshot's fact is not crowded out (a supplement named "Collagen" that
    /// states collagen). Water poured by volume is the one food that is what the catalog row says it is, so
    /// it keeps the catalog id, unless its own snapshot states water, which then keeps that id for the label.
    nonisolated static func componentID(
        forFoodNamed name: String, unit: MeasureUnit, snapshotNutrientKeys: [String] = []
    ) -> String {
        let base = Self.slug(name)
        let stated = Set(snapshotNutrientKeys.map { IntakeContextFactCatalog.nutrientSlug(for: $0) })
        if base == "water", unit.dimension == .volume, !stated.contains(base) { return base }
        func isTaken(_ id: String) -> Bool {
            stated.contains(id) || IntakeContextFactCatalog.isReserved(componentID: id)
        }
        guard isTaken(base) else { return base }
        // The namespaced id is checked the same way, since a snapshot can state a nutrient under it too; a
        // counter goes after the prefix until one is free, which a real label runs out of long before 100.
        for counter in 1...100 {
            let prefix = counter == 1 ? "food-" : "food-\(counter)-"
            let candidate = String((prefix + base).prefix(64))
            if !isTaken(candidate) { return candidate }
        }
        return String(("food-" + UUID().uuidString.lowercased()).prefix(64))
    }
}

/// The sheet that presents the intake form is bound to the view model itself rather than to a flag
/// beside it, so the model has to say which form it is: one form on screen at a time.
extension AddIntakeViewModel: Identifiable {
    public var id: UUID { formID }
}

extension String {
    /// nil when the string holds nothing but whitespace, so an empty brand is stored as absent
    /// rather than as an empty string.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

/// Asks a food source for the cup, tablespoon and teaspoon gram weights a food lists. Implemented by the app
/// target over the USDA client, so the form never holds a key or a network client.
public protocol HouseholdPortionLookup: Sendable {
    func listedPortions(fdcId: Int) async -> [MeasureUnit: Decimal]
}
