import NutritionDomain
import SwiftUI

/// The guided goal setup, one screen per step, shown as a sheet from the Goals screen.
///
/// Each step asks one thing, shows where the person is ("Step 2 of 5") and moves on with a Next button.
/// The answers are not stored: they are cleared when the sheet closes, and only the targets a person
/// saves on the last screen leave it.
public struct GoalSetupView: View {
    @ObservedObject var model: GoalSetupViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedKey: String?

    public init(model: GoalSetupViewModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.l) {
                Text(model.stepLabel)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
                    .accessibilityLabel(model.stepLabel)
                stepContent
                navigation
            }
            .padding(DesignSpacing.m)
        }
        .background(TokenColors.background)
        .navigationTitle("Set your goals")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .onDisappear { model.clearAnswers() }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .aim: aimStep
        case .about: aboutStep
        case .body: bodyStep
        case .activity: activityStep
        case .pace: paceStep
        case .results: resultsStep
        }
    }

    private var aimStep: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m) {
            heading("What would you like to do?")
            Text(GoalSetupViewModel.privacyNotice)
                .font(.footnote)
                .foregroundStyle(TokenColors.textSecondary)
            choice("Lose weight", selected: model.aim == .lose) { model.aim = .lose }
            choice("Maintain my weight", selected: model.aim == .maintain) { model.aim = .maintain }
            choice("Gain weight", selected: model.aim == .gain) { model.aim = .gain }
            choice("Just track, no targets", selected: model.aim == .justTrack) { model.aim = .justTrack }
        }
    }

    private var aboutStep: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m) {
            heading("About you")
            Text("Used only to work out the targets.")
                .font(.footnote)
                .foregroundStyle(TokenColors.textSecondary)
            choice("Female", selected: model.sex == .female) { model.sex = .female }
            choice("Male", selected: model.sex == .male) { model.sex = .male }
            choice("Prefer not to say", selected: model.sex == .unspecified) { model.sex = .unspecified }
            LabeledField("Age in years") { focus in
                TextField(text: $model.ageText, prompt: Text("For example, 30")) {
                    Text("Age in years")
                }
                .labelsHidden()
                .font(.body)
                .foregroundStyle(TokenColors.textPrimary)
                .integerKeyboard()
                .focused(focus)
            }
        }
    }

    @ViewBuilder
    private var bodyStep: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m) {
            heading("Your height and weight")
            if model.unitSystem == .usCustomary {
                measured("Height in feet", text: $model.heightFeetText, prompt: "For example, 5", decimal: false)
                measured("Height in inches", text: $model.heightInchesText, prompt: "For example, 10", decimal: true)
                measured("Weight in pounds", text: $model.weightPoundsText, prompt: "For example, 176", decimal: true)
            } else {
                measured("Height in centimeters", text: $model.heightCentimetersText, prompt: "For example, 170", decimal: true)
                measured("Weight in kilograms", text: $model.weightKilogramsText, prompt: "For example, 70", decimal: true)
            }
        }
    }

    private var activityStep: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m) {
            heading("How active are you in a usual week?")
            ForEach(ActivityLevel.allCases, id: \.summary) { level in
                choice(level.summary, selected: model.activity == level) { model.activity = level }
            }
        }
    }

    private var paceStep: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m) {
            heading(model.aim == .gain ? "How fast would you like to gain?" : "How fast would you like to lose?")
            ForEach(model.paceOptions, id: \.label) { option in
                choice(option.label, selected: model.selectedPaceKilograms == option.kilogramsPerWeek) {
                    model.selectedPaceKilograms = option.kilogramsPerWeek
                }
            }
        }
    }

    @ViewBuilder
    private var resultsStep: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m) {
            if model.aim == .justTrack {
                heading(model.justTrackHeading)
                Text(model.justTrackMessage)
                    .font(.body)
                    .foregroundStyle(TokenColors.textPrimary)
            } else {
                if let error = model.resultError {
                    InlineNotice(error, tone: .failed)
                }
            }
            if !model.draftTargets.isEmpty {
                heading("Your daily targets")
                Text("You can change any number before you save.")
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
                if let note = model.adjustmentNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.textPrimary)
                }
                ForEach(resultRows, id: \.key) { row in
                    LabeledField(row.label, error: model.fieldErrors[row.key]) { focus in
                        TextField(text: draftBinding(row.key), prompt: Text(row.label)) {
                            Text(row.label)
                        }
                        .labelsHidden()
                        .font(.body)
                        .foregroundStyle(TokenColors.textPrimary)
                        .decimalKeyboard()
                        .focused(focus)
                    }
                }
                if model.hasExistingTargets {
                    Text(GoalSetupViewModel.replaceNotice)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.textSecondary)
                }
                Text(GoalSetupViewModel.estimateNotice)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var navigation: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s) {
            if model.step == .results {
                if model.aim == .justTrack {
                    PrimaryCapsule("Done") { dismiss() }
                } else if !model.draftTargets.isEmpty {
                    PrimaryCapsule("Save goals") {
                        if model.save() { dismiss() }
                    }
                }
            } else {
                PrimaryCapsule("Next") { model.next() }
                    .disabled(!model.canGoNext)
            }
            if model.step != .aim {
                QuietCapsule("Back") { model.back() }
            }
        }
    }

    private struct ResultRow {
        let key: String
        let label: String
    }

    private var resultRows: [ResultRow] {
        [
            ResultRow(key: "energy", label: "Energy (kcal)"),
            ResultRow(key: "protein", label: "Protein (g)"),
            ResultRow(key: "carbohydrate", label: "Carbohydrate (g)"),
            ResultRow(key: "fat", label: "Fat (g)"),
            ResultRow(key: "fiber", label: "Fiber (g)"),
        ]
    }

    private func draftBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { model.draftTargets[key] ?? "" },
            set: { model.draftTargets[key] = $0 })
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.title2.weight(.semibold))
            .foregroundStyle(TokenColors.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    /// One answer among a short list. The selected one says so to VoiceOver as well as by its mark.
    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DesignSpacing.s) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(TokenColors.textPrimary)
                Spacer(minLength: DesignSpacing.s)
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(TokenColors.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(DesignSpacing.m)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                selected ? TokenColors.accentTint : TokenColors.surface,
                in: RoundedRectangle(cornerRadius: DesignRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func measured(_ label: String, text: Binding<String>, prompt: String, decimal: Bool) -> some View {
        LabeledField(label) { focus in
            TextField(text: text, prompt: Text(prompt)) {
                Text(label)
            }
            .labelsHidden()
            .font(.body)
            .foregroundStyle(TokenColors.textPrimary)
            .decimalKeyboard(decimal)
            .focused(focus)
        }
    }
}

private extension View {
    /// A whole-number keyboard for the age field.
    @ViewBuilder
    func integerKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }

    /// The decimal keyboard for the amounts, which is the number keyboard for a whole number.
    @ViewBuilder
    func decimalKeyboard(_ decimal: Bool = true) -> some View {
        #if os(iOS)
        self.keyboardType(decimal ? .decimalPad : .numberPad)
        #else
        self
        #endif
    }
}
