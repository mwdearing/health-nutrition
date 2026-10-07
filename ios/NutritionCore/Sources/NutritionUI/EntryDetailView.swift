import SwiftUI

public struct EntryDetailView: View {
    @ObservedObject var model: EntryDetailViewModel
    private let now: () -> Date
    private let onFinished: () -> Void
    @State private var confirmingDelete = false

    public init(model: EntryDetailViewModel, now: @escaping () -> Date = { Date() }, onFinished: @escaping () -> Void) {
        self.model = model
        self.now = now
        self.onFinished = onFinished
    }

    public var body: some View {
        Form {
            Section("Amounts") {
                ForEach(model.components) { component in
                    VStack(alignment: .leading) {
                        Text(component.name).font(.headline).foregroundStyle(TokenColors.textPrimary)
                        HStack {
                            TextField("Amount", text: draftBinding(component.id))
                                .font(.body)
                                .accessibilityLabel("Amount of \(component.name)")
                            Text(component.unit.symbol).font(.body).foregroundStyle(TokenColors.textSecondary)
                        }
                        // The same amount in the unit the reader chose, shown beside the field that
                        // edits the stored one. Saving writes the field back in the stored unit, so
                        // this line is a reading of the value and never an edit to it. It follows the
                        // draft as it is typed, and is hidden when there is no amount to read.
                        if let converted = model.convertedText(for: component.id) {
                            Text("\(converted) with your unit preference")
                                .font(.footnote)
                                .foregroundStyle(TokenColors.textSecondary)
                                .accessibilityLabel("Shown as \(converted)")
                        }
                        if component.amountText == "unknown" {
                            Text("Amount: \(component.amountText)")
                                .font(.footnote)
                                .foregroundStyle(TokenColors.textSecondary)
                                .accessibilityLabel("Amount of \(component.name)")
                                .accessibilityValue(component.amountText)
                        }
                        if let message = model.fieldErrors[component.id] {
                            Text(message).font(.footnote).foregroundStyle(TokenColors.error)
                        }
                    }
                }
                TextField("Reason for the change", text: $model.changeReason)
                    .font(.body)
                Button {
                    if model.saveDrafts(now: now()) { onFinished() }
                } label: {
                    Text("Save changes").font(.headline)
                }
                .accessibilityLabel("Save changes")
                .accessibilityHint("Adds a new revision and keeps the old one")
            }
            Section("Delivery") {
                ForEach(model.destinations) { row in
                    HStack {
                        Image(systemName: row.iconName)
                            .foregroundStyle(TokenColors.accent)
                            .accessibilityLabel("\(row.label) status icon")
                        Text(row.label).font(.body).foregroundStyle(TokenColors.textPrimary)
                        Spacer()
                        Text(row.stateText).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.label)
                    .accessibilityValue(row.stateText)
                }
            }
            Section("History") {
                ForEach(model.revisions) { revision in
                    VStack(alignment: .leading) {
                        Text("Revision \(revision.number)").font(.headline).foregroundStyle(TokenColors.textPrimary)
                        Text(revision.changeReason).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                        Text(revision.createdAt, style: .date).font(.footnote).foregroundStyle(TokenColors.textSecondary)
                    }
                }
            }
            if let message = model.errorMessage {
                Text(message).font(.footnote).foregroundStyle(TokenColors.error)
            }
            Section {
                Button {
                    if model.repeatEntry(now: now()) != nil { onFinished() }
                } label: {
                    Text("Repeat now").font(.headline)
                }
                .accessibilityLabel("Repeat this entry now")
                .accessibilityHint("Adds a new entry with the same amounts at the current time")
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Text("Delete entry").font(.headline)
                }
                .accessibilityLabel("Delete entry")
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Entry")
        .confirmationDialog("Delete this entry?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if model.delete(now: now()) { onFinished() }
            }
            .accessibilityLabel("Confirm delete")
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Cancel delete")
        } message: {
            Text("The entry is hidden and its history is kept.")
        }
        .onAppear { model.load(now: now()) }
    }

    private func draftBinding(_ id: String) -> Binding<String> {
        Binding(get: { model.drafts[id] ?? "" }, set: { model.drafts[id] = $0 })
    }
}
