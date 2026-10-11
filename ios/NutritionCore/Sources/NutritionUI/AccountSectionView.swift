import SwiftUI

/// The Account section of Settings. It is shown only where the model exists, which needs the project settings
/// (see `AppSettingsViewModel.account`). Signed out, it offers sign-in. Signed in, it shows the name, the
/// sharing switch, sign out and delete.
public struct AccountSectionView: View {
    @ObservedObject var model: AccountViewModel
    @FocusState private var nameFocused: Bool

    public init(model: AccountViewModel) {
        self.model = model
    }

    public var body: some View {
        Section {
            if model.phase == .signedOut {
                Button("Sign in") { model.presentingSignIn = true }
                    .disabled(model.isBusy)
            } else {
                TextField("Name", text: $model.displayName)
                    .focused($nameFocused)
                    .onSubmit { saveName() }
                    .disabled(!model.profileReady || model.isBusy)
                    .accessibilityHint("Shown with the labels you share. Up to \(AccountViewModel.nameLimit) characters.")
                LabeledContent("Email", value: model.email)
                Toggle("Share labels with the community", isOn: Binding(
                    get: { model.shareLabels },
                    set: { on in Task { await model.setSharing(on) } }
                ))
                .disabled(!model.profileReady || model.isBusy)
                if !model.profileReady {
                    // The name and the switch stay locked until the profile has been read, so a failed read
                    // cannot lead to a save that replaces the stored values.
                    Button("Try again") { Task { await model.retryProfile() } }
                        .disabled(model.isBusy)
                }
                Button("Sign out") { Task { await model.signOut() } }
                    .disabled(model.isBusy)
                Button("Delete account", role: .destructive) { model.presentingDeleteConfirmation = true }
                    .disabled(model.isBusy)
            }
            if let message = model.message {
                InlineNotice(message, tone: message == AccountViewModel.codeSentMessage ? .waiting : .failed)
            }
        } header: {
            Text("Account")
        } footer: {
            Text(model.phase == .signedOut
                ? "Without an account, everything stays on this device. Signing in lets you share scanned labels with the community."
                : "Turning sharing off stops new labels from being shared. Deleting the account removes it and every label it shared; data on this device is kept.")
                .font(.footnote)
        }
        .onChange(of: nameFocused) { _, focused in
            if !focused { saveName() }
        }
    }

    private func saveName() {
        let text = model.displayName
        Task { await model.saveName(text) }
    }
}

/// The sheets and the delete confirmation of the Account section. They are attached to the Settings form
/// itself, not to the Section: a presentation anchored to one lazily managed row is dropped when that row is
/// rebuilt (for example when the busy state flips), which took the sign-in sheet down with it. The Section's
/// buttons only set `presentingSignIn` and `presentingDeleteConfirmation` on the model.
struct AccountPresentations: ViewModifier {
    @ObservedObject var model: AccountViewModel
    @State private var showingDisclosure = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.presentingSignIn, onDismiss: {
                // Read after the sign-in sheet has gone away, so the two sheets are never up together.
                showingDisclosure = model.needsDisclosure
            }) {
                SignInSheet(model: model)
            }
            .sheet(isPresented: $showingDisclosure) {
                SharingDisclosureSheet(model: model)
            }
            .confirmationDialog(
                "Delete your account?", isPresented: $model.presentingDeleteConfirmation, titleVisibility: .visible
            ) {
                Button("Delete account", role: .destructive) { Task { await model.deleteAccount() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The account and every label it shared are deleted. Data on this device is kept.")
            }
            .onChange(of: model.needsDisclosure) { _, needed in
                if needed && !model.presentingSignIn { showingDisclosure = true }
            }
            .onAppear {
                showingDisclosure = model.needsDisclosure && !model.presentingSignIn
            }
            // Brings the stored sign-in back when Settings opens, if the launch restore could not.
            .task {
                await model.load()
                showingDisclosure = model.needsDisclosure && !model.presentingSignIn
            }
    }
}

extension View {
    /// Attaches the Account section's sheets and confirmation to this view (the Settings form).
    @ViewBuilder
    func accountPresentations(_ model: AccountViewModel?) -> some View {
        if let model {
            modifier(AccountPresentations(model: model))
        } else {
            self
        }
    }
}
