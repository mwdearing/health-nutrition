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
    /// everything below it.
    private var servingSection: some View {
        Section("Serving size") {
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
                Text("The parser had to correct this serving size. Confirm it, or scan the panel again.")
                    .font(.footnote)
                    .foregroundStyle(TokenColors.error)
                Button("Confirm serving size") { model.confirmServing() }
                    .font(.body)
                    .accessibilityLabel("Confirm the serving size")
            }
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

    /// The actions a row offers. A row still waiting for an answer gets Confirm as well as Correct; a
    /// row the user has already answered still gets Correct, because they may have read it wrong
    /// themselves; a row with no amount to correct gets nothing.
    @ViewBuilder
    private func rowControls(_ row: LabelCaptureRow) -> some View {
        if row.needsConfirmation {
            HStack {
                Button("Confirm") { model.confirm(row.key) }
                    .font(.body)
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
            HStack {
                Button("Save") {
                    if model.correct(key: row.key, text: draft) { editing = nil }
                }
                .font(.body)
                .accessibilityLabel("Save the corrected \(row.name)")
                Button("Cancel") {
                    editing = nil
                    draft = ""
                }
                .font(.body)
                .accessibilityLabel("Stop correcting \(row.name)")
            }
        }
    }

    /// The unit a correction will keep: the one the panel printed, or the one this row usually carries.
    private func unitSymbol(for row: LabelCaptureRow) -> String {
        LabelCaptureViewModel.unit(of: row.value, for: row.key).symbol
    }

    private func beginCorrection(for row: LabelCaptureRow) {
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
