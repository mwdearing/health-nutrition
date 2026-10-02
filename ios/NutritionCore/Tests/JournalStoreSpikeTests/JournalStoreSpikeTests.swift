import XCTest
@testable import JournalStoreSpike

enum StoreKind {
    case swiftData
    case coreData

    func storeURL(in directory: URL) -> URL {
        switch self {
        case .swiftData: return directory.appendingPathComponent("journal-swiftdata.store")
        case .coreData: return directory.appendingPathComponent("journal-coredata.sqlite")
        }
    }

    func open(
        at url: URL,
        version: SpikeSchemaVersion = .v2,
        behavior: MigrationBehavior = .migrate
    ) throws -> any JournalStore {
        switch self {
        case .swiftData:
            return try SwiftDataJournalStore(url: url, version: version, behavior: behavior)
        case .coreData:
            return try CoreDataJournalStore(url: url, version: version, behavior: behavior)
        }
    }
}

let sampleRevision1 = IntakeRevision(
    intakeID: "intake-1", number: 1, payload: "oats and milk", amountText: "125.50", note: "")
let sampleOutbox1 = OutboxOperation(
    operationID: "op-1", intakeID: "intake-1", revisionNumber: 1, kind: "upsertIntake")
let sampleRevision2 = IntakeRevision(
    intakeID: "intake-1", number: 2, payload: "oats, milk and honey", amountText: "140.25", note: "added honey")
let sampleOutbox2 = OutboxOperation(
    operationID: "op-2", intakeID: "intake-1", revisionNumber: 2, kind: "upsertIntake")

final class JournalStoreSpikeTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalStoreSpike-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    // MARK: Scenarios (shared by both stores, assertions stay in the tests)

    private func migrationScenario(_ kind: StoreKind) throws -> (migrated: [IntakeRevision], outbox: [OutboxOperation], afterWrite: [IntakeRevision]) {
        let url = kind.storeURL(in: try makeDirectory())
        let v1 = try kind.open(at: url, version: .v1)
        try v1.save(revision: sampleRevision1, outbox: sampleOutbox1)
        v1.close()

        let v2 = try kind.open(at: url, version: .v2)
        let migrated = try v2.revisions()
        let outbox = try v2.outboxOperations()
        try v2.save(revision: sampleRevision2, outbox: sampleOutbox2)
        let afterWrite = try v2.revisions()
        v2.close()
        return (migrated, outbox, afterWrite)
    }

    private func atomicScenario(_ kind: StoreKind) throws -> (revisions: [IntakeRevision], outbox: [OutboxOperation]) {
        let store = try kind.open(at: kind.storeURL(in: try makeDirectory()))
        try store.save(revision: sampleRevision1, outbox: sampleOutbox1)
        let result = (try store.revisions(), try store.outboxOperations())
        store.close()
        return result
    }

    private func failedSaveScenario(_ kind: StoreKind) throws -> (threw: Bool, revisions: [IntakeRevision], outbox: [OutboxOperation], reopenedRevisions: [IntakeRevision], reopenedOutbox: [OutboxOperation]) {
        let url = kind.storeURL(in: try makeDirectory())
        let store = try kind.open(at: url)
        try store.save(revision: sampleRevision1, outbox: sampleOutbox1)
        store.failNextSaveForTesting = true
        var threw = false
        do {
            try store.save(revision: sampleRevision2, outbox: sampleOutbox2)
        } catch {
            threw = true
        }
        let revisions = try store.revisions()
        let outbox = try store.outboxOperations()
        store.close()
        let reopened = try kind.open(at: url)
        let reopenedRevisions = try reopened.revisions()
        let reopenedOutbox = try reopened.outboxOperations()
        reopened.close()
        return (threw, revisions, outbox, reopenedRevisions, reopenedOutbox)
    }

    private func backgroundScenario(_ kind: StoreKind) async throws -> [IntakeRevision] {
        let store = try kind.open(at: kind.storeURL(in: try makeDirectory()))
        try store.save(revision: sampleRevision1, outbox: sampleOutbox1)
        let seen = try await store.revisionsFromBackground()
        store.close()
        return seen
    }

    private func failedMigrationScenario(_ kind: StoreKind) throws -> (migrationThrew: Bool, readable: [IntakeRevision], readableOutbox: [OutboxOperation]) {
        let url = kind.storeURL(in: try makeDirectory())
        let v1 = try kind.open(at: url, version: .v1)
        try v1.save(revision: sampleRevision1, outbox: sampleOutbox1)
        v1.close()

        var threw = false
        do {
            let broken = try kind.open(at: url, version: .v2, behavior: .failForTesting)
            broken.close()
        } catch {
            threw = true
        }

        let again = try kind.open(at: url, version: .v1)
        let readable = try again.revisions()
        let readableOutbox = try again.outboxOperations()
        again.close()
        return (threw, readable, readableOutbox)
    }

    private func reopenScenario(_ kind: StoreKind) throws -> (revisions: [IntakeRevision], outbox: [OutboxOperation]) {
        let url = kind.storeURL(in: try makeDirectory())
        let first = try kind.open(at: url)
        try first.save(revision: sampleRevision1, outbox: sampleOutbox1)
        try first.save(revision: sampleRevision2, outbox: sampleOutbox2)
        first.close()
        let second = try kind.open(at: url)
        let result = (try second.revisions(), try second.outboxOperations())
        second.close()
        return result
    }

    // MARK: SwiftData

    func testMigrationV1ToV2KeepsData_SwiftData() throws {
        let r = try migrationScenario(.swiftData)
        XCTAssertEqual(r.migrated, [sampleRevision1])
        XCTAssertEqual(r.outbox, [sampleOutbox1])
        XCTAssertEqual(r.afterWrite, [sampleRevision1, sampleRevision2])
    }

    func testRevisionAndOutboxCommitAtomically_SwiftData() throws {
        let r = try atomicScenario(.swiftData)
        XCTAssertEqual(r.revisions, [sampleRevision1])
        XCTAssertEqual(r.outbox, [sampleOutbox1])
    }

    func testFailedSaveLeavesNeitherRevisionNorOutbox_SwiftData() throws {
        let r = try failedSaveScenario(.swiftData)
        XCTAssertTrue(r.threw)
        XCTAssertEqual(r.revisions, [sampleRevision1])
        XCTAssertEqual(r.outbox, [sampleOutbox1])
        XCTAssertEqual(r.reopenedRevisions, [sampleRevision1])
        XCTAssertEqual(r.reopenedOutbox, [sampleOutbox1])
    }

    func testBackgroundContextReadsCommittedData_SwiftData() async throws {
        let seen = try await backgroundScenario(.swiftData)
        XCTAssertEqual(seen, [sampleRevision1])
    }

    func testFailedMigrationLeavesStoreReadable_SwiftData() throws {
        let r = try failedMigrationScenario(.swiftData)
        XCTAssertTrue(r.migrationThrew)
        XCTAssertEqual(r.readable, [sampleRevision1])
        XCTAssertEqual(r.readableOutbox, [sampleOutbox1])
    }

    func testReopenAfterCloseKeepsData_SwiftData() throws {
        let r = try reopenScenario(.swiftData)
        XCTAssertEqual(r.revisions, [sampleRevision1, sampleRevision2])
        XCTAssertEqual(r.outbox, [sampleOutbox1, sampleOutbox2])
    }

    // MARK: Core Data

    func testMigrationV1ToV2KeepsData_CoreData() throws {
        let r = try migrationScenario(.coreData)
        XCTAssertEqual(r.migrated, [sampleRevision1])
        XCTAssertEqual(r.outbox, [sampleOutbox1])
        XCTAssertEqual(r.afterWrite, [sampleRevision1, sampleRevision2])
    }

    func testRevisionAndOutboxCommitAtomically_CoreData() throws {
        let r = try atomicScenario(.coreData)
        XCTAssertEqual(r.revisions, [sampleRevision1])
        XCTAssertEqual(r.outbox, [sampleOutbox1])
    }

    func testFailedSaveLeavesNeitherRevisionNorOutbox_CoreData() throws {
        let r = try failedSaveScenario(.coreData)
        XCTAssertTrue(r.threw)
        XCTAssertEqual(r.revisions, [sampleRevision1])
        XCTAssertEqual(r.outbox, [sampleOutbox1])
        XCTAssertEqual(r.reopenedRevisions, [sampleRevision1])
        XCTAssertEqual(r.reopenedOutbox, [sampleOutbox1])
    }

    func testBackgroundContextReadsCommittedData_CoreData() async throws {
        let seen = try await backgroundScenario(.coreData)
        XCTAssertEqual(seen, [sampleRevision1])
    }

    func testFailedMigrationLeavesStoreReadable_CoreData() throws {
        let r = try failedMigrationScenario(.coreData)
        XCTAssertTrue(r.migrationThrew)
        XCTAssertEqual(r.readable, [sampleRevision1])
        XCTAssertEqual(r.readableOutbox, [sampleOutbox1])
    }

    func testReopenAfterCloseKeepsData_CoreData() throws {
        let r = try reopenScenario(.coreData)
        XCTAssertEqual(r.revisions, [sampleRevision1, sampleRevision2])
        XCTAssertEqual(r.outbox, [sampleOutbox1, sampleOutbox2])
    }
}
