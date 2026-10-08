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

    public init(store: JournalStore, meal: MealLabel? = nil,
        scannerAvailability: AddScannerAvailability = AddScannerAvailability(),
        lookup: BarcodeProductLookup? = nil,
        preferences: DisplayPreferences = InMemoryDisplayPreferences(),
        now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.meal = meal
        self.scannerAvailability = scannerAvailability
        self.lookup = lookup
        self.preferences = preferences
        self.now = now
    }

    public func load() {
        do {
            recents = try RecentItemsProvider(store: store).recents(limit: 5)
            errorMessage = nil
        } catch { errorMessage = "Could not read recent items." }
    }

    public func makeDetails(now: Date) -> AddIntakeViewModel {
        let model = AddIntakeViewModel(store: store, now: now, lookup: lookup, preferences: preferences)
        model.meal = meal
        return model
    }

    public func makeDetails(prefill: RepeatTemplate, now: Date) throws -> AddIntakeViewModel {
        let model = makeDetails(now: now)
        guard let component = prefill.components.first else { throw JournalError.corruptRecord("empty template") }
        if prefill.components.count > 1 {
            // The current Details form has one amount. Present the whole recorded combination as
            // one serving, spelling out all original amounts rather than silently dropping any.
            model.name = prefill.components.map {
                "\($0.name) (\(AmountText.describe($0)))"
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
                let nutrients = product.nutrients.mapValues { value in
                    factor.map { value.scaled(by: $0) } ?? .unknown
                }
                model.applyLabelProduct(ProductDefinition(
                    snapshotID: UUID().uuidString.lowercased(), productID: product.productID,
                    name: model.name, brand: product.brand, barcode: product.barcode,
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
        model.amountText = DecimalFormatting.text(component.amount)
        model.unit = component.unit
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
        let product = ProductDefinition(
            snapshotID: RecipeLogger.snapshotID(recipeID: recipe.recipeID, number: recipe.number),
            productID: recipe.recipeID, name: recipe.title,
            labelBasis: RecipeLogger.basisText(recipe.yield),
            catalogOrigin: RecipeLogger.catalogOrigin, catalogVersion: String(recipe.number), nutrients: values)
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
        template.meal = meal?.rawValue
        let date = now()
        do {
            let repeater = IntakeRepeater(store: store, timeZoneProvider: { TimeZone.current.identifier },
                makeID: { UUID().uuidString.lowercased() })
            let id = try repeater.create(from: template, now: date)
            let token = AddUndoToken(intakeID: id,
                message: "Added \(template.displayName), \(AmountText.summary(template.components))",
                expiresAt: date.addingTimeInterval(10))
            undoToken = token
            load()
            return token
        } catch { errorMessage = "Could not add the item."; return nil }
    }

    @discardableResult
    public func undo() -> Bool {
        guard let token = undoToken, now() < token.expiresAt else { undoToken = nil; return false }
        do {
            try store.delete(intakeID: token.intakeID, now: now())
            undoToken = nil
            load()
            return true
        } catch { errorMessage = "Could not undo."; return false }
    }

    public func expireUndo(_ token: AddUndoToken) {
        if undoToken == token { undoToken = nil }
    }
}
