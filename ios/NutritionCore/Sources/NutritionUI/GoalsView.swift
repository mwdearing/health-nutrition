import SwiftUI
import NutritionDomain

/// The daily goals screen: the target for each nutrient a person can set, and how to change or
/// clear it.
///
/// Text styles only, colours from the tokens, and every control named for VoiceOver. The amounts
/// are typed rather than stepped, because a target is a number the person has in mind - a dietitian's
/// figure, a package label - and a stepper would only make that harder to enter.
public struct GoalsView: View {
    @ObservedObject var model: GoalsViewModel
    /// The nutrient currently being edited, and the text and unit its target is typed into.
    @State private var editing: String = NutrientGoalChoices.keys.first ?? "energy"
    @State private var targetText: String = ""
    @State private var unit: MeasureUnit = NutrientGoalChoices.unit(forKey: NutrientGoalChoices.keys.first ?? "energy")

    public init(model: GoalsViewModel) {
        self.model = model
    }

    public var body: some View {
        List {
            Section("Daily goals") {
                ForEach(model.rows) { row in
                    goalRow(row)
                }
            }
            Section("Change a goal") {
                Picker("Nutrient", selection: $editing) {
                    ForEach(model.offeredKeys, id: \.self) { key in
                        Text(model.displayName(for: key)).tag(key)
                    }
                }
                TextField("Target", text: $targetText)
                    .font(.body)
                    .decimalKeyboard()
                    .accessibilityLabel("Daily target for \(model.displayName(for: editing))")
                Picker("Unit", selection: $unit) {
                    ForEach(NutrientGoalChoices.units(forKey: editing), id: \.symbol) { candidate in
                        Text(candidate.symbol).tag(candidate)
                    }
                }
                .onChange(of: editing) { _, _ in unit = NutrientGoalChoices.unit(forKey: editing) }
                Button("Save goal") {
                    if model.setTarget(targetText, for: editing, unit: unit) { targetText = "" }
                }
                .font(.headline)
                .foregroundStyle(TokenColors.accent)
                .accessibilityLabel("Save the daily goal")
                .accessibilityHint("Stores the target for the chosen nutrient")
            }
            if let message = model.errorMessage {
                Text(message).font(.footnote).foregroundStyle(TokenColors.error)
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Daily goals")
        .onAppear { model.load() }
    }

    /// One nutrient: its name, the target it has or the fact that it has none, and the way to clear
    /// it. A nutrient without a target says so rather than showing an empty amount, so an unset
    /// goal does not read as a target of nothing.
    private func goalRow(_ row: NutrientGoalRow) -> some View {
        VStack(alignment: .leading) {
            Text(row.displayName).font(.headline).foregroundStyle(TokenColors.textPrimary)
            Text(row.targetText ?? "No goal set")
                .font(.subheadline)
                .foregroundStyle(row.targetText == nil ? TokenColors.textSecondary : TokenColors.success)
                .accessibilityLabel(row.targetText == nil
                    ? "No goal set for \(row.displayName)" : "\(row.displayName) goal \(row.targetText ?? "")")
            if row.targetText != nil {
                Button {
                    model.removeTarget(for: row.nutrient)
                } label: {
                    Label("Remove goal", systemImage: "trash")
                        .font(.footnote)
                        .foregroundStyle(TokenColors.error)
                }
                .accessibilityLabel("Remove the goal for \(row.displayName)")
                .accessibilityHint("The nutrient falls back to a plain total on Today")
            }
        }
    }
}

/// The keyboard is only set where the platform has one. This package also builds for macOS, where
/// `keyboardType` does not exist, so it stays behind this one door, as it does in `AddIntakeView`.
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
