import SwiftUI

/// One entry, read first: what it is, what it added, where its values came from, where it was sent, and
/// how it was changed. The amounts and the time are always shown and can be edited; only Save and the
/// optional note appear once something has changed.
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
        Group {
            if model.isDeleted {
                EmptyState(
                    title: "Entry", message: "This entry is no longer available.", systemImage: "tray",
                    actionTitle: "Close", action: onFinished)
            } else {
                form
            }
        }
        .navigationTitle("Entry")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if model.isDirty {
                    Button("Save") {
                        if model.saveDrafts(now: now()) { onFinished() }
                    }
                    .accessibilityHint("Saves your change")
                }
            }
        }
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

    private var form: some View {
        Form {
            if let message = model.errorMessage {
                Section {
                    InlineNotice(message, tone: .failed)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(TokenColors.background)
            }
            header
            Section {
                Card {
                    VStack(alignment: .leading, spacing: DesignSpacing.m) {
                        ForEach(model.components) { component in
                            amountRow(component)
                        }
                        // Editing the meal is not part of this build, so the row states it and says so.
                        HStack {
                            Text("Meal").font(.body).foregroundStyle(TokenColors.textPrimary)
                            Spacer()
                            Text(model.mealText ?? "Not set")
                                .font(.body)
                                .foregroundStyle(TokenColors.textSecondary)
                            LaterBadge()
                        }
                        .accessibilityElement(children: .combine)
                        // Bounded to now: nobody has eaten anything in the future, and an entry's time is
                        // something to be corrected backwards. The picker reads the entry's own stored zone.
                        DatePicker("When", selection: $model.occurredAt, in: ...now())
                            .environment(\.timeZone, model.storedTimeZone)
                            .accessibilityLabel("When the entry was eaten")
                            .accessibilityHint("Corrects when this was eaten or drunk")
                        if model.isDirty {
                            DisclosureGroup("Add a note") {
                                TextField("Optional note", text: $model.changeReason)
                                    .font(.body)
                            }
                        }
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(TokenColors.background)
            }
            if !model.adds.isEmpty {
                Section("This entry adds") {
                    ForEach(model.adds) { row in
                        LabeledContent(row.name, value: row.amountText)
                            .font(.body)
                            .accessibilityLabel(row.name)
                            .accessibilityValue(row.amountText)
                    }
                }
            }
            if !model.allValues.isEmpty {
                Section {
                    DisclosureGroup("All \(model.allValues.count) values") {
                        ForEach(otherValues) { row in
                            LabeledContent(row.name, value: row.amountText)
                                .font(.footnote)
                                .accessibilityLabel(row.name)
                                .accessibilityValue(row.amountText)
                        }
                        // The compounds a captured panel printed, shown under their own heading.
                        if !model.additionalNutrients.isEmpty {
                            Text("Also on the label")
                                .font(.footnote)
                                .foregroundStyle(TokenColors.textSecondary)
                                .accessibilityLabel("Also on the label")
                            ForEach(model.additionalNutrients) { row in
                                LabeledContent(row.name, value: row.amountText)
                                    .font(.footnote)
                                    .accessibilityLabel(row.name)
                                    .accessibilityValue(row.amountText)
                            }
                        }
                    }
                }
            }
            Section("Where this came from") {
                HStack {
                    Text(model.sourceLine)
                        .font(.body)
                        .foregroundStyle(TokenColors.textPrimary)
                    Spacer()
                    LaterBadge()
                }
                .accessibilityElement(children: .combine)
                if model.isTypedEntry {
                    Button {} label: {
                        HStack {
                            Text("Add values from a label").font(.body)
                            Spacer()
                            LaterBadge()
                        }
                    }
                    .laterPlaceholder()
                }
            }
            Section("Sent to") {
                ForEach(model.destinations) { row in
                    VStack(alignment: .leading) {
                        HStack {
                            Image(systemName: row.iconName)
                                .foregroundStyle(TokenColors.accent)
                                .accessibilityHidden(true)
                            Text(row.sentToLabel).font(.body).foregroundStyle(TokenColors.textPrimary)
                            Spacer()
                            Text(row.sentToText).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(row.sentToLabel)
                        .accessibilityValue(row.sentToText)
                        if row.state == .needsAttention {
                            Button {} label: {
                                HStack {
                                    Text("Try again").font(.body)
                                    Spacer()
                                    LaterBadge()
                                }
                            }
                            .laterPlaceholder()
                        }
                    }
                }
            }
            if !model.changes.isEmpty {
                Section("Changes") {
                    ForEach(model.changes) { change in
                        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                            Text(change.verb).font(.headline).foregroundStyle(TokenColors.textPrimary)
                            Text(change.at, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                                .font(.footnote)
                                .foregroundStyle(TokenColors.textSecondary)
                            if let note = change.note {
                                Text(note).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Section {
                Button {
                    if model.repeatEntry(now: now()) != nil { onFinished() }
                } label: {
                    Text("Log again").font(.headline)
                }
                .accessibilityLabel("Log this entry again")
                .accessibilityHint("Adds a new entry with the same amounts at the current time")
                Button {} label: {
                    HStack {
                        Text("Favourite").font(.body)
                        Spacer()
                        LaterBadge()
                    }
                }
                .laterPlaceholder()
                .accessibilityValue("Not available yet")
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
    }

    /// The header: the product's name, its brand when it has one, and a chip for a drink or a supplement.
    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignSpacing.s) {
                Text(model.productName ?? model.components.first?.name ?? "Entry")
                    .font(.title)
                    .foregroundStyle(TokenColors.textPrimary)
                if let brand = model.brand {
                    Text(brand).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                }
                if let tag = KindTag(kind: model.kind) {
                    tag
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    /// One stored amount: the name, an editable field in the stored unit, the same amount in the reader's
    /// unit beneath it when there is one, and what is wrong with it when it cannot be saved.
    private func amountRow(_ component: EntryComponentRow) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
            Text(component.name).font(.headline).foregroundStyle(TokenColors.textPrimary)
            HStack {
                TextField("Amount", text: draftBinding(component.id))
                    .font(.body)
                    .entryAmountKeyboard()
                    .accessibilityLabel("Amount of \(component.name)")
                Text(component.unit.symbol).font(.body).foregroundStyle(TokenColors.textSecondary)
            }
            // The same amount in the unit the reader chose, shown beside the field that edits the stored one.
            // Saving writes the field back in the stored unit, so this line is a reading and never an edit.
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

    /// The label's values that are not already shown under "Also on the label", so no compound is listed twice.
    private var otherValues: [EntryNutrientRow] {
        model.allValues.filter { value in
            !model.additionalNutrients.contains { $0.key == value.key }
        }
    }

    private func draftBinding(_ id: String) -> Binding<String> {
        Binding(get: { model.drafts[id] ?? "" }, set: { model.drafts[id] = $0 })
    }
}

/// The keyboard is only set where the platform has one. This package also builds for macOS, where
/// `keyboardType` does not exist, so it stays behind this one door.
private extension View {
    @ViewBuilder
    func entryAmountKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}
