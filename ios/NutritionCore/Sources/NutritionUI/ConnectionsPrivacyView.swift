import SwiftUI

/// Full privacy statement reached from Settings; data actions live in Settings itself.
public struct ConnectionsPrivacyView: View {
    @ObservedObject var model: ConnectionsPrivacyViewModel

    public init(model: ConnectionsPrivacyViewModel, now: @escaping () -> Date = { Date() }) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section("Privacy") {
                Text(model.privacyText)
                    .font(.body)
                    .foregroundStyle(TokenColors.textPrimary)
                    .accessibilityLabel("Privacy: \(model.privacyText)")
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Privacy")
    }
}
