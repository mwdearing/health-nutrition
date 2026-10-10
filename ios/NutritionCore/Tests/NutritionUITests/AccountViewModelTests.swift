import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders
import XCTest
@testable import NutritionUI

/// Stands in for the community client. Every call is recorded, and each reply is set by the test.
/// Holds one service call open until the test opens the gate, so a test can look at the model while it is busy.
final class CallGate: @unchecked Sendable {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var entered = false

    func pass() async {
        entered = true
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

final class FakeAccountService: CommunityAccountServicing, @unchecked Sendable {
    var restored: CommunitySession?
    var appleResult: Result<CommunitySession, Error>
    var codeError: Error?
    var verifyResult: Result<CommunitySession, Error>
    var profileValue = CommunityProfile(displayName: nil, shareLabels: true)
    var profileError: Error?
    var updateError: Error?
    var deleteError: Error?
    /// When set, `restore()` waits at this gate before it answers.
    var restoreGate: CallGate?
    /// When set, `profile()` waits at this gate before it answers.
    var profileGate: CallGate?
    private(set) var appleCalls: [(idToken: String, nonce: String)] = []
    private(set) var codeRequests: [String] = []
    private(set) var verifyCalls: [(email: String, code: String)] = []
    private(set) var updates: [(displayName: String?, shareLabels: Bool)] = []
    private(set) var signOutCount = 0
    private(set) var deleteCount = 0

    init(session: CommunitySession?) {
        restored = session
        appleResult = .success(session ?? AccountTestSupport.session)
        verifyResult = .success(session ?? AccountTestSupport.session)
    }

    func restore() async -> CommunitySession? {
        await restoreGate?.pass()
        return restored
    }

    func signInWithApple(idToken: String, nonce: String) async throws -> CommunitySession {
        appleCalls.append((idToken, nonce))
        return try appleResult.get()
    }

    func requestEmailCode(email: String) async throws {
        codeRequests.append(email)
        if let codeError { throw codeError }
    }

    func verifyEmailCode(email: String, code: String) async throws -> CommunitySession {
        verifyCalls.append((email, code))
        return try verifyResult.get()
    }

    func signOut() async {
        signOutCount += 1
    }

    func profile() async throws -> CommunityProfile {
        await profileGate?.pass()
        if let profileError { throw profileError }
        return profileValue
    }

    func updateProfile(displayName: String?, shareLabels: Bool) async throws -> CommunityProfile {
        updates.append((displayName, shareLabels))
        if let updateError { throw updateError }
        return CommunityProfile(displayName: displayName, shareLabels: shareLabels)
    }

    func deleteAccount() async throws {
        deleteCount += 1
        if let deleteError { throw deleteError }
    }
}

enum AccountTestSupport {
    static let session = CommunitySession(
        accessToken: "test-access-token",
        refreshToken: "test-refresh-token",
        expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
        userID: "00000000-0000-0000-0000-000000000001",
        email: "person@example.com"
    )
}

/// An error whose text carries a token, a code and an address, to prove that no message repeats it.
struct LeakyAccountError: Error, LocalizedError {
    var errorDescription: String? { "test-access-token 654321 person@example.com" }
}

@MainActor
final class AccountViewModelTests: XCTestCase {
    private func makeModel(
        session: CommunitySession? = nil, preferences: InMemoryDisplayPreferences = InMemoryDisplayPreferences()
    ) -> (AccountViewModel, FakeAccountService, InMemoryDisplayPreferences) {
        let service = FakeAccountService(session: session)
        let model = AccountViewModel(service: service, preferences: preferences)
        return (model, service, preferences)
    }

    func testSignedOutAtStart() async throws {
        let (model, _, _) = makeModel()
        await model.load()
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertEqual(model.email, "")
        XCTAssertFalse(model.needsDisclosure)
    }

    func testRestoreSignsInWithTheStoredSession() async throws {
        let (model, _, _) = makeModel(session: AccountTestSupport.session)
        await model.load()
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.email, "person@example.com")
    }

    func testAppleSignInSucceedsAndPassesTheTokenAndNonce() async throws {
        let (model, service, _) = makeModel()
        await model.signInWithApple(idToken: "test-apple-token", nonce: "test-raw-nonce")
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(service.appleCalls.count, 1)
        XCTAssertEqual(service.appleCalls.first?.idToken, "test-apple-token")
        XCTAssertEqual(service.appleCalls.first?.nonce, "test-raw-nonce")
        XCTAssertNil(model.message)
    }

    func testAppleSignInFailureStaysSignedOutWithAShortMessage() async throws {
        let (model, service, _) = makeModel()
        service.appleResult = .failure(CommunityError.network)
        await model.signInWithApple(idToken: "test-apple-token", nonce: "test-raw-nonce")
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertEqual(model.message, AccountViewModel.networkMessage)
    }

    func testEmailAddressThenCodeSignsIn() async throws {
        let (model, service, _) = makeModel()
        await model.requestCode(email: " person@example.com ")
        XCTAssertEqual(model.emailStep, .enterCode)
        XCTAssertEqual(service.codeRequests, ["person@example.com"])
        XCTAssertEqual(model.message, AccountViewModel.codeSentMessage)

        await model.verify(code: "123456")
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.emailStep, .enterAddress)
        XCTAssertEqual(service.verifyCalls.first?.email, "person@example.com")
        XCTAssertEqual(service.verifyCalls.first?.code, "123456")
    }

    func testWrongCodeShowsTheCodeMessageAndStaysSignedOut() async throws {
        let (model, service, _) = makeModel()
        await model.requestCode(email: "person@example.com")
        service.verifyResult = .failure(CommunityError.unauthorized)
        await model.verify(code: "123456")
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertEqual(model.message, AccountViewModel.codeWrongMessage)
    }

    func testCodeWithTheWrongShapeIsRefusedWithoutACall() async throws {
        let (model, service, _) = makeModel()
        await model.requestCode(email: "person@example.com")
        await model.verify(code: "12a")
        XCTAssertEqual(model.message, AccountViewModel.codeFormatMessage)
        XCTAssertTrue(service.verifyCalls.isEmpty)
    }

    func testDisclosureIsShownAfterTheFirstSignInOnly() async throws {
        let (model, _, preferences) = makeModel()
        await model.signInWithApple(idToken: "test-apple-token", nonce: "test-raw-nonce")
        XCTAssertTrue(model.needsDisclosure)
        model.acknowledgeDisclosure()
        XCTAssertFalse(model.needsDisclosure)
        XCTAssertTrue(preferences.hasSeenCommunityDisclosure)

        await model.signOut()
        await model.signInWithApple(idToken: "test-apple-token", nonce: "test-raw-nonce")
        XCTAssertFalse(model.needsDisclosure)
    }

    func testDisclosureIsShownWhenAStoredSignInIsRestoredBeforeItWasAcknowledged() async throws {
        let (model, _, _) = makeModel(session: AccountTestSupport.session)
        await model.load()
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertTrue(model.needsDisclosure)
    }

    func testSharingIsNotAllowedUntilTheDisclosureIsAcknowledged() async throws {
        let (model, _, _) = makeModel()
        XCTAssertFalse(model.sharingAllowed)
        await model.signInWithApple(idToken: "test-apple-token", nonce: "test-raw-nonce")
        XCTAssertFalse(model.sharingAllowed)
        model.acknowledgeDisclosure()
        XCTAssertTrue(model.sharingAllowed)
        await model.setSharing(false)
        XCTAssertFalse(model.sharingAllowed)
    }

    func testDisclosureIsNotShownWhenItWasSeenBefore() async throws {
        let preferences = InMemoryDisplayPreferences()
        preferences.setHasSeenCommunityDisclosure(true)
        let (model, _, _) = makeModel(preferences: preferences)
        await model.signInWithApple(idToken: "test-apple-token", nonce: "test-raw-nonce")
        XCTAssertFalse(model.needsDisclosure)
    }

    func testTurningSharingOffCallsTheServiceAndKeepsTheNewValue() async throws {
        let (model, service, _) = makeModel(session: AccountTestSupport.session)
        await model.load()
        await model.setSharing(false)
        XCTAssertFalse(model.shareLabels)
        XCTAssertEqual(service.updates.last?.shareLabels, false)
    }

    func testSharingRollsBackWhenTheServiceFails() async throws {
        let (model, service, _) = makeModel(session: AccountTestSupport.session)
        await model.load()
        service.updateError = CommunityError.server(500)
        await model.setSharing(false)
        XCTAssertTrue(model.shareLabels)
        XCTAssertNotNil(model.message)
    }

    /// A call that finds the sign-in ended leaves the screen signed out, not showing an account that is gone.
    func testASignInThatEndedDuringACallReturnsTheScreenToSignedOut() async throws {
        let (model, service, _) = makeModel(session: AccountTestSupport.session)
        await model.load()
        XCTAssertEqual(model.phase, .signedIn)
        service.updateError = CommunityError.signedOut
        await model.setSharing(false)
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertFalse(model.sharingAllowed)
        XCTAssertEqual(model.message, AccountViewModel.sessionEndedMessage)
    }

    func testNameIsSavedTrimmed() async throws {
        let (model, service, _) = makeModel(session: AccountTestSupport.session)
        await model.load()
        await model.saveName("  Ann  ")
        XCTAssertEqual(service.updates.last?.displayName, "Ann")
        XCTAssertEqual(model.displayName, "Ann")
    }

    func testNameIsCappedAtSixtyCharacters() async throws {
        let (model, service, _) = makeModel(session: AccountTestSupport.session)
        await model.load()
        await model.saveName(String(repeating: "a", count: 80))
        XCTAssertEqual(service.updates.last?.displayName?.count, 60)
    }

    func testSignOutReturnsToSignedOut() async throws {
        let (model, service, _) = makeModel(session: AccountTestSupport.session)
        await model.load()
        await model.signOut()
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertEqual(model.email, "")
        XCTAssertEqual(service.signOutCount, 1)
    }

    func testDeleteAccountClearsTheSession() async throws {
        let (model, service, _) = makeModel(session: AccountTestSupport.session)
        await model.load()
        await model.deleteAccount()
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertEqual(service.deleteCount, 1)
    }

    func testFailedDeleteKeepsTheAccountSignedIn() async throws {
        let (model, service, _) = makeModel(session: AccountTestSupport.session)
        await model.load()
        service.deleteError = CommunityError.network
        await model.deleteAccount()
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.message, AccountViewModel.networkMessage)
    }

    func testMessagesNeverRepeatATokenACodeOrAnAddress() async throws {
        let (model, service, _) = makeModel()
        service.appleResult = .failure(LeakyAccountError())
        await model.signInWithApple(idToken: "test-apple-token", nonce: "test-raw-nonce")
        var texts = [model.message ?? ""]
        service.codeError = LeakyAccountError()
        await model.requestCode(email: "person@example.com")
        texts.append(model.message ?? "")
        service.codeError = nil
        await model.requestCode(email: "person@example.com")
        texts.append(model.message ?? "")
        service.verifyResult = .failure(LeakyAccountError())
        await model.verify(code: "654321")
        texts.append(model.message ?? "")
        XCTAssertEqual(texts.count, 4)
        XCTAssertFalse(texts.contains(""))
        for text in texts {
            XCTAssertFalse(text.contains("test-access-token"))
            XCTAssertFalse(text.contains("654321"))
            XCTAssertFalse(text.contains("person@example.com"))
        }
    }

    /// Waits, up to a bound, until the condition holds. The bound keeps a broken test from hanging.
    private func waitUntil(_ condition: () -> Bool) async {
        var rounds = 0
        while !condition() && rounds < 1000 {
            rounds += 1
            await Task.yield()
        }
    }

    func testAFailedProfileReadLeavesTheProfileNotReady() async throws {
        let (model, service, _) = makeModel(session: AccountTestSupport.session)
        service.profileError = CommunityError.network
        await model.load()
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertFalse(model.profileReady)
        XCTAssertEqual(model.message, AccountViewModel.networkMessage)
    }

    func testSharingIsNotAllowedWhileTheProfileIsNotRead() async throws {
        let preferences = InMemoryDisplayPreferences()
        preferences.setHasSeenCommunityDisclosure(true)
        let (model, service, _) = makeModel(session: AccountTestSupport.session, preferences: preferences)
        service.profileError = CommunityError.network
        await model.load()
        XCTAssertFalse(model.sharingAllowed)
    }

    func testSavingANameWhileTheProfileIsNotReadDoesNotCallTheService() async throws {
        let (model, service, _) = makeModel(session: AccountTestSupport.session)
        service.profileError = CommunityError.network
        await model.load()
        await model.saveName("Ann")
        XCTAssertTrue(service.updates.isEmpty)
        XCTAssertEqual(model.message, AccountViewModel.profileNotReadyMessage)
    }

    func testChangingSharingWhileTheProfileIsNotReadDoesNotCallTheService() async throws {
        let (model, service, _) = makeModel(session: AccountTestSupport.session)
        service.profileError = CommunityError.network
        await model.load()
        await model.setSharing(false)
        XCTAssertTrue(service.updates.isEmpty)
        XCTAssertTrue(model.shareLabels)
        XCTAssertEqual(model.message, AccountViewModel.profileNotReadyMessage)
    }

    func testRetryingTheProfileMakesTheControlsReady() async throws {
        let (model, service, _) = makeModel(session: AccountTestSupport.session)
        service.profileError = CommunityError.network
        await model.load()
        XCTAssertFalse(model.profileReady)

        service.profileError = nil
        service.profileValue = CommunityProfile(displayName: "Ann", shareLabels: true)
        await model.retryProfile()
        XCTAssertTrue(model.profileReady)
        XCTAssertEqual(model.displayName, "Ann")

        await model.saveName("Bea")
        XCTAssertEqual(service.updates.last?.displayName, "Bea")
    }

    func testAcknowledgingTheDisclosureIsIgnoredWhileABusyCallRuns() async throws {
        let (model, service, preferences) = makeModel(session: AccountTestSupport.session)
        let gate = CallGate()
        service.profileGate = gate
        let loading = Task { await model.load() }
        await waitUntil { gate.entered }
        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(model.needsDisclosure)

        model.acknowledgeDisclosure()
        XCTAssertTrue(model.needsDisclosure)
        XCTAssertFalse(preferences.hasSeenCommunityDisclosure)

        gate.open()
        await loading.value
        XCTAssertFalse(model.isBusy)
        model.acknowledgeDisclosure()
        XCTAssertFalse(model.needsDisclosure)
        XCTAssertTrue(preferences.hasSeenCommunityDisclosure)
    }

    func testUsingADifferentAddressReturnsToTheAddressStep() async throws {
        let (model, service, _) = makeModel()
        await model.requestCode(email: "person@example.com")
        model.useDifferentAddress()
        XCTAssertEqual(model.emailStep, .enterAddress)
        XCTAssertNil(model.message)
        await model.verify(code: "123456")
        XCTAssertTrue(service.verifyCalls.isEmpty)
    }

    func testResendingTheCodeUsesTheStoredAddress() async throws {
        let (model, service, _) = makeModel()
        await model.requestCode(email: " person@example.com ")
        await model.resendCode()
        XCTAssertEqual(service.codeRequests, ["person@example.com", "person@example.com"])
        XCTAssertEqual(model.emailStep, .enterCode)
        XCTAssertEqual(model.message, AccountViewModel.codeSentMessage)
    }

    func testResendingAfterADifferentAddressSendsNothing() async throws {
        let (model, service, _) = makeModel()
        await model.requestCode(email: "person@example.com")
        model.useDifferentAddress()
        await model.resendCode()
        XCTAssertEqual(service.codeRequests, ["person@example.com"])
    }

    /// A sign-in that completes while the restore is still running must survive the restore's answer.
    func testASignInThatCompletesWhileRestoreRunsIsNotCleared() async throws {
        let (model, service, _) = makeModel(session: nil)
        let gate = CallGate()
        service.restoreGate = gate
        let loading = Task { await model.load() }
        await waitUntil { gate.entered }
        XCTAssertTrue(model.isBusy)

        await model.signInWithApple(idToken: "test-apple-token", nonce: "test-raw-nonce")
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertTrue(model.isBusy)

        gate.open()
        await loading.value
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.email, "person@example.com")
        XCTAssertFalse(model.isBusy)
    }

    func testSettingsHasNoAccountWithoutAModel() throws {
        let model = AppSettingsViewModel(connections: try makeAccountConnections())
        XCTAssertNil(model.account)
    }

    func testSettingsCarriesTheAccountModelWhenGiven() throws {
        let (account, _, _) = makeModel()
        let model = AppSettingsViewModel(connections: try makeAccountConnections(), account: account)
        XCTAssertTrue(model.account === account)
    }

    private func makeAccountConnections() throws -> ConnectionsPrivacyViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ConnectionsPrivacyViewModel(
            store: try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store")),
            preferences: InMemoryDisplayPreferences())
    }
}
