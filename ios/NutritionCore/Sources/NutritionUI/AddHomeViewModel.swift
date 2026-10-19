import Foundation
import NutritionDomain
import NutritionJournal

public struct AddScannerAvailability {
    public let barcode: Bool
    public let label: Bool
    public var barcodeExplanation: String { "This device can't scan barcodes. Type the digits instead." }
    public var labelExplanation: String { "This device can't scan labels. Type the values instead." }
    public init(barcode: Bool = false, label: Bool = false) {
        self.barcode = barcode
        self.label = label
    }
}

public struct AddUndoToken: Equatable {
    public let intakeID: String
    public let message: String
    public let expiresAt: Date
}

@MainActor
public final class AddHomeViewModel: ObservableObject, Identifiable {
    public let id = UUID()
    @Published public var meal: MealLabel?
    @Published public private(set) var recents: [RecentItem] = []
    @Published public private(set) var undoToken: AddUndoToken?
    @Published public private(set) var errorMessage: String?
    public let scannerAvailability: AddScannerAvailability
    public let emptyRecentsText = "Things you log will show up here."
    private let store: JournalStore
    private let lookup: BarcodeProductLookup?
    private let preferences: DisplayPreferences
    private let now: () -> Date
    private let labelSubmitter: CommunityLabelSubmitting?
    private let portionLookup: (any HouseholdPortionLookup)?
    private let isSharingAllowed: @MainActor () -> Bool

    public init(store: JournalStore, meal: MealLabel? = nil,
        scannerAvailability: AddScannerAvailability = AddScannerAvailability(),
        lookup: BarcodeProductLookup? = nil,
        preferences: DisplayPreferences = InMemoryDisplayPreferences(),
        now: @escaping () -> Date = { Date() },
        labelSubmitter: CommunityLabelSubmitting? = nil,
        portionLookup: (any HouseholdPortionLookup)? = nil,
        isSharingAllowed: @escaping @MainActor () -> Bool = { false }) {
        self.store = store
        self.meal = meal
        self.scannerAvailability = scannerAvailability
        self.lookup = lookup
        self.preferences = preferences
        self.now = now
        self.labelSubmitter = labelSubmitter
        self.portionLookup = portionLookup
        self.isSharingAllowed = isSharingAllowed
    }

    public func load() {
        do {
            recents = try RecentItemsProvider(store: store).recents(limit: 5)
            errorMessage = nil
        } catch { errorMessage = "Could not read recent items." }
    }

    public func makeDetails(now: Date) -> AddIntakeViewModel {
        let model = AddIntakeViewModel(
            store: store, now: now, lookup: lookup, preferences: preferences,
            labelScannerAvailable: scannerAvailability.label,
            labelSubmitter: labelSubmitter, isSharingAllowed: isSharingAllowed,
            portionLookup: portionLookup)
        model.meal = meal
        return model
    }

    /// A template's amounts as the reader's unit system shows them.
    public func amountSummary(of template: RepeatTemplate) -> String {
        let kind = template.productSnapshotID.flatMap { try? store.product(snapshotID: $0) }?.kind
        return AmountText.summary(
            template.components, unitSystem: preferences.unitSystem,
            loggedUnits: kind == .supplement ? template.loggedUnits : [:], isSupplement: kind == .supplement)
    }

    /// A Recent row's second line: its amounts, then its meal, separated the way the Library row shows them.
    public func recentSubtitle(of template: RepeatTemplate) -> String {
        let amounts = amountSummary(of: template)
        guard let meal = MealLabel.displayName(for: template.meal) else { return amounts }
        return "\(amounts) · \(meal)"
    }

    public func makeDetails(product: CustomProductRevision, now: Date) throws -> AddIntakeViewModel {
        let model = makeDetails(now: now)
        try model.applyCustomProduct(product)
        return model
    }

    public func makeDetails(prefill: RepeatTemplate, now: Date) throws -> AddIntakeViewModel {
        let model = makeDetails(now: now)
        guard let component = prefill.components.first else { throw JournalError.corruptRecord("empty template") }
        if prefill.components.count > 1 {
            // The current Details form has one amount. Present the whole recorded combination as
            // one serving, spelling out all original amounts rather than silently dropping any.
            let comboKind = prefill.productSnapshotID.flatMap { try? store.product(snapshotID: $0) }?.kind
            model.name = prefill.components.map {
                let loggedUnit = comboKind == .supplement ? prefill.loggedUnits[$0.componentID] : nil
                return "\($0.name) (\(AmountText.describe($0, unitSystem: preferences.unitSystem, loggedUnit: loggedUnit, isSupplement: comboKind == .supplement)))"
            }.joined(separator: ", ")
            model.category = prefill.category
            model.amountText = "1"
            model.unit = .serving
            if let snapshotID = prefill.productSnapshotID {
                guard let product = try store.product(snapshotID: snapshotID) else {
                    throw IntakeRepeatError.productUnavailable
                }
                let factor = IntakeContextSnapshotBasis.scalingFactor(
                    labelBasis: product.labelBasis, logged: prefill.components)
                    ?? IntakeContextSnapshotBasis.perHundredGOrMLFactor(
                        labelBasis: product.labelBasis, logged: prefill.components)
                // Scaled values are kept to what the journal reads back (`StoredDecimal`) before they name a
                // snapshot, so the snapshot id and the stored values agree.
                let nutrients = product.nutrients.mapValues { value in
                    factor.map { StoredDecimal.storable(value.scaled(by: $0)) } ?? .unknown
                }
                model.applyLabelProduct(ProductDefinition(
                    snapshotID: UUID().uuidString.lowercased(), productID: product.productID,
                    name: model.name, brand: product.brand, barcode: product.barcode?.isEmpty == true ? nil : product.barcode,
                    labelBasis: "per serving", catalogOrigin: product.catalogOrigin,
                    catalogVersion: product.catalogVersion, kind: product.kind,
                    nutrients: nutrients, nutrientDisplayNames: product.nutrientDisplayNames))
                model.brand = product.brand ?? ""
            }
            return model
        }
        if let snapshotID = prefill.productSnapshotID {
            guard let product = try store.product(snapshotID: snapshotID) else { throw IntakeRepeatError.productUnavailable }
            model.applyStoredProduct(product)
            model.brand = product.brand ?? ""
        }
        model.name = prefill.displayName
        model.category = prefill.category
        let kind = prefill.productSnapshotID.flatMap { try? store.product(snapshotID: $0) }?.kind
        // A supplement opens in the unit it was logged in, or, when none was recorded and its amount is stored in
        // milliliters, in the spoon those milliliters can only have been typed in. Other units open as they are.
        var openedIn: MeasureUnit?
        if kind == .supplement {
            openedIn = prefill.loggedUnits[component.componentID]
            if openedIn == nil, component.unit == .mL {
                openedIn = AmountDisplay.legacySpoonReading(milliliters: component.amount)?.unit
            }
        }
        model.prefillAmount(component, system: preferences.unitSystem, loggedUnit: openedIn)
        return model
    }

    /// Prefills one portion without logging it; Save remains the only write.
    public func makeDetails(recipe: RecipeVersion, now: Date) throws -> AddIntakeViewModel {
        try recipe.validate()
        let values = try RecipeMath.perPortion(RecipeMath.totals(of: recipe), yield: recipe.yield, portion: 1)
        guard values.values.contains(where: { $0.isKnown }) else { throw RecipeError.nothingToLog }
        let model = makeDetails(now: now)
        let unit: MeasureUnit
        switch recipe.yield {
        case .servings: unit = .serving
        case .total(let quantity): unit = quantity.unit
        }
        let product = try RecipeLogger.snapshot(for: recipe, perServing: values, in: store)
        model.applyStoredProduct(product)
        model.name = recipe.title
        model.category = RecipeLogger.category
        model.amountText = "1"
        model.unit = unit
        return model
    }
    public func scannedBarcode(_ barcode: String, into model: AddIntakeViewModel) async {
        model.setScannedBarcode(barcode)
        await model.lookUpBarcode()
    }

    @discardableResult
    public func quickAdd(_ recent: RecentItem) -> AddUndoToken? {
        var template = recent.template
        // Only a meal the person chose overrides the item's own meal; None keeps the one it was logged under.
        if let meal { template.meal = meal.rawValue }
        let date = now()
        do {
            let repeater = IntakeRepeater(store: store, timeZoneProvider: { TimeZone.current.identifier },
                makeID: { UUID().uuidString.lowercased() })
            let id = try repeater.create(from: template, now: date)
            let token = AddUndoToken(intakeID: id,
                message: "Added \(template.displayName), \(amountSummary(of: template))",
                expiresAt: date.addingTimeInterval(10))
            undoToken = token
            load()
            return token
        } catch { errorMessage = "Could not add the item."; return nil }
    }

    /// The amounts-only form for the meal chosen here.
    public func makeQuickAdd() -> QuickAddViewModel {
        QuickAddViewModel(store: store, meal: meal, now: now)
    }

    /// Offers undo for an entry the amounts-only form wrote, as a recent item's Add does.
    public func quickAdded(_ token: AddUndoToken) {
        undoToken = token
        load()
    }

    @discardableResult
    public func undo() -> Bool {
        guard let token = undoToken, now() < token.expiresAt else { undoToken = nil; return false }
        do {
            try store.delete(intakeID: token.intakeID, now: now())
            undoToken = nil
            load()
            return true
        } catch JournalError.intakeDeleted(_) {
            // Already deleted from the Journal: nothing is left to undo, so drop the token.
            undoToken = nil
            load()
            return false
        } catch { errorMessage = "Could not undo."; return false }
    }

    public func expireUndo(_ token: AddUndoToken) {
        if undoToken == token { undoToken = nil }
    }
}
