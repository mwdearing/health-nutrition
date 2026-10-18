import SwiftUI

/// Servings and the live amount preview on the Add form. Shown only when the picked product gave a
/// serving weight; a count of servings sets the amount, and the figures follow the amount.
struct AddServingControls: View {
    @ObservedObject var model: AddIntakeViewModel

    var body: some View {
        Group {
            servingsSection
            if let notice = model.unitNotice {
                Section {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.textSecondary)
                        .accessibilityLabel(notice)
                }
                .listRowBackground(TokenColors.background)
            }
        }
    }

    @ViewBuilder private var servingsSection: some View {
        if model.canCountServings, let serving = model.servingOption {
            Section {
                LabeledField("Servings", onFocusEnd: { model.commitServingCount() }) { focus in
                    TextField(
                        "Servings",
                        text: Binding(get: { model.servingCount }, set: { model.setServingCount($0) })
                    )
                    .font(.body)
                    .decimalAmountKeyboard()
                    .focused(focus)
                }
                Text("1 serving = \(serving.label)")
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
                if let preview = model.amountPreview {
                    previewRows(preview)
                }
            } header: {
                Text("Servings")
            }
            .listRowBackground(TokenColors.background)
        }
    }

    @ViewBuilder private func previewRows(_ preview: AmountPreview) -> some View {
        row("Calories", preview.kcal, unit: "")
        row("Protein", preview.protein, unit: "g")
        row("Carbohydrates", preview.carbohydrates, unit: "g")
        row("Fat", preview.fat, unit: "g")
    }

    private func row(_ name: String, _ value: Decimal?, unit: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value.map { unit.isEmpty ? DecimalFormatting.text($0) : "\(DecimalFormatting.text($0)) \(unit)" } ?? "Unknown")
                .foregroundStyle(TokenColors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}
