import NutritionDomain
import NutritionJournal
import SwiftUI

/// Amounts only: calories and macros for a meal, saved without looking anything up.
///
/// The screen owns nothing but the form. `onSaved` hands back the undo token for the entry that was
/// written, so whoever presents it can dismiss and show its own undo toast.
public struct QuickAddView: View {
    @ObservedObject private var model: QuickAddViewModel
    private let onSaved: (AddUndoToken) -> Void

    public init(model: QuickAddViewModel, onSaved: @escaping (AddUndoToken) -> Void) {
        self.model = model
        self.onSaved = onSaved
    }

    public var body: some View {
        Form {
            Section {
                amountField(.calories, text: $model.caloriesText)
                amountField(.protein, text: $model.proteinText)
                amountField(.carbohydrates, text: $model.carbohydratesText)
                amountField(.fat, text: $model.fatText)
            } footer: {
                Text("Fill in what you know. An empty field stays unknown rather than counting as zero.")
            }
            Section {
                Picker("Meal", selection: $model.meal) {
                    Text("None").tag(MealLabel?.none)
                    ForEach(MealLabel.allCases, id: \.self) { label in
                        Text(label.displayName).tag(MealLabel?.some(label))
                    }
                }
                LabeledField("Name (optional)") { focus in
                    TextField(text: $model.name, prompt: Text(QuickAddViewModel.defaultName)) {
                        Text("Name")
                    }
                    .labelsHidden()
                    .font(.body)
                    .focused(focus)
                }
            }
        }
        .navigationTitle("Amounts only")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: DesignSpacing.s) {
                if let message = model.saveError {
                    InlineNotice(message, tone: .failed)
                }
                PrimaryCapsule("Log") {
                    if let token = self.model.save() { self.onSaved(token) }
                }
                .disabled(!model.canSave)
                .opacity(model.canSave ? 1 : 0.5)
                .accessibilityLabel("Log")
                .accessibilityHint("Adds these amounts to the journal")
            }
            .padding(DesignSpacing.m)
            .background(TokenColors.background)
        }
    }

    private func amountField(_ field: QuickAddViewModel.Field, text: Binding<String>) -> some View {
        LabeledField("\(field.label) (\(field.unit.symbol))", error: model.error(for: field)) { focus in
            TextField(text: text, prompt: Text("0")) {
                Text(field.label)
            }
            .labelsHidden()
            .font(.body)
            .decimalAmountKeyboard()
            .focused(focus)
            .accessibilityHint(self.model.error(for: field) ?? "")
        }
    }
}
