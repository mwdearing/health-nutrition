import SwiftUI

/// The Account section of Settings. It is shown only where the model exists, which needs the project settings
/// (see `AppSettingsViewModel.account`). Signed out, it offers sign-in. Signed in, it shows the name, the
/// sharing switch, sign out and delete.
struct AccountSectionView: View {
    @ObservedObject var model: AccountViewModel
    @State private var showingSignIn = false
    @State private var showingDisclosure = false
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        Section {
            if model.phase == .signedOut {
                Button("Sign in") { showingSignIn = true }
                    .disabled(model.isBusy)
            } else {
                TextField("Name", text: $model.displayName)
                    .focused($nameFocused)
                    .onSubmit { saveName() }
                    .accessibilityHint("Shown with the labels you share. Up to \(AccountViewModel.nameLimit) characters.")
                LabeledContent("Email", value: model.email)
                Toggle("Share labels with the community", isOn: Binding(
                    get: { model.shareLabels },
                    set: { on in Task { await model.setSharing(on) } }
                ))
                .disabled(model.isBusy)
                Button("Sign out") { Task { await model.signOut() } }
                    .disabled(model.isBusy)
                Button("Delete account", role: .destructive) { confirmingDelete = true }
                    .disabled(model.isBusy)
            }
            if let message = model.message {
                InlineNotice(message, tone: message == AccountViewModel.codeSentMessage ? .waiting : .failed)
            }
        } header: {
            Text("Account")
        } footer: {
            Text(model.phase == .signedOut
                ? "Without an account, everything stays on this device. Signing in backs up your data to your iCloud and lets you share scanned labels."
                : "Turning sharing off stops new labels from being shared. Deleting the account removes it and every label it shared; data on this device is kept.")
                .font(.footnote)
        }
        .onChange(of: nameFocused) { _, focused in
            if !focused { saveName() }
        }
        .sheet(isPresented: $showingSignIn, onDismiss: {
            // Read after the sign-in sheet has gone away, so the two sheets are never up together.
            showingDisclosure = model.needsDisclosure
        }) {
            SignInSheet(model: model)
        }
        .sheet(isPresented: $showingDisclosure, onDismiss: {
            model.acknowledgeDisclosure()
        }) {
            SharingDisclosureSheet(model: model)
        }
        .confirmationDialog(
            "Delete your account?", isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) { Task { await model.deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The account and every label it shared are deleted. Data on this device is kept.")
        }
        .task { await model.load() }
    }

    private func saveName() {
        let text = model.displayName
        Task { await model.saveName(text) }
    }
}
