import SwiftUI

/// One medication's dose history: its doses newest first, each with its day, time, amount and note. A dose can be
/// corrected, or deleted after a confirmation. The screen only shows what was logged; it never offers a view on a
/// dose.
public struct MedicationHistoryView: View {
    @StateObject private var model: MedicationHistoryViewModel
    /// The dose whose edit sheet is open; nil while no sheet is open.
    @State private var editing: DoseTarget?
    /// The dose waiting for the delete confirmation; nil while none is waiting.
    @State private var pendingDelete: UUID?

    private let reminders: MedicationReminderController?
    private let onClose: (Bool) -> Void

    /// - Parameters:
    ///   - model: the history this screen reads and changes.
    ///   - reminders: the medication reminders; nil where the system does not schedule them, which hides the Reminder section.
    ///   - onClose: called when the screen goes away, with whether a dose was changed or deleted.
    public init(
        model: MedicationHistoryViewModel, reminders: MedicationReminderController? = nil,
        onClose: @escaping (Bool) -> Void
    ) {
        _model = StateObject(wrappedValue: model)
        self.reminders = reminders
        self.onClose = onClose
    }

    public var body: some View {
        List {
            if let message = model.errorMessage {
                InlineNotice(message, tone: .failed)
            }
            if model.rows.isEmpty && model.errorMessage == nil {
                Text("No dose logged yet")
                    .foregroundStyle(TokenColors.textSecondary)
            }
            if model.canRemind, let reminders {
                MedicationReminderSection(medicationID: model.medicationID, reminders: reminders)
            }
            Section {
                ForEach(model.rows) { row in
                    Button { self.editing = DoseTarget(id: row.id) } label: { MedicationHistoryRowText(row: row) }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { self.pendingDelete = row.id }
                        }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle(model.title)
        .confirmationDialog("Delete this dose?", isPresented: isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete the dose", role: .destructive) {
                if let id = self.pendingDelete { self.model.deleteDose(id: id) }
                self.pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { self.pendingDelete = nil }
        } message: {
            Text("This removes the dose from the log on this device. It cannot be undone.")
        }
        .sheet(item: $editing) { target in
            EditDoseSheet(model: model, doseID: target.id)
        }
        .onAppear { model.load() }
        .onDisappear { onClose(model.didChange) }
    }

    /// Whether the delete confirmation is showing, read from the dose waiting for it.
    private var isConfirmingDelete: Binding<Bool> {
        Binding(
            get: { self.pendingDelete != nil },
            set: { if !$0 { self.pendingDelete = nil } })
    }
}

/// The Reminder section: a switch for "Remind me on due days", the time while it is on, the controller's message,
/// and a plain line on what is pending or why nothing is.
private struct MedicationReminderSection: View {
    let medicationID: UUID
    @ObservedObject var reminders: MedicationReminderController

    private static let defaultTime = ReminderTime(hour: 9, minute: 0)

    var body: some View {
        Section {
            Toggle("Remind me on due days", isOn: Binding(
                get: { self.reminders.time(for: self.medicationID) != nil },
                set: { on in
                    Task { await self.reminders.setReminder(on ? Self.defaultTime : nil, for: self.medicationID) }
                }))
            if let time = reminders.time(for: medicationID) {
                DatePicker("Time", selection: Binding(
                    get: { Self.date(for: time) },
                    set: { picked in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: picked)
                        let chosen = ReminderTime(hour: parts.hour ?? 9, minute: parts.minute ?? 0)
                        Task { await self.reminders.setReminder(chosen, for: self.medicationID) }
                    }), displayedComponents: .hourAndMinute)
            }
            if let message = reminders.message {
                InlineNotice(message, tone: .failed)
            }
        } header: {
            Text("Reminder")
        } footer: {
            if let footer = reminders.footer(for: medicationID) {
                Text(footer)
            }
        }
    }

    private static func date(for time: ReminderTime) -> Date {
        Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
    }
}

/// Identifies the dose whose edit sheet is open.
private struct DoseTarget: Identifiable {
    /// The dose's identifier.
    let id: UUID
}

/// One dose's text: its day and time on one line, then its amount, then its note when there is one.
private struct MedicationHistoryRowText: View {
    /// The row to show.
    let row: MedicationHistoryRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(row.dayText), \(row.timeText)")
            Text(row.amountText)
                .font(.footnote).foregroundStyle(TokenColors.textSecondary)
            if let note = row.noteText {
                Text(note)
                    .font(.footnote).foregroundStyle(TokenColors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Edit dose sheet: the amount, the time taken and the note of one dose, prefilled from what is stored. The model
/// checks what was typed and returns the problem; nothing is saved until the check passes.
private struct EditDoseSheet: View {
    /// The history the dose belongs to.
    let model: MedicationHistoryViewModel
    /// The dose being edited.
    let doseID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var amountText: String
    @State private var takenAt: Date
    /// The stored time the sheet opened with. The picker's range always includes it, so SwiftUI never clamps an
    /// untouched time and an edit of the amount or note keeps the logged time and zone.
    private let storedTakenAt: Date
    @State private var noteText: String
    @State private var errorText: String?

    init(model: MedicationHistoryViewModel, doseID: UUID) {
        self.model = model
        self.doseID = doseID
        let draft = model.draft(for: doseID)
        _amountText = State(initialValue: draft?.amountText ?? "")
        let storedTakenAt = draft?.takenAt ?? Date()
        self.storedTakenAt = storedTakenAt
        _takenAt = State(initialValue: storedTakenAt)
        _noteText = State(initialValue: draft?.noteText ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledField("Amount", spokenTitle: true) { focus in
                        TextField(text: $amountText, prompt: Text("For example, 5")) { Text("Amount") }
                            .labelsHidden()
                            .focused(focus)
                        #if os(iOS)
                            .keyboardType(.decimalPad)
                        #endif
                    }
                    // A dose is logged once it has been taken, so the time stops at now, or at the stored time when the
                    // clock or zone moved since it was logged.
                    DatePicker("Time taken", selection: $takenAt, in: ...max(Date(), storedTakenAt))
                    LabeledField("Note (optional)", spokenTitle: true) { focus in
                        TextField(text: $noteText, prompt: Text("For example, after breakfast")) {
                            Text("Note (optional)")
                        }
                        .labelsHidden()
                        .focused(focus)
                    }
                }
                if let errorText {
                    InlineNotice(errorText, tone: .failed)
                }
            }
            .navigationTitle("Edit dose")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        errorText = model.saveEdit(
                            doseID: doseID, amountText: amountText, takenAt: takenAt, noteText: noteText)
                        if errorText == nil { dismiss() }
                    }
                }
            }
        }
    }
}
