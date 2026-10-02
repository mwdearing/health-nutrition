import CoreData
import Foundation

enum CoreDataModels {
    private static func attribute(_ name: String, _ type: NSAttributeType, _ defaultValue: Any) -> NSAttributeDescription {
        let description = NSAttributeDescription()
        description.name = name
        description.attributeType = type
        description.isOptional = false
        description.defaultValue = defaultValue
        return description
    }

    static func model(_ version: SpikeSchemaVersion) -> NSManagedObjectModel {
        let revision = NSEntityDescription()
        revision.name = "RevisionRecord"
        var revisionProperties = [
            attribute("intakeID", .stringAttributeType, ""),
            attribute("number", .integer64AttributeType, 0),
            attribute("payload", .stringAttributeType, ""),
            attribute("amountText", .stringAttributeType, ""),
        ]
        if version == .v2 {
            revisionProperties.append(attribute("note", .stringAttributeType, ""))
        }
        revision.properties = revisionProperties

        let outbox = NSEntityDescription()
        outbox.name = "OutboxRecord"
        outbox.properties = [
            attribute("operationID", .stringAttributeType, ""),
            attribute("intakeID", .stringAttributeType, ""),
            attribute("revisionNumber", .integer64AttributeType, 0),
            attribute("kind", .stringAttributeType, ""),
        ]

        let model = NSManagedObjectModel()
        model.entities = [revision, outbox]
        return model
    }
}

final class CoreDataJournalStore: JournalStore {
    var failNextSaveForTesting = false

    private var container: NSPersistentContainer?
    private let version: SpikeSchemaVersion

    init(url: URL, version: SpikeSchemaVersion, behavior: MigrationBehavior) throws {
        self.version = version
        let container = NSPersistentContainer(name: "Journal", managedObjectModel: CoreDataModels.model(version))
        let description = NSPersistentStoreDescription(url: url)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        let migrate = behavior == .migrate
        description.shouldMigrateStoreAutomatically = migrate
        description.shouldInferMappingModelAutomatically = migrate
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }
        if let loadError {
            throw loadError
        }
        self.container = container
    }

    private func openContainer() throws -> NSPersistentContainer {
        guard let container else { throw SpikeError.closed }
        return container
    }

    func save(revision: IntakeRevision, outbox: OutboxOperation) throws {
        let context = try openContainer().newBackgroundContext()
        let fail = failNextSaveForTesting
        failNextSaveForTesting = false
        let hasNote = version == .v2
        try context.performAndWait {
            let revisionObject = NSEntityDescription.insertNewObject(forEntityName: "RevisionRecord", into: context)
            revisionObject.setValue(revision.intakeID, forKey: "intakeID")
            revisionObject.setValue(Int64(revision.number), forKey: "number")
            revisionObject.setValue(revision.payload, forKey: "payload")
            revisionObject.setValue(revision.amountText, forKey: "amountText")
            if hasNote {
                revisionObject.setValue(revision.note, forKey: "note")
            }
            let outboxObject = NSEntityDescription.insertNewObject(forEntityName: "OutboxRecord", into: context)
            outboxObject.setValue(outbox.operationID, forKey: "operationID")
            outboxObject.setValue(outbox.intakeID, forKey: "intakeID")
            outboxObject.setValue(Int64(outbox.revisionNumber), forKey: "revisionNumber")
            outboxObject.setValue(outbox.kind, forKey: "kind")
            do {
                if fail {
                    throw SpikeError.injectedSaveFailure
                }
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    func revisions() throws -> [IntakeRevision] {
        let context = try openContainer().newBackgroundContext()
        return try context.performAndWait {
            try CoreDataJournalStore.fetchRevisions(in: context)
        }
    }

    func outboxOperations() throws -> [OutboxOperation] {
        let context = try openContainer().newBackgroundContext()
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "OutboxRecord")
            let rows = try context.fetch(request)
            return sortedOutbox(rows.map {
                OutboxOperation(
                    operationID: $0.value(forKey: "operationID") as? String ?? "",
                    intakeID: $0.value(forKey: "intakeID") as? String ?? "",
                    revisionNumber: $0.value(forKey: "revisionNumber") as? Int ?? 0,
                    kind: $0.value(forKey: "kind") as? String ?? "")
            })
        }
    }

    func revisionsFromBackground() async throws -> [IntakeRevision] {
        let context = try openContainer().newBackgroundContext()
        return try await context.perform {
            try CoreDataJournalStore.fetchRevisions(in: context)
        }
    }

    func close() {
        guard let container else { return }
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try? coordinator.remove(store)
        }
        self.container = nil
    }

    private static func fetchRevisions(in context: NSManagedObjectContext) throws -> [IntakeRevision] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "RevisionRecord")
        let rows = try context.fetch(request)
        return sortedRevisions(rows.map {
            IntakeRevision(
                intakeID: $0.value(forKey: "intakeID") as? String ?? "",
                number: $0.value(forKey: "number") as? Int ?? 0,
                payload: $0.value(forKey: "payload") as? String ?? "",
                amountText: $0.value(forKey: "amountText") as? String ?? "",
                note: $0.entity.propertiesByName["note"] == nil ? "" : ($0.value(forKey: "note") as? String ?? ""))
        })
    }
}
