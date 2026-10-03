import SwiftUI

public struct AddIntakeView: View {
    @ObservedObject var model: AddIntakeViewModel
    private let now: () -> Date
    private let onSaved: () -> Void
    private let onFromLibrary: (() -> Void)?

    public init(
        model: AddIntakeViewModel, now: @escaping () -> Date = { Date() }, onSaved: @escaping () -> Void,
        onFromLibrary: (() -> Void)? = nil
    ) {
        self.model = model
        self.now = now
        self.onSaved = onSaved
        self.onFromLibrary = onFromLibrary
    }

    public var body: some View {
        Form {
            if let onFromLibrary {
                Button {
                    onFromLibrary()
                } label: {
                    Text("From library").font(.headline)
                }
                .accessibilityLabel("Add from library")
                .accessibilityHint("Shows favorites and recent items")
            }
            Section("Food or drink") {
                TextField("Name", text: $model.name)
                    .font(.body)
                if let message = model.nameError {
                    Text(message).font(.footnote).foregroundStyle(TokenColors.error)
                }
                TextField("Amount", text: $model.amountText)
                    .font(.body)
                if let message = model.amountError {
                    Text(message).font(.footnote).foregroundStyle(TokenColors.error)
                }
                Picker("Unit", selection: $model.unit) {
                    ForEach(model.units, id: \.symbol) { unit in
                        Text(unit.symbol).tag(unit)
                    }
                }
                DatePicker("When", selection: $model.occurredAt)
            }
            if let message = model.saveError {
                Text(message).font(.footnote).foregroundStyle(TokenColors.error)
            }
            Button {
                if model.save(now: now()) { onSaved() }
            } label: {
                Text("Save").font(.headline)
            }
            .accessibilityLabel("Save intake")
            .accessibilityHint("Checks the amount and adds the entry to the journal")
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Add intake")
    }
}
