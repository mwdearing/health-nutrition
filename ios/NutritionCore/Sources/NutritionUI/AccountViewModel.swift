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

    @Published public private(set) var productDeliveryPausedAfterDeletion = false
    private let productService: (any CommunityProductServicing)?
    private let productSharing: ProductShareCoordinator?
    private var productCapabilities: ProductCatalogCapabilities?
    private var accountIdentity = UUID()
    /// An explicit sign-out bars automatic restore until a later deliberate sign-in succeeds.
    private var automaticRestoreClosed = false
    /// Logout clears stored credentials after its await; no new authentication may start until it finishes.
    private var signOutInProgress = false

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
        didSet { isBusy = busyCount > 0 }
    }
    /// Counts sign-ins that completed. `load()` compares it across the restore, so a sign-in that finished while
    /// the restore was running is never cleared by the restore's answer.
    private var signInCount = 0

    public init(service: CommunityAccountServicing, preferences: CommunityDisclosurePreferences,
                productService: (any CommunityProductServicing)? = nil, productSharing: ProductShareCoordinator? = nil) {
        self.productService = productService
        self.productSharing = productSharing
        self.service = service
        self.preferences = preferences
    }

    /// Restores a stored sign-in when Settings opens. Signed out when nothing can be restored. The model is busy
    /// for the whole call, so the sign-in controls stay disabled until the restore has answered.
    public func load() async {
        guard !automaticRestoreClosed else { return }
        busyCount += 1
        defer { busyCount -= 1 }
        let signInsBefore = signInCount
        let identity = accountIdentity
        let restored = await service.restore()
        guard identity == accountIdentity else { return }
        guard let session = restored else {
            // A sign-in that completed during the restore is newer than its empty answer; keep it.
            if phase == .signedOut || signInCount == signInsBefore {
                clearSignedInState()
            }
            return
        }
        // Same reason: a sign-in that finished during the restore wins over the restored session.
        guard signInCount == signInsBefore else { return }
        signIn(with: session)
        // A sign-in restored before the disclosure was read still has to show it.
        needsDisclosure = !currentAccountAcknowledged
        await refreshProfile()
    }

    /// True only for a signed-in person who has read the disclosure, has sharing on and whose profile has been
    /// read. Anything that sends a label must check this first: the server default for sharing is on, so the
    /// switch alone is not consent.
    public var sharingAllowed: Bool {
        phase == .signedIn && profileReady && shareLabels && currentAccountAcknowledged && !productDeliveryPausedAfterDeletion
    }

    public func signInWithApple(idToken: String, nonce: String) async {
        guard !signOutInProgress else { return }
        let identity = accountIdentity
        guard let session = await run(Self.signInFailedMessage, {
            try await self.service.signInWithApple(idToken: idToken, nonce: nonce)
        }), accountIdentity == identity else { return }
        completeSignIn(session)
        await refreshProfile()
    }

    /// Called when Sign in with Apple ends without a usable identity token.
    public func reportAppleFailure() {
        message = Self.signInFailedMessage
    }

    /// Emails a one-time code to the address. Nothing is sent when the address has no at sign.
    public func requestCode(email address: String) async {
        guard !signOutInProgress else { return }
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

    /// Emails a new code to the address the first code went to. Does nothing once the person has chosen a
    /// different address.
    public func resendCode() async {
        let address = pendingEmail
        guard !address.isEmpty else { return }
        await requestCode(email: address)
    }

    /// Goes back to the address step, forgetting the address the code went to.
    public func useDifferentAddress() {
        guard !isBusy else { return }
        emailStep = .enterAddress
        pendingEmail = ""
        message = nil
    }

    /// Checks the code that was emailed to the address given to `requestCode(email:)`.
    public func verify(code: String) async {
        guard !signOutInProgress else { return }
        let digits = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let sixDigits = digits.count == 6 && digits.allSatisfy({ $0.isASCII && $0.isNumber })
        guard sixDigits else {
            message = Self.codeFormatMessage
            return
        }
        guard emailStep == .enterCode else { return }
        let address = pendingEmail
        let identity = accountIdentity
        guard let session = await run(Self.codeWrongMessage, {
            try await self.service.verifyEmailCode(email: address, code: digits)
        }), accountIdentity == identity else { return }
        completeSignIn(session)
        await refreshProfile()
    }

    /// Turns sharing on or off. The switch shows the new value at once and goes back when the save fails.
    /// Nothing is sent until the profile has been read.
    public func setSharing(_ on: Bool) async {
        if !on { productSharing?.closeGate(reason: .sharingDisabled) }
        await serialized { await self.applySharing(on) }
    }

    private func applySharing(_ on: Bool) async {
        guard profileReady else {
            message = Self.profileNotReadyMessage
            return
        }
        let identity = accountIdentity
        let previous = shareLabels
        let name = savedName
        shareLabels = on
        guard await run(Self.genericMessage, {
            try await self.service.updateProfile(displayName: name, shareLabels: on)
        }) != nil else {
            guard accountIdentity == identity else { return }
            shareLabels = previous
            await refreshProductSharing()
            return
        }
        guard accountIdentity == identity else { return }
        await refreshProductSharing()
    }

    /// Saves the name: trimmed, capped at `nameLimit`, and empty means no name. Nothing is sent until the
    /// profile has been read.
    public func saveName(_ text: String) async {
        await serialized { await self.applyName(text) }
    }

    private func applyName(_ text: String) async {
        guard profileReady else {
            message = Self.profileNotReadyMessage
            return
        }
        let capped = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String? = capped.isEmpty ? nil : capped
        let identity = accountIdentity
        let sharing = shareLabels
        guard let profile = await run(Self.genericMessage, {
            try await self.service.updateProfile(displayName: name, shareLabels: sharing)
        }), accountIdentity == identity else { return }
        savedName = profile.displayName
        displayName = profile.displayName ?? ""
    }

    /// Reads the profile again after a failed read. Does nothing when nobody is signed in.
    public func retryProfile() async {
        guard phase == .signedIn else { return }
        await refreshProfile()
    }

    public func signOut() async {
        guard !signOutInProgress else { return }
        signOutInProgress = true
        busyCount += 1
        defer {
            signOutInProgress = false
            busyCount -= 1
        }
        automaticRestoreClosed = true
        // Remove every source of local eligibility before logout can suspend with a valid session.
        clearSignedInState()
        _ = await run(Self.genericMessage, { try await self.service.signOut() })
    }

    /// Deletes the account on the server. The session is forgotten here only after the server agrees.
    public func deleteAccount() async {
        if let userID = currentUserID { preferences.setProductSharingPause(.accountDeletion, for: userID) }
        productSharing?.closeGate(reason: .accountDeletion)
        productDeliveryPausedAfterDeletion = true
        accountIdentity = UUID()
        let deletingUserID = currentUserID
        let deletingOwner = deletingUserID.flatMap(UUID.init(uuidString:))
        let identity = accountIdentity
        guard await run(Self.genericMessage, { try await self.service.deleteAccount() }) != nil else { return }
        if let deletingOwner { productSharing?.accountWasDeleted(ownerID: deletingOwner) }
        // The deleted account's own acknowledgment goes with it; the other accounts' entries stay.
        if let userID = deletingUserID {
            preferences.setHasSeenCommunityDisclosure(false, for: userID)
            preferences.setProductSharingPause(nil, for: userID)
        }
        guard accountIdentity == identity else { return }
        productDeliveryPausedAfterDeletion = false
        clearSignedInState()
    }

    /// Called after Erase all data cleared the stored preferences: a signed-in person who has not read the
    /// disclosure on this device is asked again, and nothing is shared until they do.
    public func pauseSharingForErase() {
        accountIdentity = UUID()
        productCapabilities = nil
        if let userID = currentUserID { preferences.setProductSharingPause(.erase, for: userID) }
        productDeliveryPausedAfterDeletion = true
        productSharing?.closeGate(reason: .erase)
    }

    public func refreshAfterErase() {
        productDeliveryPausedAfterDeletion = currentUserID.flatMap { preferences.productSharingPause(for: $0) } != nil
        if phase == .signedIn {
            needsDisclosure = !currentAccountAcknowledged
        }
    }

    /// The signed-in person has read the sharing disclosure. Stored for this account, so it is not shown again
    /// for that account on this device. Ignored while a call is running, so a tap during a busy call is never
    /// taken for agreement, and ignored when nobody is signed in.
    public func acknowledgeDisclosure() {
        guard productService == nil, !isBusy, let userID = currentUserID else { return }
        preferences.setHasSeenCommunityDisclosure(true, for: userID)
        needsDisclosure = false
    }

    /// True when the signed-in account has read the disclosure. No signed-in account means no acknowledgment.
    private var currentAccountAcknowledged: Bool {
        guard let userID = currentUserID else { return false }
        guard preferences.hasSeenCommunityDisclosure(for: userID) else { return false }
        guard productService != nil else { return true }
        guard let capability = productCapabilities else { return false }
        return capability.currentConsentVersion == 2 && capability.callerAcknowledgment?.version == 2 &&
            capability.callerAcknowledgment?.generation == capability.consentGeneration
    }

    /// Version-two consent is an owner-bound server acknowledgment, independent of sharing permission.
    public func acknowledgeProductDisclosure() async {
        guard let productService else { acknowledgeDisclosure(); return }
        guard !isBusy, profileReady, let userID = currentUserID, let owner = UUID(uuidString: userID) else { return }
        let identity = accountIdentity
        busyCount += 1
        defer { busyCount -= 1 }
        do {
            let capability = try await productService.capabilities()
            guard currentUserID == userID, accountIdentity == identity, capability.supportedVersion == 2 else { return }
            let consent = try await productService.acknowledgeConsent(version: 2, expectedOwnerID: owner)
            guard currentUserID == userID, accountIdentity == identity, consent.version == 2,
                  consent.acknowledged, consent.generation == capability.consentGeneration else { return }
            let refreshed = try await productService.capabilities()
            guard currentUserID == userID, accountIdentity == identity,
                  refreshed.consentGeneration == consent.generation,
                  refreshed.callerAcknowledgment?.version == 2,
                  refreshed.callerAcknowledgment?.generation == consent.generation else { return }
            productCapabilities = refreshed
            preferences.setHasSeenCommunityDisclosure(true, for: userID)
            needsDisclosure = false
            updateProductContext(explicitRecovery: productSharing?.pauseReason == .erase && !productDeliveryPausedAfterDeletion)
        } catch { message = Self.genericMessage }
    }

    /// Launch/foreground refresh. A failed deletion remains paused until the explicit recovery action.
    public func refreshProductSharing() async {
        guard let productService, phase == .signedIn, profileReady, let userID = currentUserID else { return }
        let identity = accountIdentity
        do {
            let capability = try await productService.capabilities()
            guard currentUserID == userID, accountIdentity == identity else { return }
            productCapabilities = capability
            needsDisclosure = !currentAccountAcknowledged
            updateProductContext()
        } catch {
            guard currentUserID == userID, accountIdentity == identity else { return }
            productCapabilities = nil
            productSharing?.closeGate(reason: .unavailable)
        }
    }

    public func recoverSharingAfterFailedDeletion() async {
        guard productDeliveryPausedAfterDeletion, let userID = currentUserID else { return }
        let identity = accountIdentity
        guard let live = await service.restore(), live.userID == userID, accountIdentity == identity else { return }
        await refreshProfile()
        guard currentUserID == userID, accountIdentity == identity, profileReady,
              productService == nil || productCapabilities != nil else { return }
        preferences.setProductSharingPause(nil, for: userID)
        productDeliveryPausedAfterDeletion = false
        updateProductContext(explicitRecovery: true)
    }

    private func updateProductContext(explicitRecovery: Bool = false) {
        let persistedPause = currentUserID.flatMap { preferences.productSharingPause(for: $0) }
        productDeliveryPausedAfterDeletion = persistedPause != nil
        guard let owner = currentUserID.flatMap(UUID.init(uuidString:)), let capability = productCapabilities else { return }
        let context = ProductShareAccountContext(ownerID: owner, profileReady: profileReady,
            sharingAllowed: shareLabels && currentAccountAcknowledged,
            consentVersion: capability.callerAcknowledgment?.version ?? 0, serverGeneration: capability.consentGeneration,
            localSessionEpoch: UUID(), backendSupported: capability.supportedVersion == 2)
        if explicitRecovery { productSharing?.recoverAfterLifecyclePause(context) }
        else { productSharing?.updateAccountContext(context) }
        if let persistedPause { productSharing?.closeGate(reason: persistedPause) }
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
        busyCount += 1
        defer { busyCount -= 1 }
        message = nil
        let identity = accountIdentity
        do {
            return try await call()
        } catch {
            guard identity == accountIdentity else { return nil }
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
        automaticRestoreClosed = false
        signInCount += 1
        signIn(with: session)
        emailStep = .enterAddress
        pendingEmail = ""
        needsDisclosure = !currentAccountAcknowledged
    }

    private func signIn(with session: CommunitySession) {
        productSharing?.closeGate(reason: .accountChanged)
        accountIdentity = UUID()
        productCapabilities = nil
        phase = .signedIn
        currentUserID = session.userID
        productDeliveryPausedAfterDeletion = preferences.productSharingPause(for: session.userID) != nil
        email = session.email ?? ""
        profileReady = false
    }

    /// Reads the name and the sharing switch the server holds. Until this succeeds the profile is not ready, and
    /// a failure shows a message and keeps the defaults.
    private func refreshProfile() async {
        let identity = accountIdentity
        profileReady = false
        productSharing?.closeGate(reason: .accountChanged)
        guard let profile = await run(Self.genericMessage, { try await self.service.profile() }), identity == accountIdentity else { return }
        savedName = profile.displayName
        displayName = profile.displayName ?? ""
        shareLabels = profile.shareLabels
        profileReady = true
        await refreshProductSharing()
    }

    private func clearSignedInState() {
        productSharing?.updateAccountContext(nil)
        accountIdentity = UUID()
        productCapabilities = nil
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
