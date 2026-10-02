import Foundation
import SwiftData

enum SwiftDataSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [RevisionRecord.self, OutboxRecord.self] }

    @Model
    final class RevisionRecord {
        var intakeID: String
        var number: Int
        var payload: String
        var amountText: String

        init(intakeID: String, number: Int, payload: String, amountText: String) {
            self.intakeID = intakeID
            self.number = number
            self.payload = payload
            self.amountText = amountText
        }
    }

    @Model
    final class OutboxRecord {
        var operationID: String
        var intakeID: String
        var revisionNumber: Int
        var kind: String

        init(operationID: String, intakeID: String, revisionNumber: Int, kind: String) {
            self.operationID = operationID
            self.intakeID = intakeID
            self.revisionNumber = revisionNumber
            self.kind = kind
        }
    }
}

enum SwiftDataSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [RevisionRecord.self, OutboxRecord.self] }

    @Model
    final class RevisionRecord {
        var intakeID: String
        var number: Int
        var payload: String
        var amountText: String
        var note: String = ""

        init(intakeID: String, number: Int, payload: String, amountText: String, note: String) {
            self.intakeID = intakeID
            self.number = number
            self.payload = payload
            self.amountText = amountText
            self.note = note
        }
    }

    @Model
    final class OutboxRecord {
        var operationID: String
        var intakeID: String
        var revisionNumber: Int
        var kind: String

        init(operationID: String, intakeID: String, revisionNumber: Int, kind: String) {
            self.operationID = operationID
            self.intakeID = intakeID
            self.revisionNumber = revisionNumber
            self.kind = kind
        }
    }
}

enum SwiftDataMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SwiftDataSchemaV1.self, SwiftDataSchemaV2.self] }
    static var stages: [MigrationStage] {
        [MigrationStage.lightweight(fromVersion: SwiftDataSchemaV1.self, toVersion: SwiftDataSchemaV2.self)]
    }
}

/// Same versions as the real plan, but the migration stage always fails.
enum SwiftDataFailingMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SwiftDataSchemaV1.self, SwiftDataSchemaV2.self] }
    static var stages: [MigrationStage] {
        [
            MigrationStage.custom(
                fromVersion: SwiftDataSchemaV1.self,
                toVersion: SwiftDataSchemaV2.self,
                willMigrate: { _ in throw SpikeError.injectedMigrationFailure },
                didMigrate: nil
            )
        ]
    }
}

final class SwiftDataJournalStore: JournalStore {
    var failNextSaveForTesting = false

    private var container: ModelContainer?
    private let version: SpikeSchemaVersion

    init(url: URL, version: SpikeSchemaVersion, behavior: MigrationBehavior) throws {
        self.version = version
        switch version {
        case .v1:
            let schema = Schema(versionedSchema: SwiftDataSchemaV1.self)
            let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            container = try ModelContainer(for: schema, configurations: configuration)
        case .v2:
            let schema = Schema(versionedSchema: SwiftDataSchemaV2.self)
            let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            switch behavior {
            case .migrate:
                container = try ModelContainer(
                    for: schema, migrationPlan: SwiftDataMigrationPlan.self, configurations: configuration)
            case .failForTesting:
                container = try ModelContainer(
                    for: schema, migrationPlan: SwiftDataFailingMigrationPlan.self, configurations: configuration)
            }
        }
    }

    private func openContainer() throws -> ModelContainer {
        guard let container else { throw SpikeError.closed }
        return container
    }

    func save(revision: IntakeRevision, outbox: OutboxOperation) throws {
        let context = ModelContext(try openContainer())
        context.autosaveEnabled = false
        switch version {
        case .v1:
            context.insert(SwiftDataSchemaV1.RevisionRecord(
                intakeID: revision.intakeID, number: revision.number,
                payload: revision.payload, amountText: revision.amountText))
            context.insert(SwiftDataSchemaV1.OutboxRecord(
                operationID: outbox.operationID, intakeID: outbox.intakeID,
                revisionNumber: outbox.revisionNumber, kind: outbox.kind))
        case .v2:
            context.insert(SwiftDataSchemaV2.RevisionRecord(
                intakeID: revision.intakeID, number: revision.number,
                payload: revision.payload, amountText: revision.amountText, note: revision.note))
            context.insert(SwiftDataSchemaV2.OutboxRecord(
                operationID: outbox.operationID, intakeID: outbox.intakeID,
                revisionNumber: outbox.revisionNumber, kind: outbox.kind))
        }
        if failNextSaveForTesting {
            failNextSaveForTesting = false
            // The context is dropped without saving; nothing was committed.
            throw SpikeError.injectedSaveFailure
        }
        try context.save()
    }

    func revisions() throws -> [IntakeRevision] {
        try SwiftDataJournalStore.readRevisions(container: try openContainer(), version: version)
    }

    func outboxOperations() throws -> [OutboxOperation] {
        try SwiftDataJournalStore.readOutbox(container: try openContainer(), version: version)
    }

    func revisionsFromBackground() async throws -> [IntakeRevision] {
        let container = try openContainer()
        let version = self.version
        return try await Task.detached {
            try SwiftDataJournalStore.readRevisions(container: container, version: version)
        }.value
    }

    func close() {
        container = nil
    }

    private static func readRevisions(container: ModelContainer, version: SpikeSchemaVersion) throws -> [IntakeRevision] {
        let context = ModelContext(container)
        switch version {
        case .v1:
            let rows = try context.fetch(FetchDescriptor<SwiftDataSchemaV1.RevisionRecord>())
            return sortedRevisions(rows.map {
                IntakeRevision(intakeID: $0.intakeID, number: $0.number, payload: $0.payload, amountText: $0.amountText, note: "")
            })
        case .v2:
            let rows = try context.fetch(FetchDescriptor<SwiftDataSchemaV2.RevisionRecord>())
            return sortedRevisions(rows.map {
                IntakeRevision(intakeID: $0.intakeID, number: $0.number, payload: $0.payload, amountText: $0.amountText, note: $0.note)
            })
        }
    }

    private static func readOutbox(container: ModelContainer, version: SpikeSchemaVersion) throws -> [OutboxOperation] {
        let context = ModelContext(container)
        switch version {
        case .v1:
            let rows = try context.fetch(FetchDescriptor<SwiftDataSchemaV1.OutboxRecord>())
            return sortedOutbox(rows.map {
                OutboxOperation(operationID: $0.operationID, intakeID: $0.intakeID, revisionNumber: $0.revisionNumber, kind: $0.kind)
            })
        case .v2:
            let rows = try context.fetch(FetchDescriptor<SwiftDataSchemaV2.OutboxRecord>())
            return sortedOutbox(rows.map {
                OutboxOperation(operationID: $0.operationID, intakeID: $0.intakeID, revisionNumber: $0.revisionNumber, kind: $0.kind)
            })
        }
    }
}
