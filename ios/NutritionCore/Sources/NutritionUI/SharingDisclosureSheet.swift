import SwiftUI

/// The first-run disclosure, shown once after the first sign-in on a device. It says what is shared before
/// the sharing switch is left on.
public struct SharingDisclosureSheet: View {
    @ObservedObject var model: AccountViewModel
    @Environment(\.dismiss) private var dismiss

    public init(model: AccountViewModel) {
        self.model = model
    }

    static let disclosure = "Product facts you choose to share include the name, brand, barcode, serving definition and nutrient or ingredient amounts. "
        + "A contribution can be visible immediately as Shared, not yet verified. Agreement from distinct accounts and review determine verification. "
        + "Photos, consumed amounts, intake times, meals, journal entries, notes and goals are never shared. "
        + "Turning sharing off stops future publications; it does not remove earlier contributions. Use Remove my contribution for each product you want to withdraw. "
        + "Continuing acknowledges version 2 of this disclosure and does not change your sharing switch."

    public var body: some View {
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
                    .disabled(!model.profileReady || model.isBusy)
                }
                Section {
                    Button("Continue") {
                        Task {
                            await model.acknowledgeProductDisclosure()
                            if !model.needsDisclosure { self.dismiss() }
                        }
                    }
                    .disabled(model.isBusy)
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
