import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders
import SwiftUI

/// The review screen for a captured Nutrition Facts panel: one row per nutrient, the values the
/// parser flagged highlighted and waiting for the user, and one button that hands the values on.
///
/// Nothing here decides a value is right. A row the parser read exactly as printed is shown as it
/// was read; a row it was unsure about says why, and cannot be used until the user confirms it or
/// types a value of their own. An unreadable panel says so and offers another look, rather than
/// filling the form with nothing.
///
/// No image is shown, stored or sent by this screen: it works on the text lines the capture session
/// read, which are passed in by the app target and dropped once the values have been handed over.
public struct LabelCaptureView: View {
    @ObservedObject var model: LabelCaptureViewModel
    /// Called with the reviewed product, and only when `model.canApply` is true.
    private let onUse: (ProductDefinition) -> Void
    /// Called when the user wants another look at the panel, so the capture session can read it again.
    private let onRetake: () -> Void
    /// The row being corrected, and the text typed for it. One row at a time, because there is one
    /// keyboard.
    @State private var editing: NutritionFactKey?
    @State private var draft = ""
    /// The serving size typed for a panel that stated none, or the one replacing a serving it did state.
    @State private var servingDraft = ""
    /// The compound row being corrected. One at a time, like the nutrient rows: there is one keyboard.
    @State private var editingAdditional: String?
    @State private var servingDraft = ""
    /// Whether the field for correcting a printed serving size is open.
    @State private var editingServing = false

    public init(
        model: LabelCaptureViewModel,
        onUse: @escaping (ProductDefinition) -> Void,
        onRetake: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onUse = onUse
        self.onRetake = onRetake
    }

    public var body: some View {
        Form {
            if model.isUnreadable {
                unreadableSection
            } else {
                servingSection
                Section("Nutrients") {
                    ForEach(model.rows) { row in
                        nutrientRow(row)
                    }
                }
                if !model.additionalRows.isEmpty {
                    additionalSection
                }
            }
            if let message = model.statusMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.textSecondary)
                        .accessibilityLabel(message)
                }
            }
            actions
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Check the label")
    }

    /// A panel with nothing readable in it: the user is told so plainly and offered another look.
    private var unreadableSection: some View {
        Section("Nothing to use") {
            Text(
                "No Nutrition Facts rows could be read from that shot. Nothing has been filled in. "
                    + "Try again with the panel flat, filling the frame and the text in focus.")
                .font(.body)
                .accessibilityLabel("No Nutrition Facts rows could be read. Nothing has been filled in.")
        }
    }

    /// The serving size as the panel printed it, flagged like any other value because it scales
    /// everything below it. A panel that stated none gets a field instead: the values stay per serving,
    /// so one serving has to be named before they can be used or scaled to an intake.
    private var servingSection: some View {
        Section("Serving size") {
            if model.servingIsMissing {
                Text("not stated")
                    .font(.body)
                    .foregroundStyle(TokenColors.textSecondary)
                    .accessibilityLabel("Serving size not stated by the panel")
                if let prompt = model.servingPrompt {
                    Text(prompt)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.error)
                        .accessibilityLabel(prompt)
                }
                servingEntry
            } else {
                let text = model.servingText ?? "not stated"
                HStack {
                    Text(text)
                        .font(.body)
                    Spacer()
                    if model.servingNeedsReview {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(TokenColors.warning)
                            .accessibilityLabel("Needs your confirmation")
                    } else if model.isServingConfirmed {
                        // Confirming clears the flag, so the answered state is read from the confirmation
                        // itself rather than from a flag that no longer stands.
                        Text("confirmed")
                            .font(.footnote)
                            .foregroundStyle(TokenColors.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Serving size \(text)"
                        + (model.servingNeedsReview
                            ? ", needs your confirmation"
                            : (model.isServingConfirmed ? ", confirmed" : "")))
                if model.servingNeedsReview {
                    Text(model.servingPrompt ?? "")
                        .font(.footnote)
                        .foregroundStyle(TokenColors.error)
                    Button("Confirm serving size") { model.confirmServing() }
                        .font(.body)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Confirm the serving size")
                }
                if model.servingNeedsReview {
                    correctServingControl
                }
                if editingServing {
                    servingEntry
                }
            }
        }
    }

    /// The control that opens the serving-size field for a serving the panel printed. Hidden when there is
    /// no serving to correct, which is the same rule the nutrient rows follow.
    @ViewBuilder
    private var correctServingControl: some View {
        if model.servingCanBeCorrected {
            Button("Correct") { editingServing = true }
                .font(.body)
                .buttonStyle(.borderless)
                .accessibilityLabel("Correct the serving size")
                .accessibilityHint("Types a different serving, with its unit")
        }
    }

    /// The field for a serving size the panel did not state. The unit is part of what is asked for,
    /// because "30" or "a biscuit" would leave the values below exactly as unscalable as they were.
    private var servingEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.servingPrompt ?? "")
                .font(.footnote)
                .foregroundStyle(TokenColors.error)
                .accessibilityLabel(model.servingPrompt ?? "")
            // No decimal keypad here: the answer is an amount with its unit, so the keyboard has to
            // offer the letters that spell the unit.
            TextField("One serving", text: $servingDraft)
                .font(.body)
                .accessibilityLabel("What one serving is, with its unit")
                .accessibilityHint("For example 30 g or 240 mL")
            if let message = model.servingSizeError {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.error)
                    .accessibilityLabel(message)
            }
            Button(model.servingIsMissing ? "Use this serving" : "Save this serving") {
                let accepted =
                    model.servingIsMissing
                    ? model.enterServingSize(text: servingDraft)
                    : model.correctServingSize(text: servingDraft)
                if accepted {
                    servingDraft = ""
                    editingServing = false
                }
            }
            .font(.body)
            .buttonStyle(.borderless)
            .accessibilityLabel("Use this serving size")
            .accessibilityHint("Keeps the values per serving, with this serving written down")
        }
    }

    /// One nutrient: the value as read, and the controls the row offers.
    ///
    /// A row the parser flagged is asked about: it says why, and it offers Confirm as well as Correct.
    /// A row that was read cleanly is not flagged, but it is still the user's to change, because
    /// recognition can turn one valid number into another valid one and nothing here would notice.
    private func nutrientRow(_ row: LabelCaptureRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name)
                    .font(.body)
                Spacer()
                Text(row.valueText)
                    .font(.body)
                    .foregroundStyle(TokenColors.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.accessibilityLabel)

            if row.needsConfirmation {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(TokenColors.warning)
                        .accessibilityLabel("Needs your confirmation")
                    Text(row.reviewSummary)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.error)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.name) needs your confirmation. \(row.reviewSummary)")
            }

            if editing == row.key {
                correctionEditor(row)
            } else {
                rowControls(row)
            }

            if !row.needsConfirmation, row.status == .confirmed || row.status == .corrected {
                Text(row.status == .corrected ? "Corrected by you" : "Confirmed by you")
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
                    .accessibilityLabel(
                        "\(row.name): \(row.valueText), "
                            + (row.status == .corrected ? "corrected by you" : "confirmed by you"))
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(row.needsConfirmation ? TokenColors.warning.opacity(0.12) : Color.clear)
    }

    /// The rows the panel states under its own names, under a heading of their own.
    ///
    /// These are the compounds the fifteen journal nutrients do not name, and they are why anyone scans
    /// a supplement panel, so they are shown like the rest: the name the label printed, the value as it
    /// was read, Confirm where the parser asked, and Correct for a row the user may have misread. They
    /// are kept out of the Nutrients section because they are not that list's rows and reading them as
    /// such would tell the user they are nutrients the journal knows about.
    private var additionalSection: some View {
        Section("Also on the label") {
            ForEach(model.additionalRows) { row in
                additionalRow(row)
            }
        }
    }

    /// One compound row: the value as read, and the controls the row offers, in the same shape as a
    /// nutrient row so a user who has just worked through one knows what to do with the next.
    private func additionalRow(_ row: LabelCaptureAdditionalRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name)
                    .font(.body)
                Spacer()
                Text(row.valueText)
                    .font(.body)
                    .foregroundStyle(TokenColors.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.accessibilityLabel)

            if row.needsConfirmation {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(TokenColors.warning)
                        .accessibilityLabel("Needs your confirmation")
                    Text(row.reviewSummary)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.error)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.name) needs your confirmation. \(row.reviewSummary)")
            }

            if editingAdditional == row.key {
                additionalCorrectionEditor(row)
            } else {
                additionalRowControls(row)
            }

            if !row.needsConfirmation, row.status == .confirmed || row.status == .corrected {
                Text(row.status == .corrected ? "Corrected by you" : "Confirmed by you")
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
                    .accessibilityLabel(
                        "\(row.name): \(row.valueText), "
                            + (row.status == .corrected ? "corrected by you" : "confirmed by you"))
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(row.needsConfirmation ? TokenColors.warning.opacity(0.12) : Color.clear)
    }

    @ViewBuilder
    private func additionalRowControls(_ row: LabelCaptureAdditionalRow) -> some View {
        if row.needsConfirmation {
            HStack {
                Button("Confirm") { model.confirmAdditional(key: row.key) }
                    .font(.body)
                    // Two buttons in one form row are both row actions under the automatic style, and
                    // tapping either can then fire both, so their hit areas have to stay apart.
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Confirm \(row.name)")
                    .accessibilityHint("Keeps the value as the label was read")
                Button("Correct") { beginCorrection(for: row) }
                    .font(.body)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Correct \(row.name)")
                    .accessibilityHint("Types a different amount for this row, zero included")
            }
        } else if row.canBeCorrected {
            Button("Correct") { beginCorrection(for: row) }
                .font(.body)
                .buttonStyle(.borderless)
                .accessibilityLabel("Correct \(row.name)")
                .accessibilityHint("Types a different amount for this row, zero included")
        }
    }

    /// The field a compound's correction is typed into, with the unit the label printed beside it. The
    /// unit is the one the value will be stored in, so a correction that names none keeps it.
    private func additionalCorrectionEditor(_ row: LabelCaptureAdditionalRow) -> some View {
        let unit = LabelCaptureViewModel.unit(of: row.value).symbol
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Amount", text: $draft)
                    .font(.body)
                    .amountKeyboard()
                    .accessibilityLabel("Amount for \(row.name)")
                    .accessibilityHint("Zero or more, in \(unit)")
                Text(unit)
                    .font(.body)
                    .foregroundStyle(TokenColors.textSecondary)
                    .accessibilityLabel("Unit \(unit)")
            }
            if let message = model.correctionError {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.error)
                    .accessibilityLabel(message)
            }
            // Borderless for the same reason as a nutrient row's own actions: under the automatic style
            // both of these become actions for the row, so tapping Cancel could save the draft as well.
            HStack {
                Button("Save") {
                    if model.correctAdditional(key: row.key, text: draft) { editingAdditional = nil }
                }
                .font(.body)
                .buttonStyle(.borderless)
                .accessibilityLabel("Save the corrected \(row.name)")
                Button("Cancel") {
                    editingAdditional = nil
                    draft = ""
                    // The refused correction is over, so its message goes with it rather than waiting
                    // under the next row's field.
                    model.clearCorrectionError()
                }
                .font(.body)
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop correcting \(row.name)")
            }
        }
    }

    /// Opens the amount field for one compound row, clearing the nutrient field beside it so the two
    /// cannot be confused for one another.
    private func beginCorrection(for row: LabelCaptureAdditionalRow) {
        model.clearCorrectionError()
        editing = nil
        editingAdditional = row.key
        draft = describeAmount(row.value)
    }

    /// The amount as it is typed into the correction field, or empty for a value that states none.
    private func describeAmount(_ value: NutrientValue) -> String {
        guard case .known(let amount, _) = value else { return "" }
        return NSDecimalNumber(decimal: amount).stringValue
    }

    /// The actions a row offers. A row still waiting for an answer gets Confirm as well as Correct; a
    /// row the user has already answered still gets Correct, because they may have read it wrong
    /// themselves; a row with no amount to correct gets nothing.
    @ViewBuilder
    private func rowControls(_ row: LabelCaptureRow) -> some View {
        if row.needsConfirmation {
            HStack {
                Button("Confirm") { model.confirm(row.key) }
                    .font(.body)
                    // Two buttons in one form row are both row actions under the automatic style, and
                    // tapping either can then fire both, so their hit areas have to stay apart.
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Confirm \(row.name)")
                    .accessibilityHint("Keeps the value as the label was read")
                correctButton(row)
            }
        } else if row.canBeCorrected {
            correctButton(row)
        }
    }

    private func correctButton(_ row: LabelCaptureRow) -> some View {
        Button("Correct") { beginCorrection(for: row) }
            .font(.body)
            .buttonStyle(.borderless)
            .accessibilityLabel("Correct \(row.name)")
            .accessibilityHint("Types a different amount for this row, zero included")
    }

    /// The text field a correction is typed into, with the row's own unit beside it.
    ///
    /// The unit beside the field is the one the value will be stored in, so a correction that names no
    /// unit stays in it. Zero is a value here: a panel states `0g` often, and `NutrientValue.known(0,
    /// unit)` is what such a row means.
    private func correctionEditor(_ row: LabelCaptureRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Amount", text: $draft)
                    .font(.body)
                    .amountKeyboard()
                    .accessibilityLabel("Amount for \(row.name)")
                    .accessibilityHint("Zero or more, in \(unitSymbol(for: row))")
                Text(unitSymbol(for: row))
                    .font(.body)
                    .foregroundStyle(TokenColors.textSecondary)
                    .accessibilityLabel("Unit \(unitSymbol(for: row))")
            }
            if let message = model.correctionError {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.error)
                    .accessibilityLabel(message)
            }
            // Borderless for the same reason as the row's own actions: under the automatic style both
            // of these become actions for the row, so tapping Cancel could save the draft as well.
            HStack {
                Button("Save") {
                    if model.correct(key: row.key, text: draft) { editing = nil }
                }
                .font(.body)
                .buttonStyle(.borderless)
                .accessibilityLabel("Save the corrected \(row.name)")
                Button("Cancel") {
                    editing = nil
                    draft = ""
                    // The refused correction is over, so its message goes with it rather than waiting
                    // under the next row's field.
                    model.clearCorrectionError()
                }
                .font(.body)
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop correcting \(row.name)")
            }
        }
    }

    /// The unit a correction will keep: the one the panel printed, or the one this row usually carries.
    private func unitSymbol(for row: LabelCaptureRow) -> String {
        LabelCaptureViewModel.unit(of: row.value, for: row.key).symbol
    }

    /// Opens the amount field for one row. The previous row's refused correction is forgotten on the
    /// way, so the new field never greets the user with another row's validation failure.
    private func beginCorrection(for row: LabelCaptureRow) {
        model.clearCorrectionError()
        editing = row.key
        if case .known(let amount, _) = row.value {
            draft = NSDecimalNumber(decimal: amount).stringValue
        } else {
            draft = ""
        }
    }

    /// The one button that hands values on, and the way back to the camera. The button stays disabled
    /// while any flagged value is unanswered, so a value the parser was unsure about can never be
    /// saved on the parser's word.
    private var actions: some View {
        Section {
            Button {
                if let product = model.makeProduct() { onUse(product) }
            } label: {
                Text("Use these values").font(.headline)
            }
            .disabled(!model.canApply)
            .accessibilityLabel("Use these values")
            .accessibilityHint("Fills the intake form with the values you checked")
            if model.canRetake {
                Button("Scan another label") {
                    model.retake()
                    editing = nil
                    draft = ""
                    editingAdditional = nil
                    onRetake()
                }
                .font(.body)
                .accessibilityLabel("Scan another label")
                .accessibilityHint("Goes back to the camera to read the panel again")
            }
        }
    }
}

/// The decimal keypad is only set where the platform has one. This package also builds for macOS,
/// where `keyboardType` does not exist, so it stays behind this one door.
private extension View {
    @ViewBuilder
    func amountKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}
