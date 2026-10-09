import SwiftUI
import NutritionDomain

/// Inline editing of the daily targets a person sets.
public struct GoalsView: View {
    @ObservedObject var model: GoalsViewModel
    @FocusState private var focusedNutrient: String?
    @State private var showingClearConfirmation = false

    public init(model: GoalsViewModel) {
        self.model = model
    }

    public var body: some View {
        List {
            Section {
                Text("Set your own daily targets, or leave them empty.")
                    .font(.body)
                    .foregroundStyle(TokenColors.textSecondary)
            }
            ForEach(model.sections) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        self.goalRow(row)
                    }
                }
            }
            Section {
                Text(model.footerText)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
                Button("Clear all goals", role: .destructive) {
                    self.focusedNutrient = nil
                    self.showingClearConfirmation = true
                }
            }
            if let message = model.errorMessage {
                InlineNotice(message, tone: .failed)
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Daily goals")
        .onAppear { self.model.load() }
        .onChange(of: focusedNutrient) { previous, _ in
            if let previous { self.model.commitTarget(for: previous) }
        }
        .confirmationDialog("Clear all goals?", isPresented: $showingClearConfirmation, titleVisibility: .visible) {
            Button("Clear all goals", role: .destructive) {
                self.model.clearAllGoals()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your daily totals will still be shown without targets.")
        }
    }

    private func goalRow(_ row: GoalSectionRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.displayName).font(.headline).foregroundStyle(TokenColors.textPrimary)
            if let detail = row.detail {
                Text(detail).font(.footnote).foregroundStyle(TokenColors.textSecondary)
            }
            Text(row.targetText).font(.subheadline).foregroundStyle(TokenColors.textPrimary)
            HStack {
                TextField("None", text: Binding(
                    get: { self.model.draftText[row.nutrient] ?? "" },
                    set: { self.model.draftText[row.nutrient] = $0 }))
                    .font(.body)
                    .foregroundStyle(TokenColors.textPrimary)
                    .decimalKeyboard()
                    .focused($focusedNutrient, equals: row.nutrient)
                    .onSubmit { self.model.commitTarget(for: row.nutrient) }
                    .accessibilityLabel("Daily target for \(row.displayName)")
                    .accessibilityHint("Leave blank to remove the goal")
                Picker("Unit", selection: Binding(
                    get: { self.model.selectedUnits[row.nutrient] ?? row.unit },
                    set: { self.model.selectedUnits[row.nutrient] = $0 })) {
                    ForEach(model.units(for: row.nutrient), id: \.symbol) { candidate in
                        Text(candidate.symbol).tag(candidate)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Unit for \(row.displayName)")
                .onChange(of: row.unit) { _, _ in
                    self.model.commitTarget(for: row.nutrient)
                }
            }
            if let error = row.rowError {
                Text(error).font(.footnote).foregroundStyle(TokenColors.error)
            }
            Toggle(isOn: Binding(
                get: { row.showsOnToday },
                set: { self.model.setShowsOnToday($0, for: row.nutrient) })) {
                Text("Show on Today").font(.body)
            }
            .disabled(!row.hasTarget)
            .accessibilityLabel("Show \(row.displayName) on Today")
            .accessibilityHint("Turn off to hide this goal's bar on Today and in the Journal")
        }
    }
}

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
