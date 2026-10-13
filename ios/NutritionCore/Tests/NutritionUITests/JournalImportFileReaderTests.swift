import Foundation
import NutritionJournal
import XCTest
@testable import NutritionUI

final class JournalImportFileReaderTests: XCTestCase {
    private func file(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-import-\(UUID().uuidString).json")
        try bytes.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadsFileAtExactByteLimit() throws {
        let bytes = Data("{\"a\":1}".utf8)
        let url = try file(bytes)

        let result = try JournalImportFileReader.read(
            url, limits: JournalImportLimits(maxImportBytes: bytes.count, maxAggregateElements: 10))

        XCTAssertEqual(result, bytes)
    }

    func testRefusesOneByteOverEvenWhenMetadataUnderstatesSize() throws {
        let bytes = Data(repeating: 0x61, count: 9)
        let url = try file(bytes)

        XCTAssertThrowsError(try JournalImportFileReader.read(
            url, limits: JournalImportLimits(maxImportBytes: 8, maxAggregateElements: 10),
            metadataSize: { _ in 8 })) { error in
                XCTAssertEqual(error as? JournalImportError, .tooLarge)
            }
    }

    func testRefusesWhenMetadataOverstatesSize() throws {
        let bytes = Data("{}".utf8)
        let url = try file(bytes)

        XCTAssertThrowsError(try JournalImportFileReader.read(
            url, limits: JournalImportLimits(maxImportBytes: 8, maxAggregateElements: 10),
            metadataSize: { _ in 9 })) { error in
                XCTAssertEqual(error as? JournalImportError, .tooLarge)
            }
    }

    func testMissingMetadataStillEnforcesTheLimit() throws {
        let bytes = Data(repeating: 0x61, count: 9)
        let url = try file(bytes)

        XCTAssertThrowsError(try JournalImportFileReader.read(
            url, limits: JournalImportLimits(maxImportBytes: 8, maxAggregateElements: 10),
            metadataSize: { _ in nil })) { error in
                XCTAssertEqual(error as? JournalImportError, .tooLarge)
            }
    }

    func testCancellationClosesTheHandleAndLeavesFileReadable() throws {
        let bytes = Data(repeating: 0x61, count: 10)
        let url = try file(bytes)
        var cancellationChecks = 0

        XCTAssertThrowsError(try JournalImportFileReader.read(
            url, limits: JournalImportLimits(maxImportBytes: 20, maxAggregateElements: 10),
            metadataSize: { _ in nil }, chunkSize: 2, isCancelled: {
                cancellationChecks += 1
                return cancellationChecks > 2
            })) { error in
                XCTAssertTrue(error is CancellationError)
            }

        let reopened = try Data(contentsOf: url)
        XCTAssertEqual(reopened, bytes)
    }

    func testMissingFileReportsReadFailureAndCanBeCreatedAfterward() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-import-missing-\(UUID().uuidString).json")
        XCTAssertThrowsError(try JournalImportFileReader.read(
            url, limits: JournalImportLimits(maxImportBytes: 8, maxAggregateElements: 10)))

        let bytes = Data("{}".utf8)
        try bytes.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try JournalImportFileReader.read(
            url, limits: JournalImportLimits(maxImportBytes: 8, maxAggregateElements: 10)), bytes)
    }

    func testSecurityScopedAccessIsStoppedWhenReadIsCanceled() {
        var stopped = false

        XCTAssertThrowsError(try JournalImportFileReader.withSecurityScopedAccess(
            startAccessing: { true }, stopAccessing: { stopped = true }) {
                throw CancellationError()
            }) { error in
                XCTAssertTrue(error is CancellationError)
            }

        XCTAssertTrue(stopped)
    }

    func testSecurityScopedAccessIsStoppedAfterOtherReadErrors() {
        struct ReadFailure: Error {}
        var stopped = false

        XCTAssertThrowsError(try JournalImportFileReader.withSecurityScopedAccess(
            startAccessing: { true }, stopAccessing: { stopped = true }) {
                throw ReadFailure()
            }) { error in
                XCTAssertTrue(error is ReadFailure)
            }

        XCTAssertTrue(stopped)
    }

    func testSecurityScopeIsNotStoppedWhenAccessWasNotGranted() throws {
        var stopped = false

        let value = try JournalImportFileReader.withSecurityScopedAccess(
            startAccessing: { false }, stopAccessing: { stopped = true }) { "read" }

        XCTAssertEqual(value, "read")
        XCTAssertFalse(stopped)
    }

    func testCompletedReadFromBeforeEraseCannotPublish() {
        var gate = JournalImportReadGate()
        let read = gate.begin(eraseGeneration: 3)

        XCTAssertFalse(gate.finish(read, currentEraseGeneration: 4, isErasing: false))
        XCTAssertNil(gate.activeToken)
    }

    func testReadFinishingDuringEraseCannotPublish() {
        var gate = JournalImportReadGate()
        let read = gate.begin(eraseGeneration: 3)

        XCTAssertFalse(gate.finish(read, currentEraseGeneration: 3, isErasing: true))
        XCTAssertNil(gate.activeToken)
    }

    func testCanceledReadCannotPublish() {
        var gate = JournalImportReadGate()
        let read = gate.begin(eraseGeneration: 3)
        gate.cancel(read)

        XCTAssertFalse(gate.finish(read, currentEraseGeneration: 3, isErasing: false))
        XCTAssertNil(gate.activeToken)
    }

    func testStartingANewReadPreventsAnOlderReadFromPublishing() {
        var gate = JournalImportReadGate()
        let oldRead = gate.begin(eraseGeneration: 3)
        let newRead = gate.begin(eraseGeneration: 3)

        XCTAssertFalse(gate.finish(oldRead, currentEraseGeneration: 3, isErasing: false))
        XCTAssertTrue(gate.finish(newRead, currentEraseGeneration: 3, isErasing: false))
        XCTAssertNil(gate.activeToken)
    }
}
