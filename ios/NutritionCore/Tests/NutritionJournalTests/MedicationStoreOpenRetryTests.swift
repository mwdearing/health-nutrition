import Foundation
import NutritionDomain
import SwiftData
import XCTest
@testable import NutritionJournal

/// A medication store file that cannot be opened at launch never stops the app from starting. The store starts
/// unopened, tries the open again on each call, and its erase removes the files it could not open and opens an empty
/// store in their place. A store that was closed still refuses to erase.
final class MedicationStoreOpenRetryTests: XCTestCase {
    private var pen: Medication {
        Medication(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, name: "Example weekly injection",
            unit: .mg, scheduleDays: 7)
    }

    private func makeURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("medications.store")
    }

    /// Writes bytes that are not a store at the file and its two companions.
    private func writeDamagedFiles(at url: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            try Data("not a store".utf8).write(to: URL(fileURLWithPath: url.path + suffix))
        }
    }

    private func operations(_ steps: OpenRetrySteps) -> StoreFileOperations {
        StoreFileOperations(
            checkpoint: { _ in
                steps.checkpoints += 1
                throw StoreFileError.checkpointFailed
            },
            remove: { file in
                steps.removed.append(file.lastPathComponent)
                if steps.removalFails { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: file)
                // Once the damaged files are gone, the file at the URL opens as a new store.
                steps.openFails = false
            },
            openContainer: { url in
                steps.opens += 1
                if steps.openFails { throw CocoaError(.fileReadCorruptFile) }
                return try SwiftDataMedicationStore.makeContainer(url: url)
            })
    }

    func testAFileThatCannotOpenDoesNotThrowAndEachCallTriesTheOpenAgain() throws {
        let url = try makeURL()
        let steps = OpenRetrySteps()
        steps.openFails = true
        let store = SwiftDataMedicationStore(retryingOpenAt: url, fileOperations: operations(steps))
        addTeardownBlock { store.close() }
        XCTAssertEqual(steps.opens, 1)

        XCTAssertThrowsError(try store.medications()) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadCorruptFile)
        }
        XCTAssertThrowsError(try store.saveMedication(pen))
        XCTAssertEqual(steps.opens, 3)

        steps.openFails = false
        XCTAssertEqual(try store.medications(), [])
        try store.saveMedication(pen)
        XCTAssertEqual(try store.medications(), [pen])
        XCTAssertEqual(steps.opens, 4, "once open, the store does not open the file again")
    }

    func testAFileThatOpensIsUsedAsAlways() throws {
        let url = try makeURL()
        let store = SwiftDataMedicationStore(retryingOpenAt: url)
        try store.saveMedication(pen)
        XCTAssertEqual(try store.medications(), [pen])
        store.close()
        let reopened = try SwiftDataMedicationStore(url: url)
        XCTAssertEqual(try reopened.medications(), [pen])
        reopened.close()
    }

    func testAnEraseOfAFileThatCannotOpenRemovesItsFilesWithoutACheckpointAndOpensAnEmptyStore() throws {
        let url = try makeURL()
        try writeDamagedFiles(at: url)
        let steps = OpenRetrySteps()
        steps.openFails = true
        let store = SwiftDataMedicationStore(retryingOpenAt: url, fileOperations: operations(steps))
        addTeardownBlock { store.close() }

        try store.eraseAll()

        XCTAssertEqual(steps.checkpoints, 0, "a file that cannot be opened cannot be checkpointed")
        XCTAssertEqual(steps.removed, ["medications.store-shm", "medications.store-wal", "medications.store"])
        XCTAssertEqual(try store.medications(), [])
        XCTAssertEqual(try store.allDoses(), [])
        try store.saveMedication(pen)
        XCTAssertEqual(try store.medications(), [pen])
    }

    func testAFailedRemovalIsReportedLeavesTheStoreUnopenedAndTheNextEraseTriesAgain() throws {
        let url = try makeURL()
        try writeDamagedFiles(at: url)
        let steps = OpenRetrySteps()
        steps.openFails = true
        steps.removalFails = true
        let store = SwiftDataMedicationStore(retryingOpenAt: url, fileOperations: operations(steps))
        addTeardownBlock { store.close() }

        XCTAssertThrowsError(try store.eraseAll()) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteNoPermission)
        }
        XCTAssertEqual(steps.removed, ["medications.store-shm"], "the removal stops at the first failure")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try store.medications())

        steps.removalFails = false
        try store.eraseAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertEqual(try store.medications(), [])
    }

    func testADamagedFileIsNeverRemovedWithoutAnErase() throws {
        let url = try makeURL()
        try writeDamagedFiles(at: url)
        let steps = OpenRetrySteps()
        steps.openFails = true
        let store = SwiftDataMedicationStore(retryingOpenAt: url, fileOperations: operations(steps))
        addTeardownBlock { store.close() }

        XCTAssertThrowsError(try store.medications())
        XCTAssertThrowsError(try store.allDoses())
        XCTAssertThrowsError(try store.saveMedication(pen))

        XCTAssertEqual(steps.removed, [])
        XCTAssertEqual(try Data(contentsOf: url), Data("not a store".utf8))
    }

    func testAClosedStoreStillRefusesToEraseAndRemovesNothing() throws {
        let url = try makeURL()
        let steps = OpenRetrySteps()
        let store = SwiftDataMedicationStore(retryingOpenAt: url, fileOperations: operations(steps))
        try store.saveMedication(pen)
        store.close()

        XCTAssertThrowsError(try store.eraseAll()) { XCTAssertEqual($0 as? MedicationStoreError, .closed) }
        XCTAssertEqual(steps.removed, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAnUnopenedStoreThatIsClosedRefusesToEraseAndRemovesNothing() throws {
        let url = try makeURL()
        try writeDamagedFiles(at: url)
        let steps = OpenRetrySteps()
        steps.openFails = true
        let store = SwiftDataMedicationStore(retryingOpenAt: url, fileOperations: operations(steps))
        store.close()

        XCTAssertThrowsError(try store.eraseAll()) { XCTAssertEqual($0 as? MedicationStoreError, .closed) }
        XCTAssertThrowsError(try store.medications()) { XCTAssertEqual($0 as? MedicationStoreError, .closed) }
        XCTAssertEqual(steps.removed, [])
    }
}

/// What the file steps did, and which of them fail.
private final class OpenRetrySteps: @unchecked Sendable {
    var openFails = false
    var removalFails = false
    var opens = 0
    var checkpoints = 0
    var removed: [String] = []
}
