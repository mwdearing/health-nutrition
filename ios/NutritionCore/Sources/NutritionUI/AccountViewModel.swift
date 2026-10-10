import Foundation
import NutritionProviders

/// Drives the Account section of Settings and the sign-in sheet. It holds presentation state only: every
/// call goes through the service, and no message ever repeats a token, a code or an address.
@MainActor
public final class AccountViewModel: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case signedOut
        case signedIn
    }

    public enum EmailStep: Equatable, Sendable {
        case enterAddress
        case enterCode
    }

    /// The longest display name, in characters.
    public static let nameLimit = 60

    public static let signInFailedMessage = "Could not sign in. Check your connection and try again."
    public static let codeRequestFailedMessage = "Could not send a code. Check the address and try again."
    public static let codeSentMessage = "Check your email for a six-digit code."
    public static let codeWrongMessage = "That code is not right or has expired. Check it, or ask for a new code."
    public static let codeFormatMessage = "Enter the six-digit code from your email."
    public static let addressMessage = "Enter the email address you want to sign in with."
    public static let networkMessage = "Could not reach the server. Check your connection and try again."
    public static let sessionEndedMessage = "Your sign-in has ended. Sign in again to continue."
    public static let rateLimitedMessage = "Too many attempts. Wait a few minutes and try again."
    public static let storageMessage = "Could not keep your sign-in on this phone. Try again."
    public static let genericMessage = "Something went wrong. Try again."

    @Published public private(set) var phase: Phase = .signedOut
    /// The email the account signed in with. Shown in Settings, never in a message.
    @Published public private(set) var email = ""
    /// The name as typed. `saveName(_:)` trims and caps it before it is stored.
    @Published public var displayName = ""
    /// Whether labels are shared. On unless the person has turned it off.
    @Published public private(set) var shareLabels = true
    @Published public private(set) var isBusy = false
    @Published public private(set) var message: String?
    @Published public private(set) var emailStep: EmailStep = .enterAddress
    /// True after the first sign-in on this device, until the person has read the sharing disclosure.
    @Published public private(set) var needsDisclosure = false

    private let service: CommunityAccountServicing
    private let preferences: CommunityDisclosurePreferences
    /// The name the server holds, so a change of the sharing switch sends the saved name, not the typed one.
    private var savedName: String?
    /// The address the code was sent to. Kept here so the code step needs no address from the view.
    private var pendingEmail = ""

    public init(service: CommunityAccountServicing, preferences: CommunityDisclosurePreferences) {
        self.service = service
        self.preferences = preferences
    }

    /// Restores a stored sign-in when Settings opens. Signed out when nothing can be restored.
    public func load() async {
        guard let session = await service.restore() else {
            clearSignedInState()
            return
        }
        signIn(with: session)
        // A sign-in restored before the disclosure was read still has to show it.
        if !preferences.hasSeenCommunityDisclosure {
            needsDisclosure = true
        }
        await refreshProfile()
    }

    /// True only for a signed-in person who has read the disclosure and has sharing on. Anything that sends a
    /// label must check this first: the server default for sharing is on, so the switch alone is not consent.
    public var sharingAllowed: Bool {
        phase == .signedIn && shareLabels && preferences.hasSeenCommunityDisclosure
    }

    public func signInWithApple(idToken: String, nonce: String) async {
        guard let session = await run(Self.signInFailedMessage, {
            try await self.service.signInWithApple(idToken: idToken, nonce: nonce)
        }) else { return }
        completeSignIn(session)
        await refreshProfile()
    }

    /// Called when Sign in with Apple ends without a usable identity token.
    public func reportAppleFailure() {
        message = Self.signInFailedMessage
    }

    /// Emails a one-time code to the address. Nothing is sent when the address has no at sign.
    public func requestCode(email address: String) async {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@") else {
            message = Self.addressMessage
            return
        }
        guard await run(Self.codeRequestFailedMessage, {
            try await self.service.requestEmailCode(email: trimmed)
        }) != nil else { return }
        pendingEmail = trimmed
        emailStep = .enterCode
        message = Self.codeSentMessage
    }

    /// Checks the code that was emailed to the address given to `requestCode(email:)`.
    public func verify(code: String) async {
        let digits = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digits.count == 6, digits.allSatisfy { $0.isASCII && $0.isNumber } else {
            message = Self.codeFormatMessage
            return
        }
        guard emailStep == .enterCode else { return }
        let address = pendingEmail
        guard let session = await run(Self.codeWrongMessage, {
            try await self.service.verifyEmailCode(email: address, code: digits)
        }) else { return }
        completeSignIn(session)
        await refreshProfile()
    }

    /// Turns sharing on or off. The switch shows the new value at once and goes back when the save fails.
    public func setSharing(_ on: Bool) async {
        let previous = shareLabels
        let name = savedName
        shareLabels = on
        guard await run(Self.genericMessage, {
            try await self.service.updateProfile(displayName: name, shareLabels: on)
        }) != nil else {
            shareLabels = previous
            return
        }
    }

    /// Saves the name: trimmed, capped at `nameLimit`, and empty means no name.
    public func saveName(_ text: String) async {
        let capped = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String? = capped.isEmpty ? nil : capped
        let sharing = shareLabels
        guard let profile = await run(Self.genericMessage, {
            try await self.service.updateProfile(displayName: name, shareLabels: sharing)
        }) else { return }
        savedName = profile.displayName
        displayName = profile.displayName ?? ""
    }

    public func signOut() async {
        await service.signOut()
        clearSignedInState()
    }

    /// Deletes the account on the server. The session is forgotten here only after the server agrees.
    public func deleteAccount() async {
        guard await run(Self.genericMessage, { try await self.service.deleteAccount() }) != nil else { return }
        clearSignedInState()
    }

    /// The person has read the sharing disclosure. Stored, so it is not shown again on this device.
    public func acknowledgeDisclosure() {
        preferences.setHasSeenCommunityDisclosure(true)
        needsDisclosure = false
    }

    // MARK: Helpers

    /// Runs one service call with the busy flag set. A failure sets `message` and returns nil.
    private func run<T>(_ fallback: String, _ call: () async throws -> T) async -> T? {
        isBusy = true
        defer { isBusy = false }
        message = nil
        do {
            return try await call()
        } catch {
            message = Self.message(for: error, fallback: fallback)
            return nil
        }
    }

    /// The text for a failure. Only fixed sentences are ever shown, so nothing from the error itself reaches
    /// the screen; the fallback covers every other case.
    private static func message(for error: Error, fallback: String) -> String {
        switch error as? CommunityError {
        case .network?: return networkMessage
        case .signedOut?: return sessionEndedMessage
        case .rateLimited?: return rateLimitedMessage
        case .storage?: return storageMessage
        default: return fallback
        }
    }

    private func completeSignIn(_ session: CommunitySession) {
        signIn(with: session)
        emailStep = .enterAddress
        pendingEmail = ""
        if !preferences.hasSeenCommunityDisclosure {
            needsDisclosure = true
        }
    }

    private func signIn(with session: CommunitySession) {
        phase = .signedIn
        email = session.email ?? ""
    }

    /// Reads the name and the sharing switch the server holds. A failure shows a message and keeps the defaults.
    private func refreshProfile() async {
        guard let profile = await run(Self.genericMessage, { try await self.service.profile() }) else { return }
        savedName = profile.displayName
        displayName = profile.displayName ?? ""
        shareLabels = profile.shareLabels
    }

    private func clearSignedInState() {
        phase = .signedOut
        email = ""
        displayName = ""
        savedName = nil
        shareLabels = true
        emailStep = .enterAddress
        pendingEmail = ""
        needsDisclosure = false
        message = nil
    }
}
