import SwiftUI

/// The first-run disclosure, shown once after the first sign-in on a device. It says what is shared before
/// the sharing switch is left on.
struct SharingDisclosureSheet: View {
    @ObservedObject var model: AccountViewModel
    @Environment(\.dismiss) private var dismiss

    static let disclosure = "Scanned labels help everyone. When you scan a nutrition label, the label's values "
        + "(product name, brand, barcode and nutrient amounts) are shared with the community catalog. "
        + "Photos, what you eat and when are never shared. A label is shown to others once at least two people "
        + "agree on it, and gets a verified badge once more people agree. You can turn this off at any time in Settings."

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(Self.disclosure)
                        .font(.body)
                        .foregroundStyle(TokenColors.textPrimary)
                }
                Section {
                    Toggle("Share labels with the community", isOn: Binding(
                        get: { model.shareLabels },
                        set: { on in Task { await model.setSharing(on) } }
                    ))
                    .disabled(model.isBusy)
                }
                Section {
                    Button("Continue") {
                        model.acknowledgeDisclosure()
                        self.dismiss()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(TokenColors.background)
            .tint(TokenColors.accent)
            // Only the Continue button counts as reading it: a swipe down must not be taken for agreement.
            .interactiveDismissDisabled()
            .navigationTitle("Sharing labels")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}
