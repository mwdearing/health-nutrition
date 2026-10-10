import Foundation
import NutritionJournal
import XCTest
@testable import NutritionUI

/// When the Add form shows a field's error, what the line beside Save says, and how the errors are cleared.
@MainActor
final class FieldClarityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    private func makeModel() throws -> AddIntakeViewModel {
        AddIntakeViewModel(store: try makeStore(), now: now, timeZoneIdentifier: "UTC")
    }

    /// A new form shows no error at all: a person has not been asked to fill anything in yet.
    func testFieldErrorsAreHiddenBeforeAnyEditOrSave() throws {
        let model = try makeModel()
        XCTAssertFalse(model.hasAttemptedSave)
        XCTAssertNil(model.visibleNameError)
        XCTAssertNil(model.visibleAmountError)
        XCTAssertNil(model.saveBlockedMessage)
    }

    /// A tap of Save is the other moment a field's error may show, and it shows both fields that are wrong.
    func testFieldErrorsAppearAfterASaveAttempt() throws {
        let model = try makeModel()
        XCTAssertFalse(model.save(now: now))
        XCTAssertTrue(model.hasAttemptedSave)
        XCTAssertNotNil(model.visibleNameError)
        XCTAssertNotNil(model.visibleAmountError)
    }

    /// The screenshot case: a word typed into Amount is not an error while the person is still typing it,
    /// and shows under the Amount field once they have left that field.
    func testAmountErrorShowsOnlyAfterTheFieldIsEditedAndLeft() throws {
        let model = try makeModel()
        model.amountText = "Regular"
        XCTAssertNil(model.visibleAmountError, "still in the field: no error yet")
        model.fieldDidEnd(.amount)
        XCTAssertNotNil(model.visibleAmountError)
        XCTAssertEqual(model.visibleAmountError, model.amountError)
        XCTAssertNil(model.visibleNameError, "the name was never edited or left")
        XCTAssertFalse(model.hasAttemptedSave)
    }

    /// Leaving a field that was never edited is not a reason to say it is wrong.
    func testLeavingAFieldWithoutEditingItShowsNoError() throws {
        let model = try makeModel()
        model.fieldDidEnd(.name)
        XCTAssertNil(model.visibleNameError)
    }

    /// The line beside Save points at the fields with the one sentence, and never repeats a field's own error.
    func testSaveLineIsTheSentenceAndNeverRepeatsAFieldError() throws {
        let model = try makeModel()
        XCTAssertFalse(model.save(now: now))
        XCTAssertEqual(model.saveBlockedMessage, "Fix the fields marked above.")
        XCTAssertEqual(model.saveBlockedMessage, AddIntakeViewModel.fixFieldsMessage)
        XCTAssertNotEqual(model.saveBlockedMessage, model.nameError)
        XCTAssertNotEqual(model.saveBlockedMessage, model.amountError)
    }

    /// A reset of the form takes the attempted save with it, so the next visit starts with no errors shown.
    func testResetFieldErrorsClearsTheAttemptedSave() throws {
        let model = try makeModel()
        XCTAssertFalse(model.save(now: now))
        model.resetFieldErrors()
        XCTAssertFalse(model.hasAttemptedSave)
        XCTAssertNil(model.visibleNameError)
        XCTAssertNil(model.visibleAmountError)
        XCTAssertNil(model.saveBlockedMessage)
    }
}
