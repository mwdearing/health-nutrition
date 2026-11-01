import NutritionDomain
import SwiftUI

/// The Medication log screen: the active medications with their last dose and schedule standing, the archived
/// ones below them, and the way in to add a medication, log a dose with Undo and archive a medication. Plain facts
/// only: the screen never suggests, grades or checks a dose, and it never shows a dose's site.
public struct MedicationLogView: View {
    @ObservedObject var model: MedicationLogViewModel
    @State private var isAdding = false
    /// The row whose Log a dose sheet is open; nil while no sheet is open.
    @State private var loggingRow: MedicationRow?

    /// - Parameter model: the medication log this screen reads and changes.
    public init(model: MedicationLogViewModel) {
        self.model = model
    }

    public var body: some View {
        List {
            if let undo = model.undoText {
                Section {
                    HStack {
                        Text(undo).font(.footnote)
                        Spacer()
                        Button("Undo") { self.model.undoLastDose() }
                    }
                }
            }
            Section {
                Button("Add medication") { self.isAdding = true }
            }
            Section {
                ForEach(model.rows) { row in
                    Button { self.loggingRow = row } label: { MedicationRowText(row: row) }
                        .swipeActions(edge: .trailing) {
                            Button("Archive") { self.model.setArchived(row.id, archived: true) }
                        }
                }
            }
            if !model.archivedRows.isEmpty {
                Section("Archived") {
                    ForEach(model.archivedRows) { row in
                        MedicationRowText(row: row)
                            .swipeActions(edge: .trailing) {
                                Button("Unarchive") { self.model.setArchived(row.id, archived: false) }
                            }
                    }
                }
            }
            if let message = model.errorMessage {
                InlineNotice(message, tone: .failed)
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Medication log")
        .onAppear { self.model.load() }
        .sheet(isPresented: $isAdding) {
            AddMedicationSheet(model: model)
        }
        .sheet(item: $loggingRow) { row in
            LogDoseSheet(model: model, row: row)
        }
    }
}

/// One medication's text: its name, then its unit and schedule, then the last dose and the days since and the
/// schedule standing when there are any.
private struct MedicationRowText: View {
    /// The row to show.
    let row: MedicationRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.name)
            Text(row.scheduleText.map { "\(row.unitText), \($0)" } ?? row.unitText)
                .font(.footnote).foregroundStyle(TokenColors.textSecondary)
            Text(row.lastDoseText)
                .font(.footnote).foregroundStyle(TokenColors.textSecondary)
            if let daysSince = row.daysSinceText {
                Text(daysSince)
                    .font(.footnote).foregroundStyle(TokenColors.textSecondary)
            }
            if let status = row.statusText {
                Text(status)
                    .font(.footnote).foregroundStyle(TokenColors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Add medication sheet: a name, a unit and an optional schedule in days. The model checks what was typed
/// and returns the problem; nothing is saved until the check passes.
private struct AddMedicationSheet: View {
    /// The medication log the medication is saved to.
    let model: MedicationLogViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var unit = MedicationUnit.mg
    @State private var scheduleText = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Unit", selection: $unit) {
                        ForEach(MedicationUnit.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    TextField("Every how many days", text: $scheduleText)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
                }
                if let errorText {
                    InlineNotice(errorText, tone: .failed)
                }
            }
            .navigationTitle("Add medication")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        errorText = model.addMedication(name: name, unit: unit, scheduleDaysText: scheduleText)
                        if errorText == nil { dismiss() }
                    }
                }
            }
        }
    }
}

/// The Log a dose sheet for one medication: an amount in the medication's unit, the time taken (now by default),
/// an optional injection site and an optional note. The site is saved and never read back on this screen.
private struct LogDoseSheet: View {
    /// The medication log the dose is saved to.
    let model: MedicationLogViewModel
    /// The medication the dose is logged for.
    let row: MedicationRow
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var takenAt = Date()
    @State private var siteText = ""
    @State private var noteText = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(row.name) {
                    HStack {
                        TextField("Amount", text: $amountText)
                        #if os(iOS)
                            .keyboardType(.decimalPad)
                        #endif
                        Text(row.unitText).foregroundStyle(TokenColors.textSecondary)
                    }
                    DatePicker("Time taken", selection: $takenAt)
                }
                Section {
                    TextField("Injection site (optional)", text: $siteText)
                    TextField("Note (optional)", text: $noteText)
                }
                if let errorText {
                    InlineNotice(errorText, tone: .failed)
                }
            }
            .navigationTitle("Log a dose")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        errorText = model.logDose(
                            medicationID: row.id, amountText: amountText, takenAt: takenAt,
                            siteText: siteText, noteText: noteText)
                        if errorText == nil { dismiss() }
                    }
                }
            }
        }
    }
}
