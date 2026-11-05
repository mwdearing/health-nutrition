import Foundation
import NutritionDomain
import SwiftData
import XCTest
@testable import NutritionJournal

/// An erase removes a medication store file without a checkpoint only when SQLite finds the file damaged. A file that
/// fails to open for another reason (a locked or busy file, a newer schema) is kept and the erase reports the failure,
/// and a file whose pages are damaged is replaced whichever step of the erase finds the damage.
final class MedicationStoreDamageCheckTests: XCTestCase {
    private func pen(_ number: Int) -> Medication {
        Medication(name: "Example weekly injection \(number)", unit: .mg, scheduleDays: 7)
    }

    private func makeURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("medications.store")
    }

    /// A store file at `url` that holds `count` medications, checkpointed and closed.
    private func writeHealthyStore(at url: URL, count: Int) throws -> [Medication] {
        let store = try SwiftDataMedicationStore(url: url)
        let saved = (1...count).map(pen)
        for medication in saved { try store.saveMedication(medication) }
        store.close()
        try SwiftDataJournalStore.checkpointStoreFile(at: url)
        return saved
    }

    func testTheDamageCheckTellsADamagedFileFromAHealthyOne() throws {
        let healthy = try makeURL()
        _ = try writeHealthyStore(at: healthy, count: 1)
        XCTAssertFalse(SwiftDataMedicationStore.storeFileIsDamaged(at: healthy))

        let notAStore = try makeURL()
        try Data("not a store".utf8).write(to: notAStore)
        XCTAssertTrue(SwiftDataMedicationStore.storeFileIsDamaged(at: notAStore))

        XCTAssertFalse(SwiftDataMedicationStore.storeFileIsDamaged(at: try makeURL()), "a missing file is not damaged")
    }

    func testAHealthyFileThatFailsToOpenIsKeptByAnErase() throws {
        let url = try makeURL()
        let saved = try writeHealthyStore(at: url, count: 2)
        let steps = DamageCheckSteps()
        let operations = StoreFileOperations(
            checkpoint: { try SwiftDataJournalStore.checkpointStoreFile(at: $0) },
            remove: { file in
                steps.removed.append(file.lastPathComponent)
                try FileManager.default.removeItem(at: file)
            },
            openContainer: { url in
                if steps.openFails { throw CocoaError(.fileLocking) }
                return try SwiftDataMedicationStore.makeContainer(url: url)
            })
        let store = SwiftDataMedicationStore(retryingOpenAt: url, fileOperations: operations)
        addTeardownBlock { store.close() }

        XCTAssertThrowsError(try store.eraseAll()) { XCTAssertEqual(($0 as? CocoaError)?.code, .fileLocking) }
        XCTAssertEqual(steps.removed, [], "a file that is not damaged is never removed without a checkpoint")

        steps.openFails = false
        XCTAssertEqual(try store.medications().map(\.name).sorted(), saved.map(\.name).sorted())
    }

    func testAFileWithDamagedPagesIsErasedAndOpensEmpty() throws {
        let url = try makeURL()
        _ = try writeHealthyStore(at: url, count: 40)
        // Keep the first page (the file header and the schema) and overwrite every later page.
        var bytes = try Data(contentsOf: url)
        XCTAssertGreaterThan(bytes.count, 8_192)
        bytes.replaceSubrange(4_096..<bytes.count, with: Data(repeating: 0xA5, count: bytes.count - 4_096))
        try bytes.write(to: url)
        XCTAssertTrue(SwiftDataMedicationStore.storeFileIsDamaged(at: url))

        let store = SwiftDataMedicationStore(retryingOpenAt: url)
        addTeardownBlock { store.close() }
        try store.eraseAll()

        XCTAssertFalse(SwiftDataMedicationStore.storeFileIsDamaged(at: url))
        XCTAssertEqual(try store.medications(), [])
        try store.saveMedication(pen(1))
        XCTAssertEqual(try store.medications().count, 1)
    }
}

/// Whether the open fails, and which files the erase removed.
private final class DamageCheckSteps: @unchecked Sendable {
    var openFails = true
    var removed: [String] = []
}
