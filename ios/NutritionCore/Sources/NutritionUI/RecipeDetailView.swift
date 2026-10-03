import SwiftUI

public struct RecipeDetailView: View {
    @ObservedObject var model: RecipeDetailViewModel
    private let now: () -> Date
    private let onEdit: () -> Void
    private let onLogged: () -> Void

    public init(
        model: RecipeDetailViewModel, now: @escaping () -> Date = { Date() },
        onEdit: @escaping () -> Void, onLogged: @escaping () -> Void
    ) {
        self.model = model
        self.now = now
        self.onEdit = onEdit
        self.onLogged = onLogged
    }

    public var body: some View {
        Form {
            Section("Per portion") {
                ForEach(model.rows) { row in
                    HStack {
                        Text(row.label).font(.body).foregroundStyle(TokenColors.textPrimary)
                        Spacer()
                        Text(row.text).font(.body).foregroundStyle(TokenColors.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(row.label): \(row.text)")
                }
                ForEach(model.coverageTexts, id: \.self) { text in
                    Text(text).font(.footnote).foregroundStyle(TokenColors.warning)
                }
                Text(model.provenanceText).font(.footnote).foregroundStyle(TokenColors.textSecondary)
            }
            Section("Log a portion") {
                HStack {
                    TextField("Portion", text: $model.portionText)
                        .font(.body)
                        .accessibilityLabel(model.portionLabel)
                    Text(model.portionUnitText).font(.body).foregroundStyle(TokenColors.textSecondary)
                }
                Button(RecipeLabels.logPortion) {
                    if model.logPortion(now: now()) { onLogged() }
                }
                .font(.headline)
                .foregroundStyle(TokenColors.accent)
                .accessibilityLabel(RecipeLabels.logPortion)
                .accessibilityHint("Adds one entry to the journal")
            }
            if let message = model.logMessage {
                Text(message).font(.footnote).foregroundStyle(TokenColors.success)
            }
            if let message = model.errorMessage {
                Text(message).font(.footnote).foregroundStyle(TokenColors.error)
            }
            Section {
                Button(RecipeLabels.editRecipe) { onEdit() }
                    .font(.body)
                    .foregroundStyle(TokenColors.accent)
                    .accessibilityLabel(RecipeLabels.editRecipe)
                    .accessibilityHint("Opens the recipe; saving creates a new version")
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle(model.version.title)
    }
}
