import SwiftUI

/// The Connections and privacy screen: a plain statement of what stays on the device, an export action the
/// person starts, and the two connections that are named but not yet usable.
public struct ConnectionsPrivacyView: View {
    @ObservedObject var model: ConnectionsPrivacyViewModel
    private let now: () -> Date

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
                if let message = model.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(TokenColors.error)
                }
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
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Connections and privacy")
        .onDisappear {
            // Leaving the screen deletes the exported copy. A journal export that outlives the screen would
            // sit in the temporary directory with nothing able to remove it.
            model.clearExport()
        }
    }

    private func connectionRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline).foregroundStyle(TokenColors.textPrimary)
            Text(detail).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
        }
    }
}