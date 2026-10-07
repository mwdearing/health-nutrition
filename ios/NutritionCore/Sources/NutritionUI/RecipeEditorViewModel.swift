import Foundation
import NutritionDomain
import NutritionJournal

/// A nutrient the editor asks for, stated per one unit of the ingredient.
public struct RecipeNutrientField: Equatable, Identifiable {
    public let id: String
    public let label: String
    public let unit: MeasureUnit

    /// Every nutrient the Today screen tracks by default is enterable, so a recipe logged from the
    /// editor does not read as lacking one of them.
    public static let all: [RecipeNutrientField] = [
        RecipeNutrientField(id: "energy", label: "Energy", unit: .kcal),
        RecipeNutrientField(id: "protein", label: "Protein", unit: .g),
        RecipeNutrientField(id: "sodium", label: "Sodium", unit: .mg),
        RecipeNutrientField(id: "potassium", label: "Potassium", unit: .mg),
        RecipeNutrientField(id: "fiber", label: "Fiber", unit: .g),
    ]

    public static func label(for nutrientID: String) -> String {
        all.first(where: { $0.id == nutrientID })?.label ?? nutrientID
    }
}

public struct RecipeIngredientDraft: Identifiable, Equatable {
    public var id: String
    public var name: String = ""
    public var amountText: String = ""
    public var unitSymbol: String = MeasureUnit.g.symbol
    /// Density in g per mL; blank when not needed.
    public var densityText: String = ""
    /// Per-unit values by nutrient id; blank means unknown.
    public var nutrientTexts: [String: String] = [:]
    /// The unit a loaded value is stated in, when it differs from its editor field's unit and cannot
    /// be converted to it exactly. The field still shows the number, so saving writes the value back
    /// in the unit it was stored in rather than relabelling it.
    public var nutrientUnits: [String: MeasureUnit] = [:]
    /// A state a field cannot express, such as not applicable or below a reporting threshold. The field
    /// shows no number for it, so it is carried through an edit unless the user types a number there.
    var states: [String: NutrientValue] = [:]
    /// The unit the per-unit values are stated in, when it differs from `unitSymbol`. The editor has
    /// no field for it, so an existing value is carried through untouched.
    public var basisUnit: MeasureUnit?

    /// The symbol the nutrient values are stated per: the explicit basis when there is one, else the
    /// ingredient's own unit.
    public var basisSymbol: String { basisUnit?.symbol ?? unitSymbol }
    /// Values the editor has no field for, carried over unchanged.
    var preserved: [String: NutrientValue] = [:]
    var sourceNote: String?
    var storedID: String?

    public init(id: String) {
        self.id = id
    }
}

public enum RecipeYieldKind: String, CaseIterable, Identifiable {
    case servings
    case total

    public var id: String { rawValue }
    public var label: String { self == .servings ? "Servings" : "Total amount" }
}

@MainActor
public final class RecipeEditorViewModel: ObservableObject {
    @Published public var title: String = ""
    @Published public var notes: String = ""
    @Published public var ingredients: [RecipeIngredientDraft] = []
    @Published public var yieldKind: RecipeYieldKind = .servings
    @Published public var yieldAmountText: String = ""
    @Published public var yieldUnitSymbol: String = MeasureUnit.g.symbol
    @Published public private(set) var messages: [String] = []
    @Published public private(set) var savedVersion: RecipeVersion?

    /// The units the ingredient and yield pickers offer: the registry without the two ounces.
    ///
    /// `oz` and `fl oz` are input and display units for Add intake, which normalises them to grams and
    /// millilitres on the way in. A recipe has no such step: its yield becomes the component of a
    /// logged entry through `RecipeLogger.portionQuantity`, so an ounce yield would be stored as an
    /// ounce and skip that normalisation. Keeping them out here is what makes a recipe metric.
    public static let unitSymbols: [String] =
        UnitRegistry.all.filter { $0 != .oz && $0 != .flOz }.map { $0.symbol }

    public let unitSymbols = RecipeEditorViewModel.unitSymbols
    public let nutrientFields = RecipeNutrientField.all

    private let store: RecipeStore
    private let recipeID: String
    private let isEdit: Bool
    private var draftCounter = 0

    /// Starts an empty recipe, or an edit of `editing` that will save as the next version.
    public init(
        store: RecipeStore,
        editing: RecipeVersion? = nil,
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.recipeID = editing?.recipeID ?? makeID()
        self.isEdit = editing != nil
        if let editing {
            load(editing)
        } else {
            addIngredient()
        }
    }

    public func addIngredient() {
        draftCounter += 1
        ingredients.append(RecipeIngredientDraft(id: "draft-\(draftCounter)"))
    }

    public func removeIngredient(id: String) {
        ingredients.removeAll { $0.id == id }
    }

    private func load(_ version: RecipeVersion) {
        title = version.title
        notes = version.notes
        for ingredient in version.ingredients {
            draftCounter += 1
            var draft = RecipeIngredientDraft(id: "draft-\(draftCounter)")
            draft.storedID = ingredient.id
            draft.name = ingredient.name
            draft.amountText = DecimalFormatting.text(ingredient.quantity.value)
            draft.unitSymbol = ingredient.quantity.unit.symbol
            draft.densityText = ingredient.density.map { DecimalFormatting.text($0) } ?? ""
            draft.basisUnit = ingredient.basisUnit
            draft.sourceNote = ingredient.sourceNote
            for (key, value) in ingredient.perUnit {
                guard let field = nutrientFields.first(where: { $0.id == key }) else {
                    draft.preserved[key] = value
                    continue
                }
                guard case .known(let amount, let storedUnit) = value else {
                    // A state the field cannot express (not applicable, below a reporting threshold)
                    // is kept as it is, so an edit that does not touch this field does not turn it into
                    // unknown, which counts as missing rather than as stated.
                    draft.states[key] = value
                    continue
                }
                // The field shows a number, so a value stored in another unit of the same kind is
                // converted into the field's unit exactly. A unit that cannot be converted (a mass
                // against a volume with no density, say) keeps the number and its own unit, so saving
                // never relabels 1000 mg as 1000 g.
                if let converted = try? Quantity(value: amount, unit: storedUnit).converted(to: field.unit) {
                    draft.nutrientTexts[key] = DecimalFormatting.text(converted.value)
                } else {
                    draft.nutrientTexts[key] = DecimalFormatting.text(amount)
                    draft.nutrientUnits[key] = storedUnit
                }
            }
            ingredients.append(draft)
        }
        switch version.yield {
        case .servings(let count):
            yieldKind = .servings
            yieldAmountText = DecimalFormatting.text(count)
        case .total(let quantity):
            yieldKind = .total
            yieldAmountText = DecimalFormatting.text(quantity.value)
            yieldUnitSymbol = quantity.unit.symbol
        }
    }

    /// Accepts digits with one point, including zero; nil for anything else.
    static func parseNonNegative(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let value = AmountParser.parse(trimmed) { return value }
        let dots = trimmed.filter { $0 == "." }.count
        guard !trimmed.isEmpty, dots <= 1, trimmed.contains("0"), trimmed.allSatisfy({ $0 == "0" || $0 == "." }) else {
            return nil
        }
        return Decimal(0)
    }

    /// Validates and writes one new version. Invalid input sets messages and writes nothing.
    @discardableResult
    public func save(now: Date) -> Bool {
        var problems: [String] = []
        savedVersion = nil
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty { problems.append("Enter a title.") }
        if ingredients.isEmpty { problems.append("Add at least one ingredient.") }

        var built: [RecipeIngredient] = []
        var usedIDs = Set<String>()
        for (index, draft) in ingredients.enumerated() {
            let position = index + 1
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { problems.append("Ingredient \(position): enter a name.") }
            let amount = AmountParser.parse(draft.amountText)
            if amount == nil {
                problems.append("Ingredient \(position): enter an amount greater than zero, using digits and a point.")
            }
            let unit = try? UnitRegistry.unit(for: draft.unitSymbol)
            if unit == nil { problems.append("Ingredient \(position): choose a known unit.") }
            var density: Decimal?
            let densityTrimmed = draft.densityText.trimmingCharacters(in: .whitespaces)
            if !densityTrimmed.isEmpty {
                density = AmountParser.parse(densityTrimmed)
                if density == nil {
                    problems.append("Ingredient \(position): density must be greater than zero, using digits and a point.")
                }
            }
            var perUnit = draft.preserved
            for field in nutrientFields {
                let text = (draft.nutrientTexts[field.id] ?? "").trimmingCharacters(in: .whitespaces)
                if text.isEmpty {
                    // A blank field means unknown, unless the field still holds a state the editor has
                    // no way to show and the user has not typed over it.
                    perUnit[field.id] = draft.states[field.id] ?? .unknown
                } else if let value = Self.parseNonNegative(text) {
                    // A value the editor could not express in this field's unit keeps the unit it was
                    // loaded with; every other value is written in the field's own unit.
                    perUnit[field.id] = .known(value, draft.nutrientUnits[field.id] ?? field.unit)
                } else {
                    problems.append("Ingredient \(position): \(field.label) must be a number using digits and a point, or blank.")
                }
            }
            var ingredientID = draft.storedID ?? AddIntakeViewModel.slug(name)
            if !usedIDs.insert(ingredientID).inserted {
                var suffix = 2
                while !usedIDs.insert("\(ingredientID)-\(suffix)").inserted { suffix += 1 }
                ingredientID = "\(ingredientID)-\(suffix)"
            }
            if let amount, let unit {
                built.append(RecipeIngredient(
                    id: ingredientID, name: name, quantity: Quantity(value: amount, unit: unit), perUnit: perUnit,
                    density: density, sourceNote: draft.sourceNote, basisUnit: draft.basisUnit))
            }
        }

        var yieldValue: RecipeYield?
        if let amount = AmountParser.parse(yieldAmountText) {
            switch yieldKind {
            case .servings:
                yieldValue = .servings(amount)
            case .total:
                if let unit = try? UnitRegistry.unit(for: yieldUnitSymbol) {
                    yieldValue = .total(Quantity(value: amount, unit: unit))
                } else {
                    problems.append("Choose a known unit for the yield.")
                }
            }
        } else {
            problems.append("Enter a yield greater than zero, using digits and a point.")
        }

        guard problems.isEmpty, let yieldValue else {
            messages = problems
            return false
        }
        do {
            var latest = 0
            if isEdit {
                // A version that cannot be read is left out of this list but still holds its number,
                // so the store, not this list, has the last word on which number comes next.
                latest = (try? store.versions(of: recipeID))?.last?.number ?? 0
            }
            var version = RecipeVersion(
                recipeID: recipeID, number: latest + 1, title: trimmedTitle, ingredients: built,
                yield: yieldValue, notes: notes, createdAt: now)
            try version.validate()
            do {
                try store.saveNewVersion(version)
            } catch RecipeStoreError.versionConflict(let expected, _) {
                version = RecipeVersion(
                    recipeID: recipeID, number: expected, title: trimmedTitle, ingredients: built,
                    yield: yieldValue, notes: notes, createdAt: now)
                try store.saveNewVersion(version)
            }
            savedVersion = version
            messages = []
            return true
        } catch let error as RecipeError {
            messages = [Self.message(for: error)]
            return false
        } catch {
            messages = ["Could not save the recipe."]
            return false
        }
    }

    static func message(for error: RecipeError) -> String {
        switch error {
        case .emptyTitle: return "Enter a title."
        case .noIngredients: return "Add at least one ingredient."
        case .nonPositiveYield: return "Enter a yield greater than zero, using digits and a point."
        case .nonPositiveQuantity: return "Every ingredient needs an amount greater than zero."
        case .emptyIngredientName: return "Every ingredient needs a name."
        case .duplicateIngredientID: return "Two ingredients share the same identifier."
        default: return "The recipe is not valid."
        }
    }
}
