import SwiftUI

/// The first-run disclosure, shown once after the first sign-in on a device. It says what is shared before
/// the sharing switch is left on.
public struct SharingDisclosureSheet: View {
    @ObservedObject var model: AccountViewModel
    @Environment(\.dismiss) private var dismiss

    public init(model: AccountViewModel) {
        self.model = model
    }

    static let disclosure = "Sharing includes manually created foods, drinks and supplements, with or without a barcode. Product facts include the name, brand, optional barcode, serving definition and nutrient or ingredient amounts. "
        + "A contribution can be visible immediately as Shared, not yet verified. Agreement is support only. Only catalog-owner review of the exact facts verifies a product. New products saved while signed in with sharing enabled and this disclosure acknowledged are automatically queued to share, including when offline. Imports, edits and older local products are shared only after a separate deliberate review. "
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
                    Toggle("Share products with the community", isOn: Binding(
                        get: { model.shareLabels },
                        set: { on in Task { await model.setSharing(on) } }
                    ))
                    .disabled(!model.profileReady || model.isBusy)
                }
                if let message = model.message {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(TokenColors.textPrimary)
                    }
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
            .navigationTitle("Sharing products")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}
