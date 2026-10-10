import SwiftUI
import CryptoKit
#if os(iOS)
import AuthenticationServices
#endif

/// Sign in with Apple, or an email address and a one-time code. It closes itself once the person is signed in.
struct SignInSheet: View {
    @ObservedObject var model: AccountViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""
    /// The raw nonce for the Apple request in flight. Its SHA-256 goes to Apple; the raw value goes to the service.
    @State private var appleNonce = ""

    var body: some View {
        NavigationStack {
            Form {
                #if os(iOS)
                Section {
                    SignInWithAppleButton(.signIn) { request in
                        appleNonce = AppleNonce.make()
                        request.nonce = AppleNonce.hash(appleNonce)
                    } onCompletion: { result in
                        handleApple(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 50)
                    .disabled(model.isBusy)
                }
                #endif
                Section {
                    if model.emailStep == .enterAddress {
                        TextField("Email address", text: $address)
                            #if os(iOS)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                        Button("Send code") {
                            Task { await model.requestCode(email: address) }
                        }
                        .disabled(model.isBusy)
                    } else {
                        TextField("Six-digit code", text: $code)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            #endif
                            .autocorrectionDisabled()
                        Button("Sign in with code") {
                            Task { await model.verify(code: code) }
                        }
                        .disabled(model.isBusy)
                    }
                } header: {
                    Text("Email")
                } footer: {
                    Text("We email a six-digit code to this address. Nothing is sent until you ask for one.")
                        .font(.footnote)
                }
                if let message = model.message {
                    InlineNotice(message, tone: message == AccountViewModel.codeSentMessage ? .waiting : .failed)
                }
            }
            .scrollContentBackground(.hidden)
            .background(TokenColors.background)
            .tint(TokenColors.accent)
            .navigationTitle("Sign in")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { self.dismiss() }
                }
            }
            .onChange(of: model.phase) { _, phase in
                if phase == .signedIn { self.dismiss() }
            }
        }
    }

    #if os(iOS)
    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled { return }
            model.reportAppleFailure()
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken,
                  let token = String(data: data, encoding: .utf8)
            else {
                model.reportAppleFailure()
                return
            }
            let nonce = appleNonce
            Task { await model.signInWithApple(idToken: token, nonce: nonce) }
        }
    }
    #endif
}

/// Nonces for Sign in with Apple: 32 random bytes as hex, and their SHA-256 as hex for the request.
enum AppleNonce {
    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32)
            .map { _ in String(format: "%02x", UInt8.random(in: UInt8.min...UInt8.max, using: &generator)) }
            .joined()
    }

    static func hash(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
