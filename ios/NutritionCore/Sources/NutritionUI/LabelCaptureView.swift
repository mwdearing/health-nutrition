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
    /// Called when the user wants to photograph the rest of the panel, so the capture session can read
    /// it again without throwing the values already on screen away.
    private let onAddPhoto: () -> Void
    /// The text typed into whichever correction field is open. The row being corrected is held by the
    /// view model, so beginning one row's correction closes the editor open on any other.
    @State private var draft = ""
    /// The serving size typed for a panel that stated none, or the one replacing a serving it did state.
    @State private var servingDraft = ""
    /// The unit a compound correction is stated in, chosen from the picker beside its amount field. It
    /// starts on the unit the label printed.
    @State private var additionalUnit: MeasureUnit = .g
    /// Whether the field for correcting a printed serving size is open.
    @State private var editingServing = false

    public init(
        model: LabelCaptureViewModel,
        onUse: @escaping (ProductDefinition) -> Void,
        onRetake: @escaping () -> Void = {},
        onAddPhoto: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onUse = onUse
        self.onRetake = onRetake
        self.onAddPhoto = onAddPhoto
    }

    public var body: some View {
        Form {
            if let header = model.photoHeader {
                photoHeader(header)
            }
            if model.isUnreadable {
                unreadableSection
            } else {
                kindSection
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

    /// What the panel is recorded as, read off its heading and changeable here.
    ///
    /// The heading settles it in the ordinary case — a Supplement Facts panel is a supplement — and the two
    /// cases it cannot settle are the ones this row exists for: a drink prints a Nutrition Facts panel, and
    /// a heading cropped out of the frame reads as no heading at all. Getting it wrong is what would put a
    /// drink or a vitamin in the day's count of foods, so it is shown rather than assumed, and changing it
    /// changes what the snapshot is stored as.
    private var kindSection: some View {
        Section("Kind") {
            Picker("Kind", selection: $model.kind) {
                ForEach(ProductKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Kind of product")
            .accessibilityHint("Food, drink or supplement, read from the panel and changeable here")
            Text(model.kindExplanation)
                .font(.footnote)
                .foregroundStyle(TokenColors.textSecondary)
                .accessibilityLabel(model.kindExplanation)
        }
    }

    /// Where the values came from, once more than one photo has been merged into them: a panel that
    /// does not fit in one frame is read in several, and saying so tells the user why a row they did
    /// not point the camera at is on the screen.
    private func photoHeader(_ text: String) -> some View {
        Section {
            Text(text)
                .font(.footnote)
                .foregroundStyle(TokenColors.textSecondary)
                .accessibilityLabel(text)
        }
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

            if row.hasConflict {
                conflictNotice(row)
            }

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

            if model.editingKey == row.key {
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
        .listRowBackground(rowWarningBackground(for: row))
    }

    /// A row the photos read differently: every reading is shown and the user picks one.
    ///
    /// Nothing here chooses for them. A photo that saw a column at an angle can turn one printed digit
    /// into another, and the row on screen cannot tell which photo was the clearer one, so it shows
    /// what each of them said and lets the answer come from the bottle in the user's hand.
    ///
    /// A panel read across three photos can be read three ways rather than two, so every candidate is
    /// listed rather than only the first disagreement: dropping a third reading would decide for the
    /// user that two photos outvote one. A reading more than one photo agrees on says so, which is
    /// worth knowing before choosing and is not itself a reason to choose.
    @ViewBuilder
    private func conflictNotice(_ row: LabelCaptureRow) -> some View {
        if row.hasConflict {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(TokenColors.error)
                        .accessibilityLabel("The photos read this row differently")
                    Text("Conflict: tap to choose")
                        .font(.footnote)
                        .foregroundStyle(TokenColors.error)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(row.name) was read differently in \(row.candidates.count + 1) photos. Tap to choose.")
                Text(row.displayedCandidate.summary)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
                    .accessibilityLabel(row.displayedCandidate.summary)
                Button("Keep photo \(row.frameIndex)") { model.confirm(row.key) }
                    .font(.body)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Keep \(row.valueText) for \(row.name), from photo \(row.frameIndex)")
                ForEach(row.candidates) { candidate in
                    candidateRow(
                        candidate,
                        rowName: row.name,
                        keep: { model.chooseConflict(key: row.key, taking: candidate.frameIndex) })
                }
            }
        }
    }

    /// One reading of a conflicted row: what the photo read, and the button that keeps it.
    ///
    /// The button is labelled by the value it keeps rather than by its position, because there can be
    /// any number of them and "the other one" is no longer a thing the screen can say.
    private func candidateRow(
        _ candidate: LabelCaptureCandidate, rowName: String, keep: @escaping () -> Void
    ) -> some View {
        let value = LabelCaptureRow.displayText(candidate.value)
        return HStack {
            Text(candidate.summary)
                .font(.footnote)
                .foregroundStyle(TokenColors.textSecondary)
            Spacer()
            Button("Keep \(value)") { keep() }
                .font(.body)
                .buttonStyle(.borderless)
                .accessibilityLabel("Keep \(value) for \(rowName), from photo \(candidate.frameIndex)")
        }
    }

    /// The tinted background of one row: a row that needs the user's answer is called out, whether the
    /// parser flagged it or two photos disagreed about it.
    private func rowWarningBackground(for row: LabelCaptureRow) -> Color {
        row.isPending ? TokenColors.warning.opacity(0.12) : Color.clear
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

            if row.hasConflict {
                additionalConflictNotice(row)
            }

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

            if model.editingAdditionalKey == row.key {
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
        .listRowBackground(row.isPending ? TokenColors.warning.opacity(0.12) : Color.clear)
    }

    /// The same choice a named nutrient row offers, for a compound the photos read differently.
    /// A compound is stored under the slug of its printed name, so every reading has to reach the same
    /// row for the choice to be possible at all, and a third photo's reading is kept beside the first
    /// two rather than dropped.
    @ViewBuilder
    private func additionalConflictNotice(_ row: LabelCaptureAdditionalRow) -> some View {
        if row.hasConflict {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(TokenColors.error)
                        .accessibilityLabel("The photos read this row differently")
                    Text("Conflict: tap to choose")
                        .font(.footnote)
                        .foregroundStyle(TokenColors.error)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(row.name) was read differently in \(row.candidates.count + 1) photos. Tap to choose.")
                Text(row.displayedCandidate.summary)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
                    .accessibilityLabel(row.displayedCandidate.summary)
                Button("Keep photo \(row.frameIndex)") { model.confirmAdditional(key: row.key) }
                    .font(.body)
                    .buttonStyle(.borderless)
                    .accessibilityLabel(
                        "Keep \(row.valueText) for \(row.name), from photo \(row.frameIndex)")
                ForEach(row.candidates) { candidate in
                    candidateRow(
                        candidate,
                        rowName: row.name,
                        keep: {
                            model.chooseConflict(additionalKey: row.key, taking: candidate.frameIndex)
                        })
                }
            }
        }
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

    /// The field a compound's correction is typed into, with a unit picker beside it. A compound has
    /// no usual unit to fall back on, so the unit is chosen rather than typed: the picker offers the
    /// mass units and the international unit a supplement states a compound in, and the chosen one is
    /// what the corrected value is stored in.
    private func additionalCorrectionEditor(_ row: LabelCaptureAdditionalRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Amount", text: $draft)
                    .font(.body)
                    .amountKeyboard()
                    .accessibilityLabel("Amount for \(row.name)")
                    .accessibilityHint("Zero or more")
                Picker("Unit", selection: $additionalUnit) {
                    ForEach(LabelCaptureViewModel.additionalUnits, id: \.symbol) { candidate in
                        Text(candidate.symbol).tag(candidate)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Unit for \(row.name)")
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
                    if model.correctAdditional(key: row.key, text: draft, unit: additionalUnit) {
                        model.endCorrection()
                    }
                }
                .font(.body)
                .buttonStyle(.borderless)
                .accessibilityLabel("Save the corrected \(row.name)")
                Button("Cancel") {
                    model.endCorrection()
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

    /// Opens the amount field for one compound row. The model closes the nutrient editor beside it, so
    /// the two cannot be open together, and the picker starts on the unit the label printed.
    private func beginCorrection(for row: LabelCaptureAdditionalRow) {
        model.beginCorrection(forAdditional: row.key)
        additionalUnit = model.additionalUnit(for: row.key)
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
                    if model.correct(key: row.key, text: draft) { model.endCorrection() }
                }
                .font(.body)
                .buttonStyle(.borderless)
                .accessibilityLabel("Save the corrected \(row.name)")
                Button("Cancel") {
                    model.endCorrection()
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

    /// Opens the amount field for one row. The model closes any compound editor beside it, and the
    /// previous row's refused correction is forgotten on the way, so the new field never greets the
    /// user with another row's validation failure.
    private func beginCorrection(for row: LabelCaptureRow) {
        model.beginCorrection(for: row.key)
        if case .known(let amount, _) = row.value {
            draft = NSDecimalNumber(decimal: amount).stringValue
        } else {
            draft = ""
        }
    }

    /// The one button that hands values on, the way to photograph the rest of the panel, and the way back
    /// to the camera. The hand-off button stays disabled while any flagged value is unanswered and
    /// while any row is still a conflict, so a value the parser was unsure about, or a row two photos
    /// read differently, can never be saved on the parser's word alone.
    private var actions: some View {
        Section {
            Button {
                if let product = model.makeProduct() { onUse(product) }
            } label: {
                Text(model.primaryActionTitle).font(.headline)
            }
            .disabled(!model.canApply)
            .accessibilityLabel(model.primaryActionTitle)
            .accessibilityHint("Fills the intake form with the values you checked")
            if model.canAddPhoto {
                Button("Add another photo") {
                    // The model flips first, so the sheet is already showing the camera by the time the
                    // host is told, however it chooses to react to the request.
                    model.beginAddingPhoto()
                    // The camera takes the screen away, and a draft held here would not come back with
                    // it: an editor left open would return against the value it was opened for, and a
                    // half-typed amount would look like an answer the user never gave. So the edit is
                    // closed here, on the way out, and only what was already saved on the model is kept.
                    draft = ""
                    servingDraft = ""
                    editingServing = false
                    model.clearCorrectionError()
                    onAddPhoto()
                }
                .font(.body)
                .accessibilityLabel("Add another photo")
                .accessibilityHint("Goes back to the camera to read the rest of the panel into these values")
            }
            if model.canRetake {
                Button("Scan another label") {
                    model.retake()
                    draft = ""
                    onRetake()
                }
                .font(.body)
                .accessibilityLabel("Scan another label")
                .accessibilityHint("Throws these values away and goes back to the camera to read a new panel")
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
