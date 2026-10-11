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
    public static let captchaMessage = "We could not confirm you are a person. Try again."
    public static let genericMessage = "Something went wrong. Try again."
    public static let profileNotReadyMessage = "Your profile has not loaded yet. Try again once it has."

    @Published public private(set) var phase: Phase = .signedOut
    /// Set by the Account section's buttons; the Settings form owns the sheet and the confirmation they open.
    @Published public var presentingSignIn = false
    @Published public var presentingDeleteConfirmation = false
    /// The email the account signed in with. Shown in Settings, never in a message.
    @Published public private(set) var email = ""
    /// The name as typed. `saveName(_:)` trims and caps it before it is stored.
    @Published public var displayName = ""
    /// Whether labels are shared. On unless the person has turned it off.
    @Published public private(set) var shareLabels = true
    /// True while any service call is running, including the restore that `load()` makes.
    @Published public private(set) var isBusy = false
    @Published public private(set) var message: String?
    @Published public private(set) var emailStep: EmailStep = .enterAddress
    /// True while the signed-in account has not read the sharing disclosure on this device.
    @Published public private(set) var needsDisclosure = false
    /// True only once the server's profile has been read. Until then the name and the sharing switch stay
    /// locked, so a failed read can never lead to a write that replaces the stored values with defaults.
    @Published public private(set) var profileReady = false

    private let service: CommunityAccountServicing
    private let preferences: CommunityDisclosurePreferences
    /// The name the server holds, so a change of the sharing switch sends the saved name, not the typed one.
    private var savedName: String?
    /// The address the code was sent to. Kept here so the code step needs no address from the view.
    private var pendingEmail = ""
    /// The ID of the signed-in account, from its session. Nil when nobody is signed in, and then no account has
    /// acknowledged the disclosure. Cleared on sign out and on delete.
    private var currentUserID: String?
    /// Counts running service calls. A counter, not a flag, so a call nested inside another does not clear
    /// the busy state while the outer call is still running.
    private var busyCount = 0 {
        didSet { isBusy = busyCount > 0 || isErasingLocalData }
    }
    /// Counts sign-ins that completed. `load()` compares it across the restore, so a sign-in that finished while
    /// the restore was running is never cleared by the restore's answer.
    private var signInCount = 0
    /// Invalidates every completion that began before local account erasure.
    private var sessionGeneration = 0
    private var isErasingLocalData = false

    public init(service: CommunityAccountServicing, preferences: CommunityDisclosurePreferences) {
        self.service = service
        self.preferences = preferences
    }

    /// Restores a stored sign-in when Settings opens. Signed out when nothing can be restored. The model is busy
    /// for the whole call, so the sign-in controls stay disabled until the restore has answered.
    public func load() async {
        guard !isErasingLocalData else { return }
        busyCount += 1
        defer { busyCount -= 1 }
        let generation = sessionGeneration
        let signInsBefore = signInCount
        guard let session = await service.restore() else {
            guard generation == sessionGeneration, !isErasingLocalData else { return }
            // A sign-in that completed during the restore is newer than its empty answer; keep it.
            if phase == .signedOut || signInCount == signInsBefore {
                clearSignedInState()
            }
            return
        }
        // Same reason: a sign-in that finished during the restore wins over the restored session.
        guard generation == sessionGeneration, !isErasingLocalData, signInCount == signInsBefore else { return }
        signIn(with: session)
        // A sign-in restored before the disclosure was read still has to show it.
        needsDisclosure = !currentAccountAcknowledged
        await refreshProfile()
    }

    /// True only for a signed-in person who has read the disclosure, has sharing on and whose profile has been
    /// read. Anything that sends a label must check this first: the server default for sharing is on, so the
    /// switch alone is not consent.
    public var sharingAllowed: Bool {
        phase == .signedIn && profileReady && shareLabels && currentAccountAcknowledged
    }

    public func signInWithApple(idToken: String, nonce: String) async {
        guard !isErasingLocalData else { return }
        let generation = sessionGeneration
        guard let session = await run(Self.signInFailedMessage, {
            try await self.service.signInWithApple(idToken: idToken, nonce: nonce)
        }) else { return }
        guard generation == sessionGeneration, !isErasingLocalData else { return }
        completeSignIn(session)
        await refreshProfile()
    }

    /// Called when Sign in with Apple ends without a usable identity token.
    public func reportAppleFailure() {
        guard !isErasingLocalData else { return }
        message = Self.signInFailedMessage
    }

    /// Emails a one-time code to the address. Nothing is sent when the address has no at sign.
    public func requestCode(email address: String) async {
        guard !isErasingLocalData else { return }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@") else {
            message = Self.addressMessage
            return
        }
        let generation = sessionGeneration
        guard await run(Self.codeRequestFailedMessage, {
            try await self.service.requestEmailCode(email: trimmed)
        }) != nil else { return }
        guard generation == sessionGeneration, !isErasingLocalData else { return }
        pendingEmail = trimmed
        emailStep = .enterCode
        message = Self.codeSentMessage
    }

    /// Emails a new code to the address the first code went to. Does nothing once the person has chosen a
    /// different address.
    public func resendCode() async {
        guard !isErasingLocalData else { return }
        let address = pendingEmail
        guard !address.isEmpty else { return }
        await requestCode(email: address)
    }

    /// Goes back to the address step, forgetting the address the code went to.
    public func useDifferentAddress() {
        guard !isBusy, !isErasingLocalData else { return }
        emailStep = .enterAddress
        pendingEmail = ""
        message = nil
    }

    /// Checks the code that was emailed to the address given to `requestCode(email:)`.
    public func verify(code: String) async {
        guard !isErasingLocalData else { return }
        let digits = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let sixDigits = digits.count == 6 && digits.allSatisfy({ $0.isASCII && $0.isNumber })
        guard sixDigits else {
            message = Self.codeFormatMessage
            return
        }
        guard emailStep == .enterCode else { return }
        let generation = sessionGeneration
        let address = pendingEmail
        guard let session = await run(Self.codeWrongMessage, {
            try await self.service.verifyEmailCode(email: address, code: digits)
        }) else { return }
        guard generation == sessionGeneration, !isErasingLocalData else { return }
        completeSignIn(session)
        await refreshProfile()
    }

    /// Turns sharing on or off. The switch shows the new value at once and goes back when the save fails.
    /// Nothing is sent until the profile has been read.
    public func setSharing(_ on: Bool) async {
        guard !isErasingLocalData else { return }
        await serialized { await self.applySharing(on) }
    }

    private func applySharing(_ on: Bool) async {
        guard !isErasingLocalData else { return }
        guard profileReady else {
            message = Self.profileNotReadyMessage
            return
        }
        let previous = shareLabels
        let generation = sessionGeneration
        let name = savedName
        shareLabels = on
        guard await run(Self.genericMessage, {
            try await self.service.updateProfile(displayName: name, shareLabels: on)
        }) != nil else {
            if generation == sessionGeneration, !isErasingLocalData { shareLabels = previous }
            return
        }
    }

    /// Saves the name: trimmed, capped at `nameLimit`, and empty means no name. Nothing is sent until the
    /// profile has been read.
    public func saveName(_ text: String) async {
        guard !isErasingLocalData else { return }
        await serialized { await self.applyName(text) }
    }

    private func applyName(_ text: String) async {
        guard !isErasingLocalData else { return }
        guard profileReady else {
            message = Self.profileNotReadyMessage
            return
        }
        let capped = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String? = capped.isEmpty ? nil : capped
        let sharing = shareLabels
        let generation = sessionGeneration
        guard let profile = await run(Self.genericMessage, {
            try await self.service.updateProfile(displayName: name, shareLabels: sharing)
        }) else { return }
        guard generation == sessionGeneration, !isErasingLocalData else { return }
        savedName = profile.displayName
        displayName = profile.displayName ?? ""
    }

    /// Reads the profile again after a failed read. Does nothing when nobody is signed in.
    public func retryProfile() async {
        guard !isErasingLocalData else { return }
        guard phase == .signedIn else { return }
        await refreshProfile()
    }

    public func signOut() async {
        guard !isErasingLocalData else { return }
        let generation = sessionGeneration
        guard await run(Self.genericMessage, { try await self.service.signOut() }) != nil else { return }
        guard generation == sessionGeneration, !isErasingLocalData else { return }
        clearSignedInState()
    }

    /// Deletes the account on the server. The session is forgotten here only after the server agrees.
    public func deleteAccount() async {
        guard !isErasingLocalData else { return }
        let generation = sessionGeneration
        guard await run(Self.genericMessage, { try await self.service.deleteAccount() }) != nil else { return }
        guard generation == sessionGeneration, !isErasingLocalData else { return }
        // The deleted account's own acknowledgment goes with it; the other accounts' entries stay.
        if let userID = currentUserID {
            preferences.setHasSeenCommunityDisclosure(false, for: userID)
        }
        clearSignedInState()
    }

    /// Clears this device's account presentation and stored session as part of Erase all data. It never
    /// signs out from or deletes anything on the server. The UI is cleared before the Keychain call can fail,
    /// and the generation makes every older service completion stale.
    public func discardLocalSession() async throws {
        guard !isErasingLocalData else { return }
        isErasingLocalData = true
        isBusy = true
        sessionGeneration += 1
        signInCount += 1
        clearSignedInState()
        defer {
            isErasingLocalData = false
            isBusy = busyCount > 0
        }
        try await service.discardLocalSession()
    }

    /// Called after Erase all data cleared the stored preferences: a signed-in person who has not read the
    /// disclosure on this device is asked again, and nothing is shared until they do.
    public func refreshAfterErase() {
        if phase == .signedIn {
            needsDisclosure = !currentAccountAcknowledged
        }
    }

    /// The signed-in person has read the sharing disclosure. Stored for this account, so it is not shown again
    /// for that account on this device. Ignored while a call is running, so a tap during a busy call is never
    /// taken for agreement, and ignored when nobody is signed in.
    public func acknowledgeDisclosure() {
        guard !isBusy, let userID = currentUserID else { return }
        preferences.setHasSeenCommunityDisclosure(true, for: userID)
        needsDisclosure = false
    }

    /// True when the signed-in account has read the disclosure. No signed-in account means no acknowledgment.
    private var currentAccountAcknowledged: Bool {
        guard let userID = currentUserID else { return false }
        return preferences.hasSeenCommunityDisclosure(for: userID)
    }

    // MARK: Helpers

    /// The tail of the profile writes. Every write sends the whole profile, so each waits for the one before it
    /// and then reads the current name and switch, which keeps an older response from undoing a newer change.
    private var writeTail: Task<Void, Never>?

    private func serialized(_ work: @escaping @MainActor () async -> Void) async {
        let previous = writeTail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        writeTail = task
        await task.value
    }

    /// Runs one service call with the busy flag set. A failure sets `message` and returns nil.
    private func run<T>(_ fallback: String, _ call: () async throws -> T) async -> T? {
        guard !isErasingLocalData else { return nil }
        let generation = sessionGeneration
        busyCount += 1
        defer { busyCount -= 1 }
        message = nil
        do {
            let result = try await call()
            guard generation == sessionGeneration, !isErasingLocalData else { return nil }
            return result
        } catch {
            guard generation == sessionGeneration, !isErasingLocalData else { return nil }
            let text = Self.message(for: error, fallback: fallback)
            // The sign-in ended (the session could not be renewed): stop showing the account.
            if phase == .signedIn, case .signedOut? = error as? CommunityError {
                clearSignedInState()
            }
            message = text
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
        case .captcha?: return captchaMessage
        default: return fallback
        }
    }

    private func completeSignIn(_ session: CommunitySession) {
        signInCount += 1
        signIn(with: session)
        emailStep = .enterAddress
        pendingEmail = ""
        needsDisclosure = !currentAccountAcknowledged
    }

    private func signIn(with session: CommunitySession) {
        phase = .signedIn
        currentUserID = session.userID
        email = session.email ?? ""
        profileReady = false
    }

    /// Reads the name and the sharing switch the server holds. Until this succeeds the profile is not ready, and
    /// a failure shows a message and keeps the defaults.
    private func refreshProfile() async {
        let generation = sessionGeneration
        guard !isErasingLocalData else { return }
        profileReady = false
        guard let profile = await run(Self.genericMessage, { try await self.service.profile() }) else { return }
        guard generation == sessionGeneration, !isErasingLocalData else { return }
        savedName = profile.displayName
        displayName = profile.displayName ?? ""
        shareLabels = profile.shareLabels
        profileReady = true
    }

    private func clearSignedInState() {
        presentingSignIn = false
        presentingDeleteConfirmation = false
        phase = .signedOut
        currentUserID = nil
        email = ""
        displayName = ""
        savedName = nil
        shareLabels = true
        emailStep = .enterAddress
        pendingEmail = ""
        needsDisclosure = false
        profileReady = false
        message = nil
    }
}
