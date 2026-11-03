import Foundation
import NutritionDomain
import SwiftData
import XCTest
@testable import NutritionJournal

/// An erase whose open and row delete succeed but whose checkpoint fails: the file is replaced without a checkpoint
/// when the damage check finds it damaged, and kept, with the checkpoint failure thrown, when it does not.
final class MedicationStoreCheckpointDamageTests: XCTestCase {
    private func makeURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("medications.store")
    }

    /// A store at `url` holding one medication, whose checkpoint always fails and whose removals are recorded.
    private func makeStore(at url: URL, steps: CheckpointDamageSteps) throws -> SwiftDataMedicationStore {
        let operations = StoreFileOperations(
            checkpoint: { _ in
                steps.checkpoints += 1
                throw StoreFileError.checkpointFailed
            },
            remove: { file in
                steps.removed.append(file.lastPathComponent)
                try FileManager.default.removeItem(at: file)
            },
            openContainer: { try SwiftDataMedicationStore.makeContainer(url: $0) })
        let store = SwiftDataMedicationStore(retryingOpenAt: url, fileOperations: operations)
        addTeardownBlock { store.close() }
        try store.saveMedication(Medication(name: "Example weekly injection", unit: .mg, scheduleDays: 7))
        return store
    }

    func testTheStoreUsesSQLitesDamageCheckByDefault() throws {
        let url = try makeURL()
        let store = SwiftDataMedicationStore(retryingOpenAt: url)
        addTeardownBlock { store.close() }
        let directory = url.deletingLastPathComponent()
        let notAStore = directory.appendingPathComponent("other.store")
        try Data("not a store".utf8).write(to: notAStore)
        XCTAssertTrue(store.storeFileDamageCheck(notAStore))
        XCTAssertFalse(store.storeFileDamageCheck(directory.appendingPathComponent("missing.store")))
    }

    func testADamagedFileWhoseCheckpointFailsIsReplacedAndOpensEmpty() throws {
        let url = try makeURL()
        let steps = CheckpointDamageSteps()
        let store = try makeStore(at: url, steps: steps)
        store.storeFileDamageCheck = { checked in
            steps.checkedURLs.append(checked)
            return true
        }

        try store.eraseAll()

        XCTAssertEqual(steps.checkpoints, 1, "the replacement after the damage check runs without a checkpoint")
        XCTAssertEqual(steps.checkedURLs, [url])
        XCTAssertTrue(steps.removed.contains("medications.store"), "\(steps.removed)")
        XCTAssertEqual(try store.medications(), [])
        try store.saveMedication(Medication(name: "Example vial", unit: .mL))
        XCTAssertEqual(try store.medications().map(\.name), ["Example vial"])
    }

    func testAFileThatIsNotDamagedIsKeptAndTheCheckpointFailureIsThrown() throws {
        let url = try makeURL()
        let steps = CheckpointDamageSteps()
        let store = try makeStore(at: url, steps: steps)
        store.storeFileDamageCheck = { _ in false }

        XCTAssertThrowsError(try store.eraseAll()) { error in
            guard case StoreFileError.checkpointFailed = error else {
                return XCTFail("expected the checkpoint failure, got \(error)")
            }
        }

        XCTAssertEqual(steps.removed, [], "a file that is not damaged is never removed without a checkpoint")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try store.medications(), [], "the rows were deleted before the checkpoint failed")
    }
}

/// How many checkpoints ran, which files the erase removed, and which files the damage check was asked about.
private final class CheckpointDamageSteps: @unchecked Sendable {
    var checkpoints = 0
    var removed: [String] = []
    var checkedURLs: [URL] = []
}
