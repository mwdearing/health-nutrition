import SwiftUI
import NutritionDomain

/// Inline editing of the daily targets a person sets.
public struct GoalsView: View {
    @ObservedObject var model: GoalsViewModel
    @FocusState private var focusedNutrient: String?
    @State private var showingClearConfirmation = false
    /// The sheet's presence and its model are one state, so the sheet cannot appear before its content has a model.
    @State private var setupModel: GoalSetupViewModel?
    @State private var saveNotice: SaveNotice?

    public init(model: GoalsViewModel) {
        self.model = model
    }

    public var body: some View {
        List {
            Section {
                Text("Set your own daily targets, or leave them empty.")
                    .font(.body)
                    .foregroundStyle(TokenColors.textSecondary)
                Button("Help me set my goals") {
                    self.setupModel = GoalSetupViewModel(goals: self.model)
                }
            }
            MacroSplitSection(model: model)
            if model.offersActivityGoal {
                Section {
                    Toggle(GoalsViewModel.activityGoalTitle, isOn: Binding(
                        get: { self.model.addsActiveEnergyToGoal },
                        set: { self.model.setAddsActiveEnergyToGoal($0) }))
                } footer: {
                    Text(GoalsViewModel.activityGoalFooter)
                }
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
            if model.clearedGoal != nil {
                UndoToast(GoalsViewModel.clearedMessage) { self.model.undoClear() }
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Daily goals")
        .onAppear { self.model.load() }
        .saveConfirmation(saveNotice)
        .onChange(of: model.savedSerial) { _, _ in self.saveNotice = SaveNotice(SaveLabels.goalsSaved) }
        .onChange(of: focusedNutrient) { previous, _ in
            if let previous { self.model.commitTarget(for: previous) }
        }
        .sheet(item: $setupModel, onDismiss: {
            self.setupModel?.clearAnswers()
            self.setupModel = nil
        }) { setupModel in
            NavigationStack {
                GoalSetupView(model: setupModel, onSaved: { self.saveNotice = SaveNotice(SaveLabels.goalsSaved) })
            }
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
            ReferenceGoalHintLine(model: model, nutrient: row.nutrient)
            HStack {
                TextField("None", text: Binding(
                    get: { self.model.draftText[row.nutrient] ?? "" },
                    set: { self.model.userEditedDraft($0, for: row.nutrient) }))
                    .font(.body)
                    .foregroundStyle(TokenColors.textPrimary)
                    .decimalKeyboard()
                    .focused($focusedNutrient, equals: row.nutrient)
                    .onSubmit { self.model.submitTarget(for: row.nutrient) }
                    .accessibilityLabel("Daily target for \(row.displayName)")
                Picker("Unit", selection: Binding(
                    get: { self.model.selectedUnits[row.nutrient] ?? row.unit },
                    set: { self.model.selectedUnits[row.nutrient] = $0 })) {
                    ForEach(model.units(for: row.nutrient), id: \.symbol) { candidate in
                        Text(candidate.screenSymbol).tag(candidate)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Unit for \(row.displayName)")
                .onChange(of: row.unit) { _, _ in
                    self.model.commitTarget(for: row.nutrient)
                }
                Button("Clear") {
                    self.focusedNutrient = nil
                    self.model.clearTarget(for: row.nutrient)
                }
                .disabled(!row.hasTarget)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Clear goal for \(row.displayName)")
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
