import Foundation
import SQLite3
import XCTest
@testable import NutritionJournal

/// A file that SQLite cannot read for a moment (busy, locked, short read, no permission) is not damage, so an
/// erase keeps it. Only the corrupt and not-a-database codes count as damage.
final class MedicationStoreBusyFileTests: XCTestCase {
    private func makeURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("plain.sqlite")
    }

    /// A plain SQLite file in the default rollback-journal mode, with one table.
    private func makePlainDatabase(at url: URL) {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE items (value INTEGER)", nil, nil, nil), SQLITE_OK)
    }

    func testBusyLockedAndUnavailableCodesAreNotDamage() {
        // SQLITE_BUSY, SQLITE_PERM, SQLITE_LOCKED, SQLITE_CANTOPEN, and SQLITE_IOERR_SHORT_READ (10 | 2 << 8).
        for code: Int32 in [5, 3, 6, 14, 522] {
            XCTAssertFalse(SwiftDataMedicationStore.isDamageCode(code), "code \(code) is not damage")
        }
    }

    func testCorruptAndNotADatabaseCodesAreDamage() {
        // SQLITE_CORRUPT, SQLITE_NOTADB, and the extended codes SQLITE_CORRUPT_VTAB (11 | 1 << 8) and
        // SQLITE_CORRUPT_INDEX (11 | 3 << 8).
        for code: Int32 in [11, 26, 267, 779] {
            XCTAssertTrue(SwiftDataMedicationStore.isDamageCode(code), "code \(code) is damage")
        }
    }

    func testAFileAnotherConnectionHoldsIsBusyNotDamaged() throws {
        let url = try makeURL()
        makePlainDatabase(at: url)
        var holder: OpaquePointer?
        defer { sqlite3_close(holder) }
        XCTAssertEqual(sqlite3_open_v2(url.path, &holder, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(holder, "BEGIN EXCLUSIVE; INSERT INTO items (value) VALUES (1);", nil, nil, nil), SQLITE_OK)

        XCTAssertFalse(
            SwiftDataMedicationStore.storeFileIsDamaged(at: url), "a file that is busy for now is not damaged")

        XCTAssertEqual(sqlite3_exec(holder, "COMMIT", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(SwiftDataMedicationStore.storeFileIsDamaged(at: url), "the same file is healthy once released")
    }
}
