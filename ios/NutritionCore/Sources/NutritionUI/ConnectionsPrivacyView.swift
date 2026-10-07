import SwiftUI
import UniformTypeIdentifiers

/// The Connections and privacy screen: a plain statement of what stays on the device, the export and
/// import actions the person starts, and the two connections that are named but not yet usable.
public struct ConnectionsPrivacyView: View {
    @ObservedObject var model: ConnectionsPrivacyViewModel
    private let now: () -> Date
    /// Held here rather than in the model so the file picker is a view concern: the model never sees a
    /// file, only the bytes the person chose.
    @State private var isImporting = false
    /// Held so the erase button asks first, and the ask is a dialog with the erase action and a cancel
    /// side by side.
    @State private var confirmingErase = false

    public init(model: ConnectionsPrivacyViewModel, now: @escaping () -> Date = { Date() }) {
        self.model = model
        self.now = now
    }

    public var body: some View {
        Form {
            Section("Your data") {
                Text(model.privacyText)
                    .font(.body)
                    .foregroundStyle(TokenColors.textPrimary)
                    .accessibilityLabel("Privacy: \(model.privacyText)")
            }
            Section("Export") {
                Button {
                    model.export(now: now())
                } label: {
                    Text(ConnectionsPrivacyViewModel.exportButtonTitle).font(.headline)
                }
                .disabled(!model.canExport)
                .accessibilityLabel("Export journal as JSON")
                .accessibilityHint(
                    "Writes a copy of the journal to a file on this device. Nothing is sent until you share it.")
                if let url = model.exportFileURL {
                    ShareLink(item: url) {
                        Text(ConnectionsPrivacyViewModel.shareButtonTitle).font(.headline)
                    }
                    .accessibilityLabel("Share the exported journal file")
                    .accessibilityHint("Opens the system share sheet so you can choose where the file goes")
                    Text("Exported \(model.entryCount) entries.")
                        .font(.footnote)
                        .foregroundStyle(TokenColors.textSecondary)
                        .accessibilityLabel("Exported \(model.entryCount) entries")
                }
            }
            Section("Import") {
                Button {
                    isImporting = true
                } label: {
                    Text(ConnectionsPrivacyViewModel.importButtonTitle).font(.headline)
                }
                .accessibilityLabel("Import a journal export from a file")
                .accessibilityHint(
                    "Restores a journal export you already made. It only works while this phone's journal is empty.")
                if let message = model.importMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(
                            model.importState == .failed ? TokenColors.error : TokenColors.textSecondary)
                        .accessibilityLabel(message)
                }
            }
            Section(ConnectionsPrivacyViewModel.unitsSectionTitle) {
                Picker(ConnectionsPrivacyViewModel.unitSystemTitle, selection: $model.unitSystem) {
                    ForEach(model.unitSystems, id: \.self) { system in
                        Text(ConnectionsPrivacyViewModel.label(for: system)).tag(system)
                    }
                }
                .font(.body)
                .accessibilityLabel(ConnectionsPrivacyViewModel.unitSystemTitle)
                TextField(ConnectionsPrivacyViewModel.quickWaterFieldLabel, text: $model.quickWaterText)
                    .font(.body)
                    .accessibilityLabel(ConnectionsPrivacyViewModel.quickWaterFieldLabel)
                    .accessibilityHint(
                        "How much the Add water button on Today adds. It must be above zero.")
                    .onSubmit { model.saveQuickWaterAmount() }
                Text("Shown as \(model.quickWaterDisplay.text) on Today.")
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
                    .accessibilityLabel("Quick-add water is shown as \(model.quickWaterDisplay.text)")
                if let message = model.quickWaterError {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.error)
                        .accessibilityLabel(message)
                }
                Button("Save water amount") {
                    model.saveQuickWaterAmount()
                }
                .font(.body)
                .accessibilityLabel("Save the quick-add water amount")
                .accessibilityHint("Checks the amount and uses it for the Add water button on Today")
            }
            Section("Connections") {
                Toggle(isOn: $model.appleHealthEnabled) {
                    connectionRow(
                        title: ConnectionsPrivacyViewModel.appleHealthTitle,
                        detail: "Write entries to the Health app on this phone.")
                }
                .disabled(true)
                .accessibilityLabel(ConnectionsPrivacyViewModel.appleHealthTitle)
                .accessibilityValue("Not available yet")
                .accessibilityHint(ConnectionsPrivacyViewModel.arrivingNote)
                Toggle(isOn: $model.healthRelayEnabled) {
                    connectionRow(
                        title: ConnectionsPrivacyViewModel.healthRelayTitle,
                        detail: "Send entries to your own relay service.")
                }
                .disabled(true)
                .accessibilityLabel(ConnectionsPrivacyViewModel.healthRelayTitle)
                .accessibilityValue("Not available yet")
                .accessibilityHint(ConnectionsPrivacyViewModel.arrivingNote)
                Text(ConnectionsPrivacyViewModel.arrivingNote)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
            }
            if model.canEraseAll {
                Section {
                    Button(role: .destructive) {
                        confirmingErase = true
                    } label: {
                        Text(ConnectionsPrivacyViewModel.eraseButtonTitle).font(.headline)
                    }
                    .accessibilityLabel(ConnectionsPrivacyViewModel.eraseButtonTitle)
                    .accessibilityHint("Asks first. Deletes every entry, favorite and recipe on this device")
                } footer: {
                    Text(ConnectionsPrivacyViewModel.eraseFooterMessage)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.textSecondary)
                }
            }
            // One place for a message, so an erase that could not finish reads the same wherever on the
            // screen it happened.
            if let message = model.errorMessage {
                Section {
                    Text(message).font(.footnote).foregroundStyle(TokenColors.error)
                }
            }
        }
        .confirmationDialog(
            ConnectionsPrivacyViewModel.eraseConfirmationTitle, isPresented: $confirmingErase,
            titleVisibility: .visible
        ) {
            Button(ConnectionsPrivacyViewModel.eraseButtonTitle, role: .destructive) {
                model.eraseAllData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ConnectionsPrivacyViewModel.eraseConfirmationMessage)
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .fileImporter(
            isPresented: $isImporting, allowedContentTypes: [.json], allowsMultipleSelection: false
        ) { result in
            importPickedFile(result)
        }
        .navigationTitle("Connections and privacy")
        .onDisappear {
            // Leaving the screen deletes the exported copy. A journal export that outlives the screen would
            // sit in the temporary directory with nothing able to remove it.
            model.clearExport()
            model.clearImport()
        }
    }

    /// Reads the file the person chose and hands the bytes to the model. A picker that was cancelled goes
    /// back to the screen's empty import state; a file that cannot be read is a failed import, because the
    /// person asked for it and nothing happened. Either way no rows were written.
    private func importPickedFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            model.clearImport()
            return
        }
        // A file the person picked in another app is outside this app's own directory until access to it
        // is claimed, and the claim has to be given up again afterwards.
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer { if isSecurityScoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            model.importCouldNotReadFile()
            return
        }
        model.importJournal(data: data)
    }

    private func connectionRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline).foregroundStyle(TokenColors.textPrimary)
            Text(detail).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
        }
    }
}