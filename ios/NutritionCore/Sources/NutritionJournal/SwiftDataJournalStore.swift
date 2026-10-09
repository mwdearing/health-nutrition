import Foundation
import NutritionDomain
import SwiftData

enum JournalSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [IntakeRecord.self, RevisionRecord.self, ProductRecord.self, ProjectionRecord.self, OutboxRecord.self]
    }

    @Model
    final class IntakeRecord {
        var intakeID: String
        var category: String
        var occurredAt: Date
        var timeZoneIdentifier: String
        var meal: String?
        var note: String?
        var lifecycleRaw: String
        var currentRevision: Int

        init(
            intakeID: String, category: String, occurredAt: Date, timeZoneIdentifier: String,
            meal: String?, note: String?, lifecycleRaw: String, currentRevision: Int
        ) {
            self.intakeID = intakeID
            self.category = category
            self.occurredAt = occurredAt
            self.timeZoneIdentifier = timeZoneIdentifier
            self.meal = meal
            self.note = note
            self.lifecycleRaw = lifecycleRaw
            self.currentRevision = currentRevision
        }
    }

    @Model
    final class RevisionRecord {
        var intakeID: String
        var number: Int
        /// JSON array of components; amounts are decimal text.
        var componentsJSON: String
        var productSnapshotID: String?
        var changeReason: String
        var createdAt: Date

        init(
            intakeID: String, number: Int, componentsJSON: String,
            productSnapshotID: String?, changeReason: String, createdAt: Date
        ) {
            self.intakeID = intakeID
            self.number = number
            self.componentsJSON = componentsJSON
            self.productSnapshotID = productSnapshotID
            self.changeReason = changeReason
            self.createdAt = createdAt
        }
    }

    @Model
    final class ProductRecord {
        var snapshotID: String
        var productID: String
        var name: String
        var brand: String?
        var barcode: String?
        var labelBasis: String
        var catalogOrigin: String
        var catalogVersion: String

        init(
            snapshotID: String, productID: String, name: String, brand: String?, barcode: String?,
            labelBasis: String, catalogOrigin: String, catalogVersion: String
        ) {
            self.snapshotID = snapshotID
            self.productID = productID
            self.name = name
            self.brand = brand
            self.barcode = barcode
            self.labelBasis = labelBasis
            self.catalogOrigin = catalogOrigin
            self.catalogVersion = catalogVersion
        }
    }

    @Model
    final class ProjectionRecord {
        var intakeID: String
        var revision: Int
        var destinationRaw: String
        var actionRaw: String
        var stateRaw: String
        var isCurrent: Bool

        init(
            intakeID: String, revision: Int, destinationRaw: String,
            actionRaw: String, stateRaw: String, isCurrent: Bool
        ) {
            self.intakeID = intakeID
            self.revision = revision
            self.destinationRaw = destinationRaw
            self.actionRaw = actionRaw
            self.stateRaw = stateRaw
            self.isCurrent = isCurrent
        }
    }

    @Model
    final class OutboxRecord {
        var operationID: String
        var kindRaw: String
        var intakeID: String
        var revision: Int
        var destinationRaw: String
        var payloadHash: String
        var attempts: Int
        var nextAttemptAt: Date?
        var acknowledgedAt: Date?

        init(
            operationID: String, kindRaw: String, intakeID: String, revision: Int,
            destinationRaw: String, payloadHash: String
        ) {
            self.operationID = operationID
            self.kindRaw = kindRaw
            self.intakeID = intakeID
            self.revision = revision
            self.destinationRaw = destinationRaw
            self.payloadHash = payloadHash
            self.attempts = 0
            self.nextAttemptAt = nil
            self.acknowledgedAt = nil
        }
    }
}

/// The nutrient values a product snapshot carries, added as one optional column. V1 above is kept
/// exactly as the first build wrote it, so a store that build created still has a schema SwiftData can
/// migrate from; a row that has no nutrient payload reads back as a product that states none.
enum JournalSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [IntakeRecord.self, RevisionRecord.self, ProductRecord.self, ProjectionRecord.self, OutboxRecord.self]
    }

    @Model
    final class IntakeRecord {
        var intakeID: String
        var category: String
        var occurredAt: Date
        var timeZoneIdentifier: String
        var meal: String?
        var note: String?
        var lifecycleRaw: String
        var currentRevision: Int

        init(
            intakeID: String, category: String, occurredAt: Date, timeZoneIdentifier: String,
            meal: String?, note: String?, lifecycleRaw: String, currentRevision: Int
        ) {
            self.intakeID = intakeID
            self.category = category
            self.occurredAt = occurredAt
            self.timeZoneIdentifier = timeZoneIdentifier
            self.meal = meal
            self.note = note
            self.lifecycleRaw = lifecycleRaw
            self.currentRevision = currentRevision
        }
    }

    @Model
    final class RevisionRecord {
        var intakeID: String
        var number: Int
        /// JSON array of components; amounts are decimal text.
        var componentsJSON: String
        var productSnapshotID: String?
        var changeReason: String
        var createdAt: Date

        init(
            intakeID: String, number: Int, componentsJSON: String,
            productSnapshotID: String?, changeReason: String, createdAt: Date
        ) {
            self.intakeID = intakeID
            self.number = number
            self.componentsJSON = componentsJSON
            self.productSnapshotID = productSnapshotID
            self.changeReason = changeReason
            self.createdAt = createdAt
        }
    }

    @Model
    final class ProductRecord {
        var snapshotID: String
        var productID: String
        var name: String
        var brand: String?
        var barcode: String?
        var labelBasis: String
        var catalogOrigin: String
        var catalogVersion: String
        /// JSON of the nutrient values the product states, sorted by id.
        var nutrientsJSON: String?

        init(
            snapshotID: String, productID: String, name: String, brand: String?, barcode: String?,
            labelBasis: String, catalogOrigin: String, catalogVersion: String, nutrientsJSON: String? = nil
        ) {
            self.snapshotID = snapshotID
            self.productID = productID
            self.name = name
            self.brand = brand
            self.barcode = barcode
            self.labelBasis = labelBasis
            self.catalogOrigin = catalogOrigin
            self.catalogVersion = catalogVersion
            self.nutrientsJSON = nutrientsJSON
        }
    }

    @Model
    final class ProjectionRecord {
        var intakeID: String
        var revision: Int
        var destinationRaw: String
        var actionRaw: String
        var stateRaw: String
        var isCurrent: Bool

        init(
            intakeID: String, revision: Int, destinationRaw: String,
            actionRaw: String, stateRaw: String, isCurrent: Bool
        ) {
            self.intakeID = intakeID
            self.revision = revision
            self.destinationRaw = destinationRaw
            self.actionRaw = actionRaw
            self.stateRaw = stateRaw
            self.isCurrent = isCurrent
        }
    }

    @Model
    final class OutboxRecord {
        var operationID: String
        var kindRaw: String
        var intakeID: String
        var revision: Int
        var destinationRaw: String
        var payloadHash: String
        var attempts: Int
        var nextAttemptAt: Date?
        var acknowledgedAt: Date?

        init(
            operationID: String, kindRaw: String, intakeID: String, revision: Int,
            destinationRaw: String, payloadHash: String
        ) {
            self.operationID = operationID
            self.kindRaw = kindRaw
            self.intakeID = intakeID
            self.revision = revision
            self.destinationRaw = destinationRaw
            self.payloadHash = payloadHash
            self.attempts = 0
            self.nextAttemptAt = nil
            self.acknowledgedAt = nil
        }
    }
}

/// The suspended-reason column, added as one optional string. V1 and V2 above are kept exactly as the
/// builds that wrote them did, so a file either of them created still has a schema SwiftData can
/// migrate from; an outbox row with no stored reason reads back as suspended for an unnamed reason.
enum JournalSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [IntakeRecord.self, RevisionRecord.self, ProductRecord.self, ProjectionRecord.self, OutboxRecord.self]
    }

    @Model
    final class IntakeRecord {
        var intakeID: String
        var category: String
        var occurredAt: Date
        var timeZoneIdentifier: String
        var meal: String?
        var note: String?
        var lifecycleRaw: String
        var currentRevision: Int

        init(
            intakeID: String, category: String, occurredAt: Date, timeZoneIdentifier: String,
            meal: String?, note: String?, lifecycleRaw: String, currentRevision: Int
        ) {
            self.intakeID = intakeID
            self.category = category
            self.occurredAt = occurredAt
            self.timeZoneIdentifier = timeZoneIdentifier
            self.meal = meal
            self.note = note
            self.lifecycleRaw = lifecycleRaw
            self.currentRevision = currentRevision
        }
    }

    @Model
    final class RevisionRecord {
        var intakeID: String
        var number: Int
        /// JSON array of components; amounts are decimal text.
        var componentsJSON: String
        var productSnapshotID: String?
        var changeReason: String
        var createdAt: Date

        init(
            intakeID: String, number: Int, componentsJSON: String,
            productSnapshotID: String?, changeReason: String, createdAt: Date
        ) {
            self.intakeID = intakeID
            self.number = number
            self.componentsJSON = componentsJSON
            self.productSnapshotID = productSnapshotID
            self.changeReason = changeReason
            self.createdAt = createdAt
        }
    }

    @Model
    final class ProductRecord {
        var snapshotID: String
        var productID: String
        var name: String
        var brand: String?
        var barcode: String?
        var labelBasis: String
        var catalogOrigin: String
        var catalogVersion: String
        /// JSON of the nutrient values the product states, sorted by id.
        var nutrientsJSON: String?

        init(
            snapshotID: String, productID: String, name: String, brand: String?, barcode: String?,
            labelBasis: String, catalogOrigin: String, catalogVersion: String, nutrientsJSON: String? = nil
        ) {
            self.snapshotID = snapshotID
            self.productID = productID
            self.name = name
            self.brand = brand
            self.barcode = barcode
            self.labelBasis = labelBasis
            self.catalogOrigin = catalogOrigin
            self.catalogVersion = catalogVersion
            self.nutrientsJSON = nutrientsJSON
        }
    }

    @Model
    final class ProjectionRecord {
        var intakeID: String
        var revision: Int
        var destinationRaw: String
        var actionRaw: String
        var stateRaw: String
        var isCurrent: Bool

        init(
            intakeID: String, revision: Int, destinationRaw: String,
            actionRaw: String, stateRaw: String, isCurrent: Bool
        ) {
            self.intakeID = intakeID
            self.revision = revision
            self.destinationRaw = destinationRaw
            self.actionRaw = actionRaw
            self.stateRaw = stateRaw
            self.isCurrent = isCurrent
        }
    }

    @Model
    final class OutboxRecord {
        var operationID: String
        var kindRaw: String
        var intakeID: String
        var revision: Int
        var destinationRaw: String
        var payloadHash: String
        var attempts: Int
        var nextAttemptAt: Date?
        var acknowledgedAt: Date?
        /// Why the operation was suspended, kept so a later run and the next launch report the same
        /// reason rather than guessing from the state. Nil while the operation has never been suspended,
        /// and backfilled by the V2→V3 migration for operations the previous schema left suspended.
        var suspensionReason: String?

        init(
            operationID: String, kindRaw: String, intakeID: String, revision: Int,
            destinationRaw: String, payloadHash: String
        ) {
            self.operationID = operationID
            self.kindRaw = kindRaw
            self.intakeID = intakeID
            self.revision = revision
            self.destinationRaw = destinationRaw
            self.payloadHash = payloadHash
            self.attempts = 0
            self.nextAttemptAt = nil
            self.acknowledgedAt = nil
            self.suspensionReason = nil
        }
    }
}

/// The deletion instant and the sent link snapshot, added as two optional columns. V3 above is kept
/// exactly as the build that wrote it did, so a store that build created still has a schema SwiftData
/// can migrate from.
///
/// Both columns exist because a hashed payload cannot be corrected under the same delivery identity: a
/// delete whose `deleted_at` was rebuilt from a different instant, or an upsert whose links changed
/// between two attempts, arrives at the receiver under one `operation_id` with a different
/// `client_payload_hash` and is a conflict rather than the duplicate it is. A row written before these
/// columns carries neither, and is delivered from the durable record the journal already keeps.
enum JournalSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [IntakeRecord.self, RevisionRecord.self, ProductRecord.self, ProjectionRecord.self, OutboxRecord.self]
    }

    @Model
    final class IntakeRecord {
        var intakeID: String
        var category: String
        var occurredAt: Date
        var timeZoneIdentifier: String
        var meal: String?
        var note: String?
        var lifecycleRaw: String
        var currentRevision: Int

        init(
            intakeID: String, category: String, occurredAt: Date, timeZoneIdentifier: String,
            meal: String?, note: String?, lifecycleRaw: String, currentRevision: Int
        ) {
            self.intakeID = intakeID
            self.category = category
            self.occurredAt = occurredAt
            self.timeZoneIdentifier = timeZoneIdentifier
            self.meal = meal
            self.note = note
            self.lifecycleRaw = lifecycleRaw
            self.currentRevision = currentRevision
        }
    }

    @Model
    final class RevisionRecord {
        var intakeID: String
        var number: Int
        /// JSON array of components; amounts are decimal text.
        var componentsJSON: String
        var productSnapshotID: String?
        var changeReason: String
        var createdAt: Date

        init(
            intakeID: String, number: Int, componentsJSON: String,
            productSnapshotID: String?, changeReason: String, createdAt: Date
        ) {
            self.intakeID = intakeID
            self.number = number
            self.componentsJSON = componentsJSON
            self.productSnapshotID = productSnapshotID
            self.changeReason = changeReason
            self.createdAt = createdAt
        }
    }

    @Model
    final class ProductRecord {
        var snapshotID: String
        var productID: String
        var name: String
        var brand: String?
        var barcode: String?
        var labelBasis: String
        var catalogOrigin: String
        var catalogVersion: String
        /// JSON of the nutrient values the product states, sorted by id.
        var nutrientsJSON: String?

        init(
            snapshotID: String, productID: String, name: String, brand: String?, barcode: String?,
            labelBasis: String, catalogOrigin: String, catalogVersion: String, nutrientsJSON: String? = nil
        ) {
            self.snapshotID = snapshotID
            self.productID = productID
            self.name = name
            self.brand = brand
            self.barcode = barcode
            self.labelBasis = labelBasis
            self.catalogOrigin = catalogOrigin
            self.catalogVersion = catalogVersion
            self.nutrientsJSON = nutrientsJSON
        }
    }

    @Model
    final class ProjectionRecord {
        var intakeID: String
        var revision: Int
        var destinationRaw: String
        var actionRaw: String
        var stateRaw: String
        var isCurrent: Bool

        init(
            intakeID: String, revision: Int, destinationRaw: String,
            actionRaw: String, stateRaw: String, isCurrent: Bool
        ) {
            self.intakeID = intakeID
            self.revision = revision
            self.destinationRaw = destinationRaw
            self.actionRaw = actionRaw
            self.stateRaw = stateRaw
            self.isCurrent = isCurrent
        }
    }

    @Model
    final class OutboxRecord {
        var operationID: String
        var kindRaw: String
        var intakeID: String
        var revision: Int
        var destinationRaw: String
        var payloadHash: String
        var attempts: Int
        var nextAttemptAt: Date?
        var acknowledgedAt: Date?
        /// Why the operation was suspended, kept so a later run and the next launch report the same
        /// reason rather than guessing from the state.
        var suspensionReason: String?
        /// The instant this intake was deleted, written when the delete row is queued.
        ///
        /// Nil for an upsert, which has no tombstone, and for a row queued by a build that predates the
        /// column. `deleted_at` is hashed into the delete's domain and client digests, so this has to be
        /// the real instant the journal was given, durable: a rebuild that named a different one would
        /// arrive under the same `operation_id` as a conflict instead of a duplicate.
        var deletedAt: Date?
        /// The link snapshot this operation was first encoded with, as the contract writes it.
        ///
        /// Nil until the operation's first attempt records it, and never changed afterwards: the retry
        /// of an upsert has to carry the same links under the same identity or the receiver reads it as a
        /// conflict rather than the duplicate it is. An upsert with no links records an empty snapshot, so
        /// "recorded with no links" is distinguishable from "never attempted".
        var linksJSON: String?

        init(
            operationID: String, kindRaw: String, intakeID: String, revision: Int,
            destinationRaw: String, payloadHash: String, suspensionReason: String? = nil,
            deletedAt: Date? = nil, linksJSON: String? = nil
        ) {
            self.operationID = operationID
            self.kindRaw = kindRaw
            self.intakeID = intakeID
            self.revision = revision
            self.destinationRaw = destinationRaw
            self.payloadHash = payloadHash
            self.attempts = 0
            self.nextAttemptAt = nil
            self.acknowledgedAt = nil
            self.suspensionReason = suspensionReason
            self.deletedAt = deletedAt
            self.linksJSON = linksJSON
        }
    }
}

/// The time each revision was written with, added as two optional columns on the revision. V4 above is
/// kept exactly as the build that wrote it did, so a store that build created still has a schema
/// SwiftData can migrate from.
///
/// These columns exist for the same reason V4's two do: a hashed payload cannot be rebuilt from a value
/// that has since moved. Correcting an entry's time writes a new revision and moves
/// `IntakeRecord.occurredAt`, so before this a queued revision 1 rebuilt at delivery time named the
/// *corrected* instant under revision 1's own `operation_id` — a different payload under one delivery
/// identity, which the receiver reads as a conflict rather than the duplicate it is.
///
/// Both are optional and an existing row carries neither, so the stage that adds them is custom rather than
/// lightweight: V4 had no way to correct a time, which makes the intake's row the one copy of the instant
/// that was exact for **every** revision of the entry, and each revision takes it. Nil therefore means "the
/// entry's current time" for a row nothing ever filled in, and the reads fall back to the entry's row for it.
enum JournalSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [IntakeRecord.self, RevisionRecord.self, ProductRecord.self, ProjectionRecord.self, OutboxRecord.self]
    }

    @Model
    final class IntakeRecord {
        var intakeID: String
        var category: String
        var occurredAt: Date
        var timeZoneIdentifier: String
        var meal: String?
        var note: String?
        var lifecycleRaw: String
        var currentRevision: Int

        init(
            intakeID: String, category: String, occurredAt: Date, timeZoneIdentifier: String,
            meal: String?, note: String?, lifecycleRaw: String, currentRevision: Int
        ) {
            self.intakeID = intakeID
            self.category = category
            self.occurredAt = occurredAt
            self.timeZoneIdentifier = timeZoneIdentifier
            self.meal = meal
            self.note = note
            self.lifecycleRaw = lifecycleRaw
            self.currentRevision = currentRevision
        }
    }

    @Model
    final class RevisionRecord {
        var intakeID: String
        var number: Int
        /// JSON array of components; amounts are decimal text.
        var componentsJSON: String
        var productSnapshotID: String?
        var changeReason: String
        var createdAt: Date
        /// The instant this revision was written for, nil meaning "the entry's current time". The V4→V5
        /// migration fills this in on rows written before the column existed, from the entry's own row.
        var occurredAt: Date?
        /// The zone `occurredAt` is a wall clock in, nil under the same rule.
        var timeZoneIdentifier: String?

        init(
            intakeID: String, number: Int, componentsJSON: String,
            productSnapshotID: String?, changeReason: String, createdAt: Date,
            occurredAt: Date? = nil, timeZoneIdentifier: String? = nil
        ) {
            self.intakeID = intakeID
            self.number = number
            self.componentsJSON = componentsJSON
            self.productSnapshotID = productSnapshotID
            self.changeReason = changeReason
            self.createdAt = createdAt
            self.occurredAt = occurredAt
            self.timeZoneIdentifier = timeZoneIdentifier
        }
    }

    @Model
    final class ProductRecord {
        var snapshotID: String
        var productID: String
        var name: String
        var brand: String?
        var barcode: String?
        var labelBasis: String
        var catalogOrigin: String
        var catalogVersion: String
        /// JSON of the nutrient values the product states, sorted by id.
        var nutrientsJSON: String?

        init(
            snapshotID: String, productID: String, name: String, brand: String?, barcode: String?,
            labelBasis: String, catalogOrigin: String, catalogVersion: String, nutrientsJSON: String? = nil
        ) {
            self.snapshotID = snapshotID
            self.productID = productID
            self.name = name
            self.brand = brand
            self.barcode = barcode
            self.labelBasis = labelBasis
            self.catalogOrigin = catalogOrigin
            self.catalogVersion = catalogVersion
            self.nutrientsJSON = nutrientsJSON
        }
    }

    @Model
    final class ProjectionRecord {
        var intakeID: String
        var revision: Int
        var destinationRaw: String
        var actionRaw: String
        var stateRaw: String
        var isCurrent: Bool

        init(
            intakeID: String, revision: Int, destinationRaw: String,
            actionRaw: String, stateRaw: String, isCurrent: Bool
        ) {
            self.intakeID = intakeID
            self.revision = revision
            self.destinationRaw = destinationRaw
            self.actionRaw = actionRaw
            self.stateRaw = stateRaw
            self.isCurrent = isCurrent
        }
    }

    @Model
    final class OutboxRecord {
        var operationID: String
        var kindRaw: String
        var intakeID: String
        var revision: Int
        var destinationRaw: String
        var payloadHash: String
        var attempts: Int
        var nextAttemptAt: Date?
        var acknowledgedAt: Date?
        var suspensionReason: String?
        var deletedAt: Date?
        var linksJSON: String?

        init(
            operationID: String, kindRaw: String, intakeID: String, revision: Int,
            destinationRaw: String, payloadHash: String, suspensionReason: String? = nil,
            deletedAt: Date? = nil, linksJSON: String? = nil
        ) {
            self.operationID = operationID
            self.kindRaw = kindRaw
            self.intakeID = intakeID
            self.revision = revision
            self.destinationRaw = destinationRaw
            self.payloadHash = payloadHash
            self.attempts = 0
            self.nextAttemptAt = nil
            self.acknowledgedAt = nil
            self.suspensionReason = suspensionReason
            self.deletedAt = deletedAt
            self.linksJSON = linksJSON
        }
    }
}

/// **The product kind, as one optional column.** V6 above is V5 with a single `kindRaw` added to the
/// product record; every other model and column is exactly as V5 wrote it, so a store that build created
/// still has a schema SwiftData can migrate from.
///
/// The column is optional and reads as `food` when it is nil, which is the honest reading rather than a
/// value waiting to be recovered: a product recorded before this column existed states nothing about its
/// kind, and this build had no notion of a supplement then, so the food it was recorded as is what that
/// row can honestly be read as. Unlike the V2→V3 and V4→V5 stages there is nothing to copy onto it — the
/// app never wrote the kind anywhere else — so the stage below is **lightweight**, and every row keeps
/// its nutrients, its times and its suspension exactly as they were.
enum JournalSchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [IntakeRecord.self, RevisionRecord.self, ProductRecord.self, ProjectionRecord.self, OutboxRecord.self]
    }

    @Model
    final class IntakeRecord {
        var intakeID: String
        var category: String
        var occurredAt: Date
        var timeZoneIdentifier: String
        var meal: String?
        var note: String?
        var lifecycleRaw: String
        var currentRevision: Int

        init(
            intakeID: String, category: String, occurredAt: Date, timeZoneIdentifier: String,
            meal: String?, note: String?, lifecycleRaw: String, currentRevision: Int
        ) {
            self.intakeID = intakeID
            self.category = category
            self.occurredAt = occurredAt
            self.timeZoneIdentifier = timeZoneIdentifier
            self.meal = meal
            self.note = note
            self.lifecycleRaw = lifecycleRaw
            self.currentRevision = currentRevision
        }
    }

    @Model
    final class RevisionRecord {
        var intakeID: String
        var number: Int
        /// JSON array of components; amounts are decimal text.
        var componentsJSON: String
        var productSnapshotID: String?
        var changeReason: String
        var createdAt: Date
        /// The instant this revision was written for, nil meaning "the entry's current time".
        var occurredAt: Date?
        /// The zone `occurredAt` is a wall clock in, nil under the same rule.
        var timeZoneIdentifier: String?

        init(
            intakeID: String, number: Int, componentsJSON: String,
            productSnapshotID: String?, changeReason: String, createdAt: Date,
            occurredAt: Date? = nil, timeZoneIdentifier: String? = nil
        ) {
            self.intakeID = intakeID
            self.number = number
            self.componentsJSON = componentsJSON
            self.productSnapshotID = productSnapshotID
            self.changeReason = changeReason
            self.createdAt = createdAt
            self.occurredAt = occurredAt
            self.timeZoneIdentifier = timeZoneIdentifier
        }
    }
    @Model
    final class ProductRecord {
        var snapshotID: String
        var productID: String
        var name: String
        var brand: String?
        var barcode: String?
        var labelBasis: String
        var catalogOrigin: String
        var catalogVersion: String
        /// JSON of the nutrient values the product states, sorted by id.
        var nutrientsJSON: String?
        /// The stored spelling of `ProductKind`. Nil means the row was written before the column
        /// existed, which reads as `food`; see the note above the schema.
        var kindRaw: String?

        init(
            snapshotID: String, productID: String, name: String, brand: String?, barcode: String?,
            labelBasis: String, catalogOrigin: String, catalogVersion: String, nutrientsJSON: String? = nil,
            kindRaw: String? = nil
        ) {
            self.snapshotID = snapshotID
            self.productID = productID
            self.name = name
            self.brand = brand
            self.barcode = barcode
            self.labelBasis = labelBasis
            self.catalogOrigin = catalogOrigin
            self.catalogVersion = catalogVersion
            self.nutrientsJSON = nutrientsJSON
            self.kindRaw = kindRaw
        }
    }

    @Model
    final class ProjectionRecord {
        var intakeID: String
        var revision: Int
        var destinationRaw: String
        var actionRaw: String
        var stateRaw: String
        var isCurrent: Bool

        init(
            intakeID: String, revision: Int, destinationRaw: String,
            actionRaw: String, stateRaw: String, isCurrent: Bool
        ) {
            self.intakeID = intakeID
            self.revision = revision
            self.destinationRaw = destinationRaw
            self.actionRaw = actionRaw
            self.stateRaw = stateRaw
            self.isCurrent = isCurrent
        }
    }
    @Model
    final class OutboxRecord {
        var operationID: String
        var kindRaw: String
        var intakeID: String
        var revision: Int
        var destinationRaw: String
        var payloadHash: String
        var attempts: Int
        var nextAttemptAt: Date?
        var acknowledgedAt: Date?
        var suspensionReason: String?
        var deletedAt: Date?
        var linksJSON: String?

        init(
            operationID: String, kindRaw: String, intakeID: String, revision: Int,
            destinationRaw: String, payloadHash: String, suspensionReason: String? = nil,
            deletedAt: Date? = nil, linksJSON: String? = nil
        ) {
            self.operationID = operationID
            self.kindRaw = kindRaw
            self.intakeID = intakeID
            self.revision = revision
            self.destinationRaw = destinationRaw
            self.payloadHash = payloadHash
            self.attempts = 0
            self.nextAttemptAt = nil
            self.acknowledgedAt = nil
            self.suspensionReason = suspensionReason
            self.deletedAt = deletedAt
            self.linksJSON = linksJSON
        }
    }
}
/// The store is written with V6.
///
/// The V1→V2 stage is lightweight: the only change is one optional column, so an existing file is
/// migrated in place and its rows keep their values.
///
/// **The V2→V3 stage is custom, because a lightweight one cannot populate a column.** It also only adds
/// an optional column — every existing column survives untouched, nutrients included — but the new
/// `suspensionReason` has to be filled in for operations the previous schema had already suspended.
/// Leaving it nil would mean `suspendedOperationIDs()` no longer sees them: the V2 store recorded a
/// suspension on the projection and nowhere else, so an upgrade would have silently **released** every
/// denied operation, and the next automatic run would retry a denial that retrying cannot fix, for as
/// long as it took someone to notice.
///
/// The work happens in **`didMigrate`, not `willMigrate`**, and that placement is the whole point of
/// the stage rather than a detail. The context passed to `willMigrate` is still bound to the *old*
/// schema, where `suspensionReason` does not exist: fetching V3 models there fails outright, which
/// means the container never finishes opening and an existing journal does not open at all. After the
/// migration the context is V3, so the new column can be read and written, and the store's own save
/// commits it with the migration.
///
/// **The V3→V4 stage is lightweight, and needs no backfill.** Both new columns are optional and describe
/// something only a delivery can supply: a row queued before this build has no `deletedAt` to carry, and
/// a tombstone for it is encoded from the journal's own last-revision record instead. Nothing already in
/// the file is wrong after the upgrade, so nothing has to be rewritten — and a custom stage here would
/// have to reach the same conclusion in more code.
///
/// **The V4→V5 stage is custom, because its two new columns do have a value to recover.** A revision written
/// before them carries no instant, and the entry's own row held the only copy — but V4 had no way to correct
/// a time, so that copy is exact for **every** revision of the entry rather than exact only for the current
/// one. Copying it onto each row turns a file full of revisions that depend on a row that may later move into
/// one where each states its own instant, which is what a queued delivery reads. Leaving them nil would also
/// have been defensible — nil means "the entry's current time" — but it would leave the two readings
/// indistinguishable, so a revision 1 still waiting in the queue would be rebuilt with whatever time the entry
/// holds now. The reads stay nil-tolerant either way, so a row that was never filled in still falls back.
///
/// It runs in `didMigrate`, for the reason the V2→V3 stage does: the context there is bound to V5, where the
/// two columns exist to write.
///
/// **The V5→V6 stage is lightweight, and needs no backfill.** It adds one optional column to the product
/// record and changes nothing else. The column describes something only the reader can supply: a product
/// row written before this build has no kind, and none was ever written anywhere else, so nil is the
/// whole of what such a row can say — and `.food` is what that nil is read as, because the app had no
/// notion of a supplement then. Filling it in would mean writing down what the file does not hold.
enum JournalMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            JournalSchemaV1.self, JournalSchemaV2.self, JournalSchemaV3.self, JournalSchemaV4.self,
            JournalSchemaV5.self, JournalSchemaV6.self,
        ]
    }
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: JournalSchemaV1.self, toVersion: JournalSchemaV2.self),
            .custom(
                fromVersion: JournalSchemaV2.self, toVersion: JournalSchemaV3.self,
                willMigrate: nil,
                didMigrate: { context in
                    try backfillSuspensionReasons(context: context)
                    try context.save()
                }),
            .lightweight(fromVersion: JournalSchemaV3.self, toVersion: JournalSchemaV4.self),
            .custom(
                fromVersion: JournalSchemaV4.self, toVersion: JournalSchemaV5.self,
                willMigrate: nil,
                didMigrate: { context in
                    try backfillRevisionTimes(context: context)
                    try context.save()
                }),
            .lightweight(fromVersion: JournalSchemaV5.self, toVersion: JournalSchemaV6.self),
        ]
    }

    /// Copies each entry's own time and zone onto every revision row that carries neither, which is what a
    /// V4 file holds: the columns did not exist, so no revision states an instant of its own.
    ///
    /// Every revision of the entry takes the intake's values, not only the current one. V4 could not correct a
    /// time, so the intake's row never moved away from the instant its revisions were written for, and that
    /// single copy is exact for all of them.
    static func backfillRevisionTimes(context: ModelContext) throws {
        let intakes = try context.fetch(FetchDescriptor<JournalSchemaV5.IntakeRecord>())
        guard !intakes.isEmpty else { return }
        var timesByIntake: [String: (occurredAt: Date, timeZoneIdentifier: String)] = [:]
        for intake in intakes {
            // The first row for an intake wins: two rows for one id is not a shape the store writes, and
            // preferring the first keeps this stage deterministic rather than order-dependent.
            if timesByIntake[intake.intakeID] == nil {
                timesByIntake[intake.intakeID] = (intake.occurredAt, intake.timeZoneIdentifier)
            }
        }
        let revisions = try context.fetch(FetchDescriptor<JournalSchemaV5.RevisionRecord>())
        for revision in revisions {
            // A row that already states a time is left alone: this stage only fills in what is missing, so
            // re-running it cannot overwrite a revision's own instant with the entry's current one.
            guard revision.occurredAt == nil, revision.timeZoneIdentifier == nil,
                let times = timesByIntake[revision.intakeID]
            else { continue }
            revision.occurredAt = times.occurredAt
            revision.timeZoneIdentifier = times.timeZoneIdentifier
        }
    }

    /// Copies the V2 projection state onto the V3 outbox rows, for the operations it suspended.
    ///
    /// The same match `suspendedOperationIDs()` used in V2, on the same four fields — intake, revision,
    /// destination and action — and only for rows that are still pending: an acknowledged operation was
    /// delivered whatever its projection says.
    ///
    /// The reason written is the store's neutral one rather than a guess. V2 never recorded which kind
    /// of permanent failure it was, so nothing here can name it truthfully, and inventing a specific
    /// cause would be worse than saying the suspension was recorded without one.
    static func backfillSuspensionReasons(context: ModelContext) throws {
        let state = DestinationState.needsAttention.rawValue
        let projections = try context.fetch(FetchDescriptor<JournalSchemaV3.ProjectionRecord>(
            predicate: #Predicate<JournalSchemaV3.ProjectionRecord> { $0.stateRaw == state }))
        guard !projections.isEmpty else { return }
        let operations = try context.fetch(FetchDescriptor<JournalSchemaV3.OutboxRecord>(
            predicate: #Predicate<JournalSchemaV3.OutboxRecord> { $0.acknowledgedAt == nil }))
        for operation in operations {
            let alreadyRecorded = operation.suspensionReason != nil
            guard !alreadyRecorded else { continue }
            for projection in projections {
                let intakeID = projection.intakeID
                let revision = projection.revision
                let destination = projection.destinationRaw
                let action = projection.actionRaw
                if operation.intakeID == intakeID && operation.revision == revision
                    && operation.destinationRaw == destination && operation.kindRaw == action {
                    operation.suspensionReason = SwiftDataJournalStore.unrecordedSuspensionReason
                }
            }
        }
    }
}

typealias IntakeRecord = JournalSchemaV6.IntakeRecord
typealias RevisionRecord = JournalSchemaV6.RevisionRecord
typealias ProductRecord = JournalSchemaV6.ProductRecord
typealias ProjectionRecord = JournalSchemaV6.ProjectionRecord
typealias OutboxRecord = JournalSchemaV6.OutboxRecord

private struct StoredComponent: Codable {
    var componentID: String
    var name: String
    var amountText: String
    var unitSymbol: String
}

/// One stored nutrient value: the state, plus the amount and unit of a known value. Every decimal is
/// POSIX text, so a value survives a round trip exactly. A state this build does not know is stored
/// as written and reads back as unknown, never as zero.
private struct StoredNutrient: Codable {
    var id: String
    var state: String
    var valueText: String?
    var unitSymbol: String?
    /// The words the label printed for a key that is a slug of them (`dha` -> `DHA`), when it printed
    /// any other than the slug spells back out. Nil for a key stored under the journal's own name.
    var displayName: String?
}

/// `RelayDeliveryStore` is named rather than left implied: the relay worker reads the queue, its
/// suspensions and the tombstones a delete is encoded from, and every one of those requirements is
/// already met by the two conformances above. Declaring the refinement says so at the type, so a caller
/// building a `RelayDeliveryWorker` over this store is checked here rather than at the worker's own
/// initializer.
public final class SwiftDataJournalStore: JournalDeliverySuspension, JournalSnapshotSource,
    JournalTombstoneSource, RelayDeliveryStore, JournalRestoreTarget, JournalErasing, JournalMealEditing,
    @unchecked Sendable
{
    private let lock = NSLock()
    /// Serializes whole writes so two edits never read the same current revision. Separate from `lock`.
    private let writeLock = NSLock()
    private var failFlag = false
    private var container: ModelContainer?
    private let enabledDestinations: Set<JournalDestination>

    public var failNextSaveForTesting: Bool {
        get { lock.withLock { failFlag } }
        set { lock.withLock { failFlag = newValue } }
    }

    /// Opens or creates the store file at `url`. Destinations not in `enabledDestinations` get a
    /// disabled projection and no outbox operation.
    public init(url: URL, enabledDestinations: Set<JournalDestination> = [.healthKit, .relay]) throws {
        self.enabledDestinations = enabledDestinations
        let schema = Schema(versionedSchema: JournalSchemaV6.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        container = try ModelContainer(
            for: schema, migrationPlan: JournalMigrationPlan.self, configurations: configuration)
    }

    public func close() {
        lock.withLock { container = nil }
    }

    /// Opens a store with the first released schema, so a test can write a file the current one has to
    /// migrate. Nothing in the app opens a store this way.
    static func legacyStoreForTesting(url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: JournalSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, migrationPlan: JournalMigrationPlan.self, configurations: configuration)
    }

    /// Opens a store written with the schema before the suspension column, so a test can write a file
    /// the current one has to migrate **and backfill**. Nothing in the app opens a store this way.
    static func v2StoreForTesting(url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: JournalSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, migrationPlan: JournalMigrationPlan.self, configurations: configuration)
    }

    /// Writes one suspended outbox operation with the V2 model, exactly as that build recorded it: the
    /// suspension lives on the projection and nowhere else, so migrating it is what proves the
    /// backfill is doing the work rather than the column having been filled in already.
    ///
    /// The V2 container is released before returning, so the caller opens a **real file on disk** rather
    /// than one still held open by this process — which is the situation a real upgrade is in, and the
    /// only one where the migration stage runs at all.
    static func writeV2SuspendedOperationForTesting(
        url: URL, operationID: String, intakeID: String, revision: Int, destination: JournalDestination,
        nutrientsJSON: String?
    ) throws {
        do {
            let context = ModelContext(try v2StoreForTesting(url: url))
            context.autosaveEnabled = false
            context.insert(JournalSchemaV2.ProductRecord(
                snapshotID: "snap-1", productID: "product-1", name: "Sample oats", brand: nil, barcode: nil,
                labelBasis: "per100g", catalogOrigin: "sample", catalogVersion: "1",
                nutrientsJSON: nutrientsJSON))
            context.insert(JournalSchemaV2.ProjectionRecord(
                intakeID: intakeID, revision: revision, destinationRaw: destination.rawValue,
                actionRaw: OutboxKind.upsert.rawValue, stateRaw: DestinationState.needsAttention.rawValue,
                isCurrent: true))
            context.insert(JournalSchemaV2.OutboxRecord(
                operationID: operationID, kindRaw: OutboxKind.upsert.rawValue, intakeID: intakeID,
                revision: revision, destinationRaw: destination.rawValue, payloadHash: "hash"))
            try context.save()
        }
    }

    /// Opens a store written with the schema before the revision carried its own time, so a test can
    /// write a file the current one has to migrate. Nothing in the app opens a store this way.
    static func v4StoreForTesting(url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: JournalSchemaV4.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, migrationPlan: JournalMigrationPlan.self, configurations: configuration)
    }

    /// Writes one revision with the V1 model, exactly as the first build did, and commits it.
    static func writeLegacyRevisionForTesting(
        url: URL, intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date
    ) throws {
        let context = ModelContext(try legacyStoreForTesting(url: url))
        context.autosaveEnabled = false
        let componentsJSON = try encode(components)
        context.insert(JournalSchemaV1.IntakeRecord(
            intakeID: intake.id, category: intake.category, occurredAt: intake.occurredAt,
            timeZoneIdentifier: intake.timeZoneIdentifier, meal: intake.meal, note: intake.note,
            lifecycleRaw: intake.lifecycle.rawValue, currentRevision: 1))
        if let product {
            context.insert(JournalSchemaV1.ProductRecord(
                snapshotID: product.snapshotID, productID: product.productID, name: product.name,
                brand: product.brand, barcode: product.barcode, labelBasis: product.labelBasis,
                catalogOrigin: product.catalogOrigin, catalogVersion: product.catalogVersion))
        }
        context.insert(JournalSchemaV1.RevisionRecord(
            intakeID: intake.id, number: 1, componentsJSON: componentsJSON,
            productSnapshotID: product?.snapshotID, changeReason: "created", createdAt: now))
        try context.save()
    }

    /// Writes one intake and two of its revisions with the V4 model, exactly as that build recorded them:
    /// the time lives on the intake row and the revisions carry none, which is the shape the V4→V5 stage
    /// has to migrate.
    ///
    /// Two revisions rather than one, because the backfill is about **every** row: a single revision cannot
    /// tell a migration that fills each row in from one that happens to fix the one row it can see. The second
    /// is an amounts-only edit, which is the other shape V4 could produce.
    ///
    /// The V4 container is released before returning, so the caller opens a **real file on disk** rather
    /// than one still held open by this process — which is the situation a real upgrade is in.
    static func writeV4RevisionsForTesting(
        url: URL, intake: Intake, components: [IntakeComponent], edited: [IntakeComponent], now: Date
    ) throws {
        do {
            let context = ModelContext(try v4StoreForTesting(url: url))
            context.autosaveEnabled = false
            let componentsJSON = try encode(components)
            let editedJSON = try encode(edited)
            context.insert(JournalSchemaV4.IntakeRecord(
                intakeID: intake.id, category: intake.category, occurredAt: intake.occurredAt,
                timeZoneIdentifier: intake.timeZoneIdentifier, meal: intake.meal, note: intake.note,
                lifecycleRaw: intake.lifecycle.rawValue, currentRevision: 2))
            context.insert(JournalSchemaV4.RevisionRecord(
                intakeID: intake.id, number: 1, componentsJSON: componentsJSON,
                productSnapshotID: nil, changeReason: "created", createdAt: now))
            context.insert(JournalSchemaV4.RevisionRecord(
                intakeID: intake.id, number: 2, componentsJSON: editedJSON,
                productSnapshotID: nil, changeReason: "bigger bowl", createdAt: now))
            try context.save()
        }
    }

    /// Drops a stored snapshot's nutrient values, leaving the row as a store written before the column
    /// existed would have it.
    func clearNutrientsOnSnapshotForTesting(snapshotID: String) throws {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<ProductRecord>(
            predicate: #Predicate<ProductRecord> { $0.snapshotID == snapshotID }))
        guard let row = rows.first else { throw JournalError.corruptRecord(snapshotID) }
        row.nutrientsJSON = nil
        try context.save()
    }

    /// Drops a stored snapshot's kind, leaving the row as a store written before the column existed
    /// would have it: the product states what it states and says nothing about what it is.
    func clearKindOnSnapshotForTesting(snapshotID: String) throws {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<ProductRecord>(
            predicate: #Predicate<ProductRecord> { $0.snapshotID == snapshotID }))
        guard let row = rows.first else { throw JournalError.corruptRecord(snapshotID) }
        row.kindRaw = nil
        try context.save()
    }

    /// Removes a stored snapshot row outright, leaving a revision that still points at it: the shape of a
    /// store whose product table was lost or truncated.
    func deleteSnapshotForTesting(snapshotID: String) throws {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<ProductRecord>(
            predicate: #Predicate<ProductRecord> { $0.snapshotID == snapshotID }))
        guard let row = rows.first else { throw JournalError.corruptRecord(snapshotID) }
        context.delete(row)
        try context.save()
    }

    private func openContainer() throws -> ModelContainer {
        try lock.withLock {
            guard let container else { throw JournalError.closed }
            return container
        }
    }

    private func takeInjectedFailure() -> Bool {
        lock.withLock {
            let flag = failFlag
            failFlag = false
            return flag
        }
    }

    /// Runs `body` on a fresh context and saves once. Any failure rolls the context back.
    private func commit<T>(_ body: (ModelContext) throws -> T) throws -> T {
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(try openContainer())
        context.autosaveEnabled = false
        do {
            let result = try body(context)
            if takeInjectedFailure() {
                throw JournalError.injectedSaveFailure
            }
            try context.save()
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: Writes

    @discardableResult
    public func create(
        _ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date
    ) throws -> IntakeRevision {
        guard JournalValidation.isValidIntakeID(intake.id) else { throw JournalError.invalidIntakeID(intake.id) }
        let json = try Self.encode(components)
        return try commit { context in
            if try Self.intakeRecord(intake.id, in: context) != nil {
                throw JournalError.intakeAlreadyExists(intake.id)
            }
            context.insert(IntakeRecord(
                intakeID: intake.id, category: intake.category, occurredAt: intake.occurredAt,
                timeZoneIdentifier: intake.timeZoneIdentifier, meal: intake.meal, note: intake.note,
                lifecycleRaw: IntakeLifecycle.active.rawValue, currentRevision: 1))
            return try appendRevision(
                intakeID: intake.id, number: 1, componentsJSON: json, components: components,
                product: product, changeReason: "created", now: now,
                occurredAt: intake.occurredAt, timeZoneIdentifier: intake.timeZoneIdentifier, context: context)
        }
    }

    @discardableResult
    public func edit(
        intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String,
        now: Date, occurredAt: Date?, timeZoneIdentifier: String?
    ) throws -> IntakeRevision {
        let json = try Self.encode(components)
        return try commit { context in
            guard let record = try Self.intakeRecord(intakeID, in: context) else {
                throw JournalError.unknownIntake(intakeID)
            }
            guard record.lifecycleRaw == IntakeLifecycle.active.rawValue else {
                throw JournalError.intakeDeleted(intakeID)
            }
            let number = record.currentRevision + 1
            record.currentRevision = number
            // The corrected time moves the entry's own row, in the same save as the revision that
            // carries it. It is read back out of the record rather than out of the arguments, so the
            // revision is hashed and stored with the time the entry now holds: an edit given no time
            // keeps the one it had, and one given a date without a zone keeps that zone. Storing it on
            // the revision as well is what leaves an earlier revision's own instant recoverable after
            // this row has moved — a delivery of that revision must not pick up the corrected time.
            if let occurredAt { record.occurredAt = occurredAt }
            if let timeZoneIdentifier { record.timeZoneIdentifier = timeZoneIdentifier }
            try Self.supersedeProjections(of: intakeID, in: context)
            return try appendRevision(
                intakeID: intakeID, number: number, componentsJSON: json, components: components,
                product: product, changeReason: changeReason, now: now,
                occurredAt: record.occurredAt, timeZoneIdentifier: record.timeZoneIdentifier, context: context)
        }
    }

    /// Changes the meal of an active entry as one new revision, reason "Meal changed". The previous revision's
    /// components and product snapshot are carried over; the entry's own meal moves in the same save.
    @discardableResult
    public func changeMeal(intakeID: String, meal: String?, now: Date) throws -> IntakeRevision? {
        let stored: String? = meal.flatMap { (value: String) -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return try commit { (context: ModelContext) throws -> IntakeRevision? in
            guard let record = try Self.intakeRecord(intakeID, in: context) else {
                throw JournalError.unknownIntake(intakeID)
            }
            guard record.lifecycleRaw == IntakeLifecycle.active.rawValue else {
                throw JournalError.intakeDeleted(intakeID)
            }
            guard record.meal != stored else { return nil }
            let current = record.currentRevision
            let revisionRows = try context.fetch(FetchDescriptor<RevisionRecord>(
                predicate: #Predicate<RevisionRecord> { $0.intakeID == intakeID && $0.number == current }))
            guard let previous = revisionRows.first else {
                throw JournalError.corruptRecord("revision")
            }
            let components = try Self.decode(previous.componentsJSON)
            var product: ProductDefinition?
            if let snapshotID = previous.productSnapshotID {
                let productRows = try context.fetch(FetchDescriptor<ProductRecord>(
                    predicate: #Predicate<ProductRecord> { $0.snapshotID == snapshotID }))
                guard let productRow = productRows.first else {
                    throw JournalError.corruptRecord("product")
                }
                product = Self.snapshot(from: productRow)
            }
            let number = current + 1
            record.meal = stored
            record.currentRevision = number
            try Self.supersedeProjections(of: intakeID, in: context)
            return try appendRevision(
                intakeID: intakeID, number: number, componentsJSON: previous.componentsJSON,
                components: components, product: product, changeReason: "Meal changed", now: now,
                occurredAt: record.occurredAt, timeZoneIdentifier: record.timeZoneIdentifier, context: context)
        }
    }

    public func delete(intakeID: String, now: Date) throws {
        try commit { context in
            guard let record = try Self.intakeRecord(intakeID, in: context) else {
                throw JournalError.unknownIntake(intakeID)
            }
            guard record.lifecycleRaw == IntakeLifecycle.active.rawValue else {
                throw JournalError.intakeDeleted(intakeID)
            }
            record.lifecycleRaw = IntakeLifecycle.deleted.rawValue
            try Self.supersedeProjections(of: intakeID, in: context)
            let revision = record.currentRevision
            queueWork(
                intakeID: intakeID, revision: revision, kind: .delete,
                payload: "delete:\(intakeID):\(revision)", deletedAt: now, context: context)
        }
    }

    // MARK: Restore

    /// Writes the whole plan in one save: the product snapshots, every intake with all of its revisions,
    /// and the tombstones of deleted entries.
    ///
    /// No projection and no outbox operation is written. A restored entry is history the destinations
    /// have already been sent once, so queueing it would deliver it a second time just because a phone
    /// was replaced. That is also why this is separate from `create`: creating an entry means the person
    /// just ate something and it must reach Health, and importing one means they ate it weeks ago.
    ///
    /// The emptiness check is inside this closure, so it is read and the rows are written under one write
    /// lock. A separate check before the save would leave a window in which another write creates an entry
    /// and the restore joins it, which is the merge this refuses.
    ///
    /// The rows are written through the current schema's aliases, so this follows the schema it is built
    /// against. It writes no outbox row at all, which is the whole point: a restored entry was delivered once
    /// already, and a delivery the worker then picks up is the one thing this must not cause. Nothing about
    /// the V3 suspension column therefore applies here, and an outbox row inserted through the V3 model
    /// would start with no suspension reason anyway.
    public func restore(_ plan: JournalRestorePlan) throws -> JournalRestoreReceipt {
        try commit { context in
            guard try context.fetchCount(FetchDescriptor<IntakeRecord>()) == 0 else {
                throw JournalImportError.notEmpty
            }
            var restored: [JournalRestoredIntake] = []
            var insertedProducts: [String] = []
            for product in plan.products {
                if try Self.restoreSnapshot(product, in: context) {
                    insertedProducts.append(product.snapshotID)
                }
            }
            for entry in plan.entries {
                let intake = entry.intake
                context.insert(IntakeRecord(
                    intakeID: intake.id, category: intake.category, occurredAt: intake.occurredAt,
                    timeZoneIdentifier: intake.timeZoneIdentifier, meal: intake.meal, note: intake.note,
                    lifecycleRaw: IntakeLifecycle.active.rawValue, currentRevision: intake.currentRevision))
                for revision in entry.revisions {
                    context.insert(RevisionRecord(
                        intakeID: intake.id, number: revision.number,
                        componentsJSON: try Self.encode(revision.components),
                        productSnapshotID: revision.productSnapshotID, changeReason: revision.changeReason,
                        createdAt: revision.createdAt, occurredAt: revision.occurredAt,
                        timeZoneIdentifier: revision.timeZoneIdentifier))
                }
                restored.append(
                    JournalRestoredIntake(
                        intakeID: intake.id, lifecycle: .active, currentRevision: intake.currentRevision,
                        revisionNumbers: entry.revisions.map(\.number)))
            }
            for tombstone in plan.tombstones {
                // A tombstone has no revision row: the export carries the revision number it was deleted
                // at, not the amounts it held then, and a deleted entry is never shown or repeated.
                context.insert(IntakeRecord(
                    intakeID: tombstone.id, category: tombstone.category, occurredAt: tombstone.occurredAt,
                    timeZoneIdentifier: tombstone.timeZoneIdentifier, meal: tombstone.meal,
                    note: tombstone.note, lifecycleRaw: IntakeLifecycle.deleted.rawValue,
                    currentRevision: tombstone.currentRevision))
                restored.append(
                    JournalRestoredIntake(
                        intakeID: tombstone.id, lifecycle: .deleted,
                        currentRevision: tombstone.currentRevision, revisionNumbers: []))
            }
            return JournalRestoreReceipt(intakes: restored, insertedProductSnapshotIDs: insertedProducts)
        }
    }

    /// Removes the rows a restore inserted, so a later step of the same import can be undone.
    ///
    /// This is compensation, not a reset, and it is deliberately narrow. An intake the restore wrote is only
    /// removed while it still looks exactly as the restore left it: same lifecycle, same current revision. A
    /// write that landed in between - an edit that added a revision, a delete that hid the entry - means
    /// those rows are no longer only the restore's, and removing them would throw the person's work away to
    /// make the journal look empty. So the undo refuses instead, and the importer says the import could not
    /// be put back. Revisions go one number at a time for the same reason. Product rows are removed only for
    /// the snapshots this restore created; nothing else writes one, so nothing else can be caught by it.
    public func undoRestore(_ receipt: JournalRestoreReceipt) throws {
        try commit { context in
            for restored in receipt.intakes {
                // Copied out of the receipt first: a #Predicate may compare a key path of the iterated model
                // only against plain values, not against a property read from a different object. The same
                // rule the delivery bookkeeping below follows for the same reason.
                let intakeID = restored.intakeID
                guard let record = try Self.intakeRecord(intakeID, in: context) else {
                    throw JournalImportError.corrupt(
                        "the entry \(intakeID) is gone already, so the import cannot be undone")
                }
                guard record.lifecycleRaw == restored.lifecycle.rawValue,
                      record.currentRevision == restored.currentRevision
                else {
                    throw JournalImportError.corrupt(
                        "the entry \(intakeID) was written to after the import restored it, "
                            + "so undoing the import would throw that away too")
                }
                for number in restored.revisionNumbers {
                    for row in try context.fetch(FetchDescriptor<RevisionRecord>(
                        predicate: #Predicate<RevisionRecord> { $0.intakeID == intakeID && $0.number == number })) {
                        context.delete(row)
                    }
                }
                context.delete(record)
            }
            for snapshotID in receipt.insertedProductSnapshotIDs {
                for row in try context.fetch(FetchDescriptor<ProductRecord>(
                    predicate: #Predicate<ProductRecord> { $0.snapshotID == snapshotID })) {
                    context.delete(row)
                }
            }
        }
    }

    /// Writes one product snapshot for a restore, and reports whether it created the row.
    ///
    /// A document records which product a revision used and where it came from, not the nutrient values
    /// that product states, so a restored snapshot brings no values of its own. Where this store already
    /// knows the snapshot, its values are the better ones: they are what the journal was reading before the
    /// restore, so they are kept exactly and an import cannot quietly empty them.
    ///
    /// Two rows under one snapshot id may therefore differ only in that one respect, and only when one of
    /// them states no values: the stored row's values win when it has any, and a stored row with none is
    /// filled in from the plan. The product's identity always has to match, and two sets of values that
    /// disagree are a conflict rather than a preference, because one snapshot id cannot name two products
    /// that state different things. Only a row this restore created is listed in the receipt for
    /// `undoRestore` to remove.
    @discardableResult
    private static func restoreSnapshot(_ product: ProductDefinition, in context: ModelContext) throws -> Bool {
        let id = product.snapshotID
        let existing = try context.fetch(FetchDescriptor<ProductRecord>(
            predicate: #Predicate<ProductRecord> { $0.snapshotID == id }))
        guard let row = existing.first else {
            context.insert(ProductRecord(
                snapshotID: product.snapshotID, productID: product.productID, name: product.name,
                brand: product.brand, barcode: product.barcode, labelBasis: product.labelBasis,
                catalogOrigin: product.catalogOrigin, catalogVersion: product.catalogVersion,
                nutrientsJSON: Self.encodeNutrients(
                    product.nutrients, displayNames: product.nutrientDisplayNames),
                kindRaw: product.kind.rawValue))
            return true
        }
        let stored = snapshot(from: row)
        guard stored.identity == product.identity else {
            throw JournalError.snapshotConflict(id)
        }
        // The values are compared as decoded `[String: NutrientValue]`, never as the stored JSON text, so
        // key order, the spelling of a decimal and an absent dictionary cannot make two equal sets look
        // different.
        //
        // A plan that states no values at all is the everyday case: a document carries a product's identity
        // and origin, not what it states, so every snapshot built from one arrives with an empty dictionary.
        // That is not a disagreement with the values this store holds - it is the absence of an opinion -
        // and treating it as one refused every restore into a store that already knew the product. Only two
        // sets that both state values and differ are a conflict, because one snapshot id cannot name two
        // products that state different things.
        guard !product.nutrients.isEmpty, stored.nutrients != product.nutrients else { return false }
        guard stored.nutrients.isEmpty else { throw JournalError.snapshotConflict(id) }
        row.nutrientsJSON = Self.encodeNutrients(
            product.nutrients, displayNames: product.nutrientDisplayNames)
        return false
    }

    /// Writes one product snapshot with no intake, the way a store that already knew a product would hold
    /// it. Only tests use this; nothing in the app writes a snapshot on its own.
    func insertProductSnapshotForTesting(_ product: ProductDefinition) throws {
        let context = ModelContext(try openContainer())
        context.autosaveEnabled = false
        try Self.insertSnapshot(product, in: context)
        try context.save()
    }

    // MARK: Erasing

    /// Removes every row the journal file holds: intakes, their revision history, product snapshots,
    /// projections and queued outbox operations. A deleted entry leaves no tombstone behind either,
    /// because a tombstone only exists so a later export can retract the entry.
    ///
    /// The rows are fetched and deleted one at a time rather than with the batch delete, which runs
    /// against the persistent store immediately, outside the save and outside the rollback. Fetching
    /// keeps the whole erase inside one commit, so a failure anywhere in it leaves the journal exactly
    /// as it was: a journal emptied by a failed save would be worse than an unerased one, because the
    /// person cannot tell which half is gone.
    ///
    /// The container is not closed: the store reads empty and accepts new entries afterwards.
    public func eraseAll() throws {
        _ = try commit { context in
            for row in try context.fetch(FetchDescriptor<RevisionRecord>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<OutboxRecord>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<ProjectionRecord>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<ProductRecord>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<IntakeRecord>()) { context.delete(row) }
        }
    }

    // MARK: Delivery bookkeeping

    /// Marks one operation delivered and its projection `succeeded`, in one save.
    ///
    /// Acknowledging an operation that is already acknowledged is not an error: a worker that
    /// crashed after writing but before recording the delivery will deliver again, and that second
    /// delivery has to be recordable rather than refused.
    public func acknowledge(operationID: String, at date: Date) throws {
        try commit { context in
            guard let row = try Self.outboxRecord(operationID, in: context) else {
                throw JournalError.unknownOperation(operationID)
            }
            guard row.acknowledgedAt == nil else { return }
            row.acknowledgedAt = date
            row.nextAttemptAt = nil
            // A superseded or delivered operation is no longer suspended, and a stale reason left on the
            // row would report it as parked after it has left the queue.
            row.suspensionReason = nil
            try Self.setProjectionState(
                .succeeded, of: row, in: context)
        }
    }

    /// Deletes acknowledged outbox rows acknowledged strictly more than `days` days before `now` and
    /// returns how many were removed. Nothing else is read or written: unacknowledged rows, intakes,
    /// revisions, tombstones, product snapshots and projections are left as they are.
    @discardableResult
    public func pruneAcknowledgedOutbox(
        now: Date, olderThan days: Int = JournalRetention.acknowledgedOutboxDays
    ) throws -> Int {
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        return try commit { context -> Int in
            let acknowledged = try context.fetch(FetchDescriptor<OutboxRecord>(
                predicate: #Predicate<OutboxRecord> { $0.acknowledgedAt != nil }))
            var pruned = 0
            for row in acknowledged {
                guard let acknowledgedAt = row.acknowledgedAt, acknowledgedAt < cutoff else { continue }
                context.delete(row)
                pruned += 1
            }
            return pruned
        }
    }

    /// Records one failed attempt: `attempts` grows by one, and the operation is due again at
    /// `retryAt` unless the failure needs a person, in which case the projection becomes
    /// `needsAttention` and no automatic retry is scheduled.
    ///
    /// An acknowledged operation is left alone: it was delivered, so a failure recorded afterwards
    /// belongs to a different attempt and must not reopen it.
    ///
    /// **A suspension is recorded on the projection belonging to the operation, superseded or not.** A
    /// worker can record the denial after an edit has already superseded that projection — the edit was
    /// queued before the revision's first attempt — and marking only current projections would leave
    /// nothing in `needsAttention`. `suspendedOperationIDs()` matches by state whatever the
    /// projection's currency, so nothing would report the operation, it would look due (`nil` retry
    /// date), and every automatic run would retry a denial forever while growing its attempt count.
    /// `rearmDelivery(operationID:)` clears this same state from this same projection, so both halves
    /// of the suspension have to reach it.
    ///
    /// A transient failure still touches current projections only: it is scheduled to be tried again,
    /// and what a later revision is doing matters more than what an old operation did.
    public func recordFailure(operationID: String, retryAt: Date?, needsAttention: Bool) throws {
        try recordFailure(
            operationID: operationID, retryAt: retryAt, needsAttention: needsAttention, reason: nil)
    }

    /// Records one failed attempt, keeping the reason a suspension is reported with.
    ///
    /// A distinct method rather than a defaulted `reason`, because `JournalOutboxDelivery` states the
    /// three-argument form as a requirement: a defaulted fourth parameter does not satisfy it, so the
    /// store would no longer conform to the protocol it delivers through.
    public func recordFailure(
        operationID: String, retryAt: Date?, needsAttention: Bool, reason: String?
    ) throws {
        try commit { context in
            guard let row = try Self.outboxRecord(operationID, in: context) else {
                throw JournalError.unknownOperation(operationID)
            }
            guard row.acknowledgedAt == nil else { return }
            row.attempts += 1
            row.nextAttemptAt = retryAt
            // The reason is stored, not recomputed: a later run and the next launch have to report the
            // same one, and a rejected sample must not come back worded as a denial.
            row.suspensionReason = needsAttention ? (reason ?? Self.unrecordedSuspensionReason) : nil
            try Self.setProjectionState(
                needsAttention ? .needsAttention : .pending, of: row, in: context,
                includingSuperseded: needsAttention)
            if needsAttention {
                try Self.markCurrentProjectionNeedsAttention(of: row, in: context)
            }
        }
    }

    /// The reason one suspended operation was parked, or nil when it is not suspended.
    ///
    /// Read back rather than reconstructed from the state, because `needsAttention` on its own says
    /// only that a person is needed, not whether Health access was refused or a sample was rejected.
    public func suspensionReason(operationID: String) throws -> String? {
        let context = ModelContext(try openContainer())
        guard let row = try Self.outboxRecord(operationID, in: context), row.acknowledgedAt == nil else {
            return nil
        }
        return row.suspensionReason
    }

    private static func outboxRecord(_ operationID: String, in context: ModelContext) throws -> OutboxRecord? {
        try context.fetch(FetchDescriptor<OutboxRecord>(
            predicate: #Predicate<OutboxRecord> { $0.operationID == operationID })).first
    }

    /// What a suspension reads as when the caller recorded no reason of its own.
    ///
    /// Neutral on purpose: it must not claim the failure was an authorization problem, because the
    /// state that reports it is the same one a rejected sample is parked in.
    static let unrecordedSuspensionReason = "waiting to be re-armed after a failed delivery"

    /// Also marks the **current** projection for this destination `needsAttention`.
    ///
    /// A suspension on a superseded projection is invisible in the app: `EntryDetailViewModel` reads
    /// only current projections, so the entry would show a pending destination while its queue was
    /// parked and every later operation blocked. Propagating the state is what puts the condition in
    /// front of a person.
    ///
    /// It says nothing about the newer operation, and `suspendedOperationIDs()` deliberately does not
    /// read this state: suspension follows an attempt, and the current projection's revision is
    /// normally one whose operation has not been tried at all.
    private static func markCurrentProjectionNeedsAttention(
        of row: OutboxRecord, in context: ModelContext
    ) throws {
        let intakeID = row.intakeID
        let destination = row.destinationRaw
        let rows = try context.fetch(FetchDescriptor<ProjectionRecord>(
            predicate: #Predicate<ProjectionRecord> { $0.intakeID == intakeID }))
        for projection in rows where projection.isCurrent && projection.destinationRaw == destination {
            projection.stateRaw = DestinationState.needsAttention.rawValue
        }
    }

    /// The pending operations a worker must not retry on its own.
    ///
    /// Read off the **operations** rather than inferred from `nextAttemptAt`, because `nil` on that date
    /// means both "do not retry" (suspended) and "due now" (first attempt), and read off the stored
    /// reason rather than a projection's state, because a suspension belongs to the operation that
    /// failed: an edit supersedes its projection while leaving the operation pending, and propagating
    /// `needsAttention` to the current projection for the app to display must not park an operation that
    /// has never been attempted.
    public func suspendedOperationIDs() throws -> Set<String> {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<OutboxRecord>(
            predicate: #Predicate<OutboxRecord> { $0.acknowledgedAt == nil && $0.suspensionReason != nil }))
        return Set(rows.map(\.operationID))
    }

    /// The deletion instant a queued delete row carries, or nil when it carries none.
    ///
    /// Nil for an upsert, which has no tombstone, and for a row queued before the column existed. A
    /// delete without it is still deliverable: the worker falls back to the durable record the journal
    /// already keeps, so an upgraded store does not strand its queued deletions.
    public func deletionInstant(operationID: String) throws -> Date? {
        let context = ModelContext(try openContainer())
        return try Self.outboxRecord(operationID, in: context)?.deletedAt
    }

    /// The link snapshot this operation was last sent under, or nil when nothing has been recorded.
    ///
    /// Read back rather than rebuilt, because the retry of an upsert has to carry the same links under the
    /// same delivery identity: links that changed in between would give the same `operation_id` a
    /// different `client_payload_hash`, which the receiver reads as a conflict rather than a duplicate.
    ///
    /// Nil means no request has carried this operation yet, so there is nothing to repeat and the next
    /// attempt encodes against whatever the links are now. That is the normal state of an operation whose
    /// first piece never went out.
    public func recordedLinks(operationID: String) throws -> [IntakeContextLink]? {
        let context = ModelContext(try openContainer())
        guard let text = try Self.outboxRecord(operationID, in: context)?.linksJSON else { return nil }
        return try RelayDeliveryLinkSnapshot.decode(text)
    }

    /// Records the link snapshot an operation is about to be sent under, keeping the first one it is given.
    ///
    /// Recording is first-write-wins: a later attempt cannot replace what an earlier one was sent with,
    /// which is the whole point of keeping it. When a snapshot is already recorded it is returned and the
    /// one offered now is ignored, so **a returned snapshot that differs from the one offered tells the
    /// caller that another run recorded a different one first** — the record then does not hold what this
    /// caller sent, which is what it needs to know before treating a retry as a duplicate.
    ///
    /// **`isNew` says whether this call wrote the record.** A returned snapshot equal to the one offered does
    /// not prove it: the same snapshot may have been on record from an earlier attempt, or an overlapping run
    /// may have written it first. Only a record this call created may be discarded later, so the caller needs
    /// to be able to tell the two apart.
    ///
    /// Called before the piece carrying the operation is sent, so what is recorded is what will go on the
    /// wire. An operation whose piece never carries it is never recorded here and keeps nothing.
    @discardableResult
    public func recordLinks(
        _ links: [IntakeContextLink], operationID: String
    ) throws -> (snapshot: [IntakeContextLink], isNew: Bool) {
        // Encoded before the commit, so a snapshot that cannot be written leaves the row as it was instead
        // of failing a transaction that would have rolled back anyway.
        let text = try RelayDeliveryLinkSnapshot.encode(links)
        // `isNew` says whether **this call** wrote the record, which is not the same as the returned snapshot
        // matching the one offered: a snapshot already on record from an earlier attempt, or written by an
        // overlapping run, is returned unchanged and is not this call's to discard later.
        let outcome: (existing: String?, isNew: Bool) = try commit { context -> (existing: String?, isNew: Bool) in
            guard let row = try Self.outboxRecord(operationID, in: context) else {
                throw JournalError.unknownOperation(operationID)
            }
            if let winner = row.linksJSON { return (winner, false) }
            guard row.acknowledgedAt == nil else { return (nil, false) }
            row.linksJSON = text
            return (nil, true)
        }
        guard let existing = outcome.existing else { return (links, outcome.isNew) }
        return (try RelayDeliveryLinkSnapshot.decode(existing), outcome.isNew)
    }

    /// Forgets the link snapshot recorded for one operation.
    ///
    /// **Only for a request the receiver refused for size, and only for a record this run wrote.** A 413 is
    /// refused before anything is applied, so the payload was never committed under that operation id and
    /// there is nothing for a later attempt to reproduce. Forgetting the snapshot is what lets the split pieces
    /// record the links current when they actually go out, and leaves an operation whose piece never carried
    /// it with nothing on record.
    ///
    /// A snapshot already on record is **not** this caller's to forget: it belongs to an earlier attempt whose
    /// answer may have been lost, or to an overlapping run about to send it, and the receiver may already hold
    /// that payload under the operation id.
    public func releaseLinks(operationID: String) throws {
        try commit { context in
            guard let row = try Self.outboxRecord(operationID, in: context) else {
                throw JournalError.unknownOperation(operationID)
            }
            guard row.acknowledgedAt == nil else { return }
            row.linksJSON = nil
        }
    }

    /// Clears the suspension on one operation, so an automatic run may pick it up again.
    ///
    /// This is the only way a `needsAttention` operation becomes due again, and it is deliberately a
    /// separate call: re-arming after a person has granted or withdrawn Health access is their
    /// decision, not something a scheduled run may decide on its own.
    public func rearmDelivery(operationID: String) throws {
        try commit { context in
            guard let row = try Self.outboxRecord(operationID, in: context) else {
                throw JournalError.unknownOperation(operationID)
            }
            guard row.acknowledgedAt == nil else { return }
            row.nextAttemptAt = nil
            // The reason goes with the suspension: a re-armed operation is due again, so a stored reason
            // would report a state the operation is no longer in.
            row.suspensionReason = nil
            // `includingSuperseded: true`: the suspension is recorded on the projection belonging to
            // this operation, and a later edit may have made that projection noncurrent. Clearing only
            // current projections would leave the state at `needsAttention` on the projection that
            // actually records it, and the operation would never be delivered again — re-arming would
            // silently do nothing.
            try Self.setProjectionState(.pending, of: row, in: context, includingSuperseded: true)
            // The current projection may be carrying the propagated state as well, so the entry would
            // go on showing a condition that no longer exists. Only cleared when this was the intake's
            // last suspension, so a second parked operation behind it keeps its own state visible.
            let intakeID = row.intakeID
            let destination = row.destinationRaw
            let stillSuspended = try context.fetch(FetchDescriptor<OutboxRecord>(
                predicate: #Predicate<OutboxRecord> {
                    $0.intakeID == intakeID && $0.destinationRaw == destination
                        && $0.acknowledgedAt == nil && $0.suspensionReason != nil
                }))
            if stillSuspended.isEmpty {
                let projections = try context.fetch(FetchDescriptor<ProjectionRecord>(
                    predicate: #Predicate<ProjectionRecord> { $0.intakeID == intakeID }))
                let state = DestinationState.needsAttention.rawValue
                let pending = DestinationState.pending.rawValue
                for projection in projections where projection.isCurrent
                    && projection.destinationRaw == destination && projection.stateRaw == state {
                    projection.stateRaw = pending
                }
            }
        }
    }

    /// Moves the projection for this operation's revision, destination **and action**.
    ///
    /// The action is part of the match because deleting an intake does not bump its revision: the
    /// queued upsert and the queued delete share an intake id, a revision number and a destination, and
    /// differ only in what they are for. Matching without it would let acknowledging the stale upsert
    /// mark the delete `succeeded`, and the app would then report a finished retraction while the
    /// samples are still in Health.
    ///
    /// A superseded projection is left as it is: what a later revision is doing matters more than what
    /// an old operation did.
    /// `includingSuperseded` is for the two halves of a suspension — recording it and clearing it —
    /// which both travel with the operation rather than with the current projection and so may have to
    /// reach one a later edit has already superseded. Every other caller wants current projections only.
    private static func setProjectionState(
        _ state: DestinationState, of row: OutboxRecord, in context: ModelContext,
        includingSuperseded: Bool = false
    ) throws {
        // Copied out of the outbox row first: a #Predicate may compare a key path of the iterated
        // model only against plain values, not against a key path read from a different model object.
        let intakeID = row.intakeID
        let rows = try context.fetch(FetchDescriptor<ProjectionRecord>(
            predicate: #Predicate<ProjectionRecord> { $0.intakeID == intakeID }))
        for projection in rows where (includingSuperseded || projection.isCurrent)
            && projection.revision == row.revision
            && projection.destinationRaw == row.destinationRaw
            && projection.actionRaw == row.kindRaw {
            projection.stateRaw = state.rawValue
        }
    }

    /// One revision, with the entry's time as it stood for that revision: the instant is hashed with
    /// the amounts, because "40 g of oats" and "40 g of oats, eaten at 19:00" are different facts and
    /// a receiver deduplicating on the payload hash must be able to tell them apart.
    ///
    /// The time is stored **on the revision** as well as hashed into the queued payload, because the
    /// entry's own row moves on a time correction and a delivery rebuilds this revision later: without a
    /// copy here, a revision 1 still waiting in the queue would be rebuilt with the corrected instant and
    /// reach the receiver under revision 1's own `operation_id` with a different payload — a conflict
    /// rather than the duplicate it is.
    private func appendRevision(
        intakeID: String, number: Int, componentsJSON: String, components: [IntakeComponent],
        product: ProductDefinition?, changeReason: String, now: Date, occurredAt: Date,
        timeZoneIdentifier: String, context: ModelContext
    ) throws -> IntakeRevision {
        if let product {
            try Self.insertSnapshot(product, in: context)
        }
        context.insert(RevisionRecord(
            intakeID: intakeID, number: number, componentsJSON: componentsJSON,
            productSnapshotID: product?.snapshotID, changeReason: changeReason, createdAt: now,
            occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier))
        let payload = "\(intakeID):\(number):\(product?.snapshotID ?? "")"
            + ":\(IntakeContextTimestamp.utc(occurredAt)):\(timeZoneIdentifier):\(componentsJSON)"
        queueWork(intakeID: intakeID, revision: number, kind: .upsert, payload: payload, context: context)
        return IntakeRevision(
            intakeID: intakeID, number: number, components: components,
            productSnapshotID: product?.snapshotID, changeReason: changeReason, createdAt: now,
            occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier)
    }

    /// One projection per destination; an enabled one also gets one outbox operation.
    ///
    /// `deletedAt` is written on a delete row and only on that one. It is the instant the journal was
    /// given, kept rather than reconstructed: a delete's `deleted_at` is hashed into two digests, so a
    /// rebuild naming a different instant arrives under the same delivery identity as a conflict instead of
    /// the duplicate it is.
    private func queueWork(
        intakeID: String, revision: Int, kind: OutboxKind, payload: String,
        deletedAt: Date? = nil, context: ModelContext
    ) {
        let hash = Self.fingerprint(payload)
        for destination in JournalDestination.allCases {
            let enabled = enabledDestinations.contains(destination)
            context.insert(ProjectionRecord(
                intakeID: intakeID, revision: revision, destinationRaw: destination.rawValue,
                actionRaw: kind.rawValue,
                stateRaw: (enabled ? DestinationState.pending : DestinationState.disabled).rawValue,
                isCurrent: true))
            if enabled {
                context.insert(OutboxRecord(
                    operationID: UUID().uuidString.lowercased(), kindRaw: kind.rawValue, intakeID: intakeID,
                    revision: revision, destinationRaw: destination.rawValue, payloadHash: hash,
                    deletedAt: deletedAt))
            }
        }
    }

    private static func supersedeProjections(of intakeID: String, in context: ModelContext) throws {
        let rows = try context.fetch(FetchDescriptor<ProjectionRecord>(
            predicate: #Predicate<ProjectionRecord> { $0.intakeID == intakeID }))
        for row in rows {
            row.isCurrent = false
        }
    }

    /// A snapshot id is written once. Re-using an id is fine only with identical content.
    ///
    /// A row written before the nutrient column existed carries no values at all. Such a row is the
    /// same product with less recorded, so the values this build has are written into it rather than
    /// refused: the snapshot id still names one product, and the values only ever fill in what the
    /// product states. Any other difference is still a conflict.
    private static func insertSnapshot(_ product: ProductDefinition, in context: ModelContext) throws {
        let id = product.snapshotID
        let existing = try context.fetch(FetchDescriptor<ProductRecord>(
            predicate: #Predicate<ProductRecord> { $0.snapshotID == id }))
        if let row = existing.first {
            let stored = snapshot(from: row)
            if stored == product { return }
            guard stored.nutrients.isEmpty, stored.identity == product.identity else {
                throw JournalError.snapshotConflict(id)
            }
            row.nutrientsJSON = Self.encodeNutrients(
                product.nutrients, displayNames: product.nutrientDisplayNames)
            return
        }
        context.insert(ProductRecord(
            snapshotID: product.snapshotID, productID: product.productID, name: product.name,
            brand: product.brand, barcode: product.barcode, labelBasis: product.labelBasis,
            catalogOrigin: product.catalogOrigin, catalogVersion: product.catalogVersion,
            nutrientsJSON: Self.encodeNutrients(
                product.nutrients, displayNames: product.nutrientDisplayNames),
            kindRaw: product.kind.rawValue))
    }

    // MARK: Reads

    public func activeIntakes() throws -> [Intake] {
        try Self.readActiveIntakes(container: try openContainer())
    }

    public func activeIntakesFromBackground() async throws -> [Intake] {
        let container = try openContainer()
        return try await Task.detached {
            try SwiftDataJournalStore.readActiveIntakes(container: container)
        }.value
    }

    public func revisions(of intakeID: String) throws -> [IntakeRevision] {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<RevisionRecord>(
            predicate: #Predicate<RevisionRecord> { $0.intakeID == intakeID }))
        return try rows.sorted { $0.number < $1.number }.map { row in
            IntakeRevision(
                intakeID: row.intakeID, number: row.number, components: try Self.decode(row.componentsJSON),
                productSnapshotID: row.productSnapshotID, changeReason: row.changeReason, createdAt: row.createdAt,
                occurredAt: row.occurredAt, timeZoneIdentifier: row.timeZoneIdentifier)
        }
    }

    public func projections(of intakeID: String) throws -> [DestinationProjection] {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<ProjectionRecord>(
            predicate: #Predicate<ProjectionRecord> { $0.intakeID == intakeID }))
        return try rows.map { row in
            guard let destination = JournalDestination(rawValue: row.destinationRaw),
                  let action = OutboxKind(rawValue: row.actionRaw),
                  let state = DestinationState(rawValue: row.stateRaw)
            else { throw JournalError.corruptRecord("projection") }
            return DestinationProjection(
                intakeID: row.intakeID, revision: row.revision, destination: destination,
                desiredAction: action, state: state, isCurrent: row.isCurrent)
        }.sorted { ($0.revision, $0.destination.rawValue) < ($1.revision, $1.destination.rawValue) }
    }

    /// Operations not yet acknowledged, oldest revision first, upsert before delete within a revision.
    public func pendingOutbox() throws -> [OutboxOperation] {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<OutboxRecord>(
            predicate: #Predicate<OutboxRecord> { $0.acknowledgedAt == nil }))
        return try rows.map { row in
            guard let kind = OutboxKind(rawValue: row.kindRaw),
                  let destination = JournalDestination(rawValue: row.destinationRaw)
            else { throw JournalError.corruptRecord("outbox") }
            return OutboxOperation(
                operationID: row.operationID, kind: kind, intakeID: row.intakeID, revision: row.revision,
                destination: destination, payloadHash: row.payloadHash, attempts: row.attempts,
                nextAttemptAt: row.nextAttemptAt, acknowledgedAt: row.acknowledgedAt)
        }.sorted {
            ($0.intakeID, $0.revision, Self.kindRank($0.kind), $0.destination.rawValue)
                < ($1.intakeID, $1.revision, Self.kindRank($1.kind), $1.destination.rawValue)
        }
    }

    /// Creation order within one revision: an upsert is always queued before a delete.
    private static func kindRank(_ kind: OutboxKind) -> Int {
        switch kind {
        case .upsert: return 0
        case .delete: return 1
        }
    }

    public func product(snapshotID: String) throws -> ProductDefinition? {
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<ProductRecord>(
            predicate: #Predicate<ProductRecord> { $0.snapshotID == snapshotID }))
        return rows.first.map(Self.snapshot(from:))
    }

    // MARK: Helpers

    private static func intakeRecord(_ id: String, in context: ModelContext) throws -> IntakeRecord? {
        try context.fetch(FetchDescriptor<IntakeRecord>(
            predicate: #Predicate<IntakeRecord> { $0.intakeID == id })).first
    }

    private static func readActiveIntakes(container: ModelContainer) throws -> [Intake] {
        try readIntakes(container: container, lifecycle: .active)
    }

    /// Deleted intakes, kept as tombstones so an export can retract them later.
    public func deletedIntakes() throws -> [Intake] {
        try Self.readIntakes(container: try openContainer(), lifecycle: .deleted)
    }

    /// One consistent read of the journal for the exporter: active intakes with every revision, and deleted
    /// intakes, all from a single model context. The write lock is held for the read, so an export cannot
    /// observe an entry that was deleted after the active list was read but before the tombstones were, which
    /// would leave it in neither list.
    public func readJournalSnapshot() throws -> JournalSnapshot {
        writeLock.lock()
        defer { writeLock.unlock() }
        let context = ModelContext(try openContainer())
        let rows = try context.fetch(FetchDescriptor<IntakeRecord>())
        let revisionRows = try context.fetch(FetchDescriptor<RevisionRecord>())
        let revisionsByIntake = Dictionary(grouping: revisionRows, by: \.intakeID)

        var active: [JournalExportIntakeSnapshot] = []
        var deleted: [Intake] = []
        for row in rows {
            let lifecycle = try Self.lifecycle(rawValue: row.lifecycleRaw)
            let intake = Intake(
                id: row.intakeID, category: row.category, occurredAt: row.occurredAt,
                timeZoneIdentifier: row.timeZoneIdentifier, meal: row.meal, note: row.note,
                lifecycle: lifecycle, currentRevision: row.currentRevision)
            if intake.lifecycle == .deleted {
                deleted.append(intake)
                continue
            }
            var revisions: [IntakeRevision] = []
            for revision in (revisionsByIntake[row.intakeID] ?? []).sorted(by: { $0.number < $1.number }) {
                // A stored row whose components cannot be read is corrupt; the caller must hear about it
                // rather than get an intake with no amounts.
                let components = try Self.decode(revision.componentsJSON)
                revisions.append(
                    IntakeRevision(
                        intakeID: revision.intakeID, number: revision.number, components: components,
                        productSnapshotID: revision.productSnapshotID, changeReason: revision.changeReason,
                        createdAt: revision.createdAt, occurredAt: revision.occurredAt,
                        timeZoneIdentifier: revision.timeZoneIdentifier))
            }
            active.append(JournalExportIntakeSnapshot(intake: intake, revisions: revisions))
        }
        return JournalSnapshot(
            activeIntakes: active.sorted { ($0.intake.occurredAt, $0.intake.id) < ($1.intake.occurredAt, $1.intake.id) },
            deletedIntakes: deleted.sorted { ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id) })
    }

    /// Maps a stored lifecycle string to its value. An unrecognized value means the row is corrupt or was
    /// written by a build this one does not understand: the ordinary active read leaves such a row out
    /// because it predicates on the exact `active` value, so defaulting it to `active` here would put a
    /// deleted entry back into an export as live data. Refuse it instead.
    static func lifecycle(rawValue: String) throws -> IntakeLifecycle {
        guard let lifecycle = IntakeLifecycle(rawValue: rawValue) else {
            throw JournalError.corruptRecord("lifecycle:\(rawValue)")
        }
        return lifecycle
    }

    private static func readIntakes(container: ModelContainer, lifecycle: IntakeLifecycle) throws -> [Intake] {
        let context = ModelContext(container)
        let raw = lifecycle.rawValue
        let rows = try context.fetch(FetchDescriptor<IntakeRecord>(
            predicate: #Predicate<IntakeRecord> { $0.lifecycleRaw == raw }))
        return rows.map {
            Intake(
                id: $0.intakeID, category: $0.category, occurredAt: $0.occurredAt,
                timeZoneIdentifier: $0.timeZoneIdentifier, meal: $0.meal, note: $0.note,
                lifecycle: lifecycle, currentRevision: $0.currentRevision)
        }.sorted { ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id) }
    }

    private static func snapshot(from row: ProductRecord) -> ProductDefinition {
        ProductDefinition(
            snapshotID: row.snapshotID, productID: row.productID, name: row.name, brand: row.brand,
            barcode: row.barcode, labelBasis: row.labelBasis, catalogOrigin: row.catalogOrigin,
            catalogVersion: row.catalogVersion, kind: ProductKind(storedRawValue: row.kindRaw),
            nutrients: Self.decodeNutrients(row.nutrientsJSON),
            nutrientDisplayNames: Self.decodeDisplayNames(row.nutrientsJSON))
    }

    /// The nutrient values a product states, sorted by id so the same values always write the same
    /// text. Values that cannot be encoded are left out rather than stored as something else. The
    /// printed names travel with the values in the same payload, so a key that is a slug of the
    /// label's own wording keeps that wording through a store round trip.
    static func encodeNutrients(
        _ values: [String: NutrientValue], displayNames: [String: String] = [:]
    ) -> String {
        let stored = values.keys.sorted().compactMap { id -> StoredNutrient? in
            guard let value = values[id] else { return nil }
            let displayName = displayNames[id]
            switch value {
            case .known(let amount, let unit):
                return StoredNutrient(
                    id: id, state: "known", valueText: DecimalText.encode(amount), unitSymbol: unit.symbol,
                    displayName: displayName)
            case .unknown:
                return StoredNutrient(id: id, state: "unknown", valueText: nil, unitSymbol: nil, displayName: displayName)
            case .notApplicable:
                return StoredNutrient(id: id, state: "notApplicable", valueText: nil, unitSymbol: nil, displayName: displayName)
            case .belowReportingThreshold(let unit):
                return StoredNutrient(
                    id: id, state: "belowThreshold", valueText: nil, unitSymbol: unit?.symbol,
                    displayName: displayName)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stored) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The printed names stored beside the values, keyed the same way. A payload written before the
    /// names existed carries none, so every key falls back to the name its slug spells out.
    static func decodeDisplayNames(_ json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8),
            let stored = try? JSONDecoder().decode([StoredNutrient].self, from: data)
        else { return [:] }
        var names: [String: String] = [:]
        for item in stored {
            guard let name = item.displayName, !name.isEmpty else { continue }
            names[item.id] = name
        }
        return names
    }

    /// Reads the stored values. An entry that cannot be read is left out, so it reads as unknown
    /// rather than as a number this build invented.
    static func decodeNutrients(_ json: String?) -> [String: NutrientValue] {
        guard let json, let data = json.data(using: .utf8),
            let stored = try? JSONDecoder().decode([StoredNutrient].self, from: data)
        else { return [:] }
        var values: [String: NutrientValue] = [:]
        for item in stored {
            switch item.state {
            case "known":
                guard let text = item.valueText, let amount = DecimalText.decode(text),
                    let symbol = item.unitSymbol, let unit = try? UnitRegistry.unit(for: symbol)
                else { continue }
                values[item.id] = .known(amount, unit)
            case "unknown":
                values[item.id] = .unknown
            case "notApplicable":
                values[item.id] = .notApplicable
            case "belowThreshold":
                if let symbol = item.unitSymbol, let unit = try? UnitRegistry.unit(for: symbol) {
                    values[item.id] = .belowReportingThreshold(unit)
                } else {
                    values[item.id] = .belowReportingThreshold(nil)
                }
            default:
                continue
            }
        }
        return values
    }

    private static func encode(_ components: [IntakeComponent]) throws -> String {
        var seen = Set<String>()
        var stored: [StoredComponent] = []
        for component in components {
            guard JournalValidation.isValidComponentID(component.componentID) else {
                throw JournalError.invalidComponentID(component.componentID)
            }
            guard seen.insert(component.componentID).inserted else {
                throw JournalError.duplicateComponentID(component.componentID)
            }
            guard !component.amount.isNaN else { throw JournalError.invalidAmount(component.componentID) }
            stored.append(StoredComponent(
                componentID: component.componentID, name: component.name,
                amountText: DecimalText.encode(component.amount), unitSymbol: component.unit.symbol))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stored)
        guard let text = String(data: data, encoding: .utf8) else { throw JournalError.corruptRecord("components") }
        return text
    }

    private static func decode(_ json: String) throws -> [IntakeComponent] {
        let stored = try JSONDecoder().decode([StoredComponent].self, from: Data(json.utf8))
        return try stored.map { item in
            guard let amount = DecimalText.decode(item.amountText) else {
                throw JournalError.invalidAmount(item.componentID)
            }
            return IntakeComponent(
                componentID: item.componentID, name: item.name, amount: amount,
                unit: try MeasureUnit(symbol: item.unitSymbol))
        }
    }

    /// FNV-1a over the UTF-8 bytes; a change detector, not a security hash.
    private static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
