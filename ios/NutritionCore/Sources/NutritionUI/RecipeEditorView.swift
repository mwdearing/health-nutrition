import NutritionDomain
import SwiftUI

public struct RecipeEditorView: View {
    @ObservedObject var model: RecipeEditorViewModel
    private let now: () -> Date
    private let onSaved: () -> Void

    public init(model: RecipeEditorViewModel, now: @escaping () -> Date = { Date() }, onSaved: @escaping () -> Void) {
        self.model = model
        self.now = now
        self.onSaved = onSaved
    }

    public var body: some View {
        Form {
            Section("Recipe") {
                TextField("Title", text: $model.title)
                    .font(.body)
                    .accessibilityLabel(RecipeLabels.titleField)
                TextField("Notes", text: $model.notes)
                    .font(.body)
                    .accessibilityLabel(RecipeLabels.notesField)
            }
            Section("Ingredients") {
                ForEach(Array(model.ingredients.enumerated()), id: \.element.id) { index, draft in
                    ingredientRows(index: index, draft: draft)
                }
                Button(RecipeLabels.addIngredient) { model.addIngredient() }
                    .font(.body)
                    .foregroundStyle(TokenColors.accent)
                    .accessibilityLabel(RecipeLabels.addIngredient)
            }
            Section("Makes") {
                Picker("Counted as", selection: $model.yieldKind) {
                    ForEach(RecipeYieldKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .accessibilityLabel(RecipeLabels.yieldKindPicker)
                TextField("Amount", text: $model.yieldAmountText)
                    .font(.body)
                    .decimalKeyboard()
                    .accessibilityLabel(RecipeLabels.yieldAmountField)
                if model.yieldKind == .total {
                    Picker("Unit", selection: $model.yieldUnitSymbol) {
                        ForEach(model.unitSymbols, id: \.self) { symbol in
                            Text(symbol).tag(symbol)
                        }
                    }
                    .accessibilityLabel("Unit of what it makes")
                }
            }
            ForEach(model.messages, id: \.self) { message in
                Text(message).font(.footnote).foregroundStyle(TokenColors.error)
            }
            Section {
                Button(RecipeLabels.saveRecipe) {
                    if model.save(now: now()) { onSaved() }
                }
                .font(.headline)
                .foregroundStyle(TokenColors.accent)
                .accessibilityLabel(RecipeLabels.saveRecipe)
                .accessibilityHint("Saves this recipe as a new version")
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Recipe")
    }

    @ViewBuilder
    private func ingredientRows(index: Int, draft: RecipeIngredientDraft) -> some View {
        let position = index + 1
        VStack(alignment: .leading) {
            TextField("Ingredient name", text: textBinding(draft.id, \.name))
                .font(.body)
                .accessibilityLabel(RecipeLabels.ingredientName(position))
            HStack {
                TextField("Amount", text: textBinding(draft.id, \.amountText))
                    .font(.body)
                    .decimalKeyboard()
                    .accessibilityLabel(RecipeLabels.ingredientAmount(position))
                Picker("Unit", selection: textBinding(draft.id, \.unitSymbol)) {
                    ForEach(model.unitSymbols, id: \.self) { symbol in
                        Text(symbol).tag(symbol)
                    }
                }
                .accessibilityLabel(RecipeLabels.ingredientUnit(position))
            }
            // The values are per the ingredient's basis unit, which is not always its own unit.
            Text("Nutrients per 1 \(draft.basisSymbol); leave blank if unknown")
                .font(.footnote)
                .foregroundStyle(TokenColors.textSecondary)
            ForEach(model.nutrientFields) { field in
                HStack {
                    TextField(field.label, text: nutrientBinding(draft.id, field.id))
                        .font(.body)
                        .decimalKeyboard()
                        .accessibilityLabel(RecipeLabels.nutrientField(field.label, position: position))
                    // A value kept in its own unit says so, rather than sitting under the default one.
                    Text(draft.nutrientUnits[field.id]?.symbol ?? field.unit.symbol)
                        .font(.body).foregroundStyle(TokenColors.textSecondary)
                }
            }
            TextField("Weight per mL in g (only to convert between weight and volume)", text: textBinding(draft.id, \.densityText))
                .font(.footnote)
                .decimalKeyboard()
                .accessibilityLabel("Weight per mL of ingredient \(position)")
            if let suggestion = model.densitySuggestion(for: draft) {
                HStack {
                    Text("Typical density for \(suggestion.name): \(DecimalFormatting.text(suggestion.gramsPerCup)) g per cup")
                        .font(.footnote)
                        .foregroundStyle(TokenColors.textSecondary)
                    Button("Use it") { model.applyDensitySuggestion(to: draft.id) }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Use typical density for ingredient \(position)")
                }
            }
            if model.densitySuggestion(for: draft) != nil || model.showsCatalogDensity(for: draft.id) {
                Text(IngredientDensityCatalog.attribution)
                    .font(.caption)
                    .foregroundStyle(TokenColors.textSecondary)
            }
            Button("Remove") { model.removeIngredient(id: draft.id) }
                .font(.footnote)
                .foregroundStyle(TokenColors.error)
                .buttonStyle(.borderless)
                .accessibilityLabel(RecipeLabels.removeIngredient(position))
        }
    }

    private func textBinding(_ id: String, _ keyPath: WritableKeyPath<RecipeIngredientDraft, String>) -> Binding<String> {
        Binding(
            get: { model.ingredients.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { newValue in
                if let index = model.ingredients.firstIndex(where: { $0.id == id }) {
                    model.ingredients[index][keyPath: keyPath] = newValue
                }
            })
    }

    private func nutrientBinding(_ id: String, _ nutrientID: String) -> Binding<String> {
        Binding(
            get: { model.ingredients.first(where: { $0.id == id })?.nutrientTexts[nutrientID] ?? "" },
            set: { newValue in
                if let index = model.ingredients.firstIndex(where: { $0.id == id }) {
                    model.ingredients[index].nutrientTexts[nutrientID] = newValue
                }
            })
    }
}

/// The decimal keypad is only set where the platform has one. This package also builds for macOS,
/// where `keyboardType` does not exist, so it stays behind this one door.
private extension View {
    @ViewBuilder
    func decimalKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}
