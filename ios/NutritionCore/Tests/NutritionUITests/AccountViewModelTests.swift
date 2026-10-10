import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders
import XCTest
@testable import NutritionUI

/// Stands in for the community client. Every call is recorded, and each reply is set by the test.
final class FakeAccountService: CommunityAccountServicing, @unchecked Sendable {
    var restored: CommunitySession?
    var appleResult: Result<CommunitySession, Error>
    var codeError: Error?
    var verifyResult: Result<CommunitySession, Error>
    var profileValue = CommunityProfile(displayName: nil, shareLabels: true)
    var updateError: Error?
    var deleteError: Error?
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

    func restore() async -> CommunitySession? { restored }

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

    func profile() async throws -> CommunityProfile { profileValue }

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
        XCTAssertFalse(model.needsDisclosure)
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
