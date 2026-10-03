import Foundation
import NutritionDomain

/// Whether an exported amount is a known decimal or a missing one. The journal stores a missing amount as
/// a not-a-number decimal, so the export says "unknown" instead of writing a 0 that would change the meaning.
public enum JournalExportValueState: String, Sendable, Hashable, Codable, CaseIterable {
    case known
    case unknown
}

/// One component of an exported revision. Amounts are exact decimal text, never binary floats.
public struct JournalExportComponent: Sendable, Hashable, Codable {
    public var componentID: String
    public var name: String
    /// Exact decimal text such as "40" or "37.5"; nil when the value state is unknown.
    public var amount: String?
    /// Unit symbol, for example "g" or "mL".
    public var unit: String
    public var valueState: JournalExportValueState

    enum CodingKeys: String, CodingKey {
        case componentID = "component_id"
        case name
        case amount
        case unit
        case valueState = "value_state"
    }

    public init(componentID: String, name: String, amount: String?, unit: String, valueState: JournalExportValueState) {
        self.componentID = componentID
        self.name = name
        self.amount = amount
        self.unit = unit
        self.valueState = valueState
    }

    public init(component: IntakeComponent) {
        self.componentID = component.componentID
        self.name = component.name
        self.unit = component.unit.symbol
        if component.amount.isNaN {
            self.amount = nil
            self.valueState = .unknown
        } else {
            self.amount = DecimalText.encode(component.amount)
            self.valueState = .known
        }
    }
}

/// Where the recorded amounts came from: the immutable product snapshot a revision points at.
public struct JournalExportProvenance: Sendable, Hashable, Codable {
    public var snapshotID: String
    public var productID: String
    public var name: String
    public var brand: String?
    public var barcode: String?
    public var labelBasis: String
    public var catalogOrigin: String
    public var catalogVersion: String

    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
        case productID = "product_id"
        case name
        case brand
        case barcode
        case labelBasis = "label_basis"
        case catalogOrigin = "catalog_origin"
        case catalogVersion = "catalog_version"
    }

    public init(
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

    public init(product: ProductDefinition) {
        self.init(
            snapshotID: product.snapshotID, productID: product.productID, name: product.name, brand: product.brand,
            barcode: product.barcode, labelBasis: product.labelBasis, catalogOrigin: product.catalogOrigin,
            catalogVersion: product.catalogVersion)
    }
}

/// One revision. Every revision of an intake is exported, not only the current one, so the history survives.
public struct JournalExportRevision: Sendable, Hashable, Codable {
    public var number: Int
    public var createdAt: Date
    public var changeReason: String
    public var productSnapshotID: String?
    public var provenance: JournalExportProvenance?
    public var components: [JournalExportComponent]

    enum CodingKeys: String, CodingKey {
        case number
        case createdAt = "created_at"
        case changeReason = "change_reason"
        case productSnapshotID = "product_snapshot_id"
        case provenance
        case components
    }

    public init(
        number: Int, createdAt: Date, changeReason: String, productSnapshotID: String?,
        provenance: JournalExportProvenance?, components: [JournalExportComponent]
    ) {
        self.number = number
        self.createdAt = createdAt
        self.changeReason = changeReason
        self.productSnapshotID = productSnapshotID
        self.provenance = provenance
        self.components = components
    }

    public init(revision: IntakeRevision, provenance: JournalExportProvenance?) {
        self.init(
            number: revision.number, createdAt: revision.createdAt, changeReason: revision.changeReason,
            productSnapshotID: revision.productSnapshotID, provenance: provenance,
            components: revision.components.map(JournalExportComponent.init(component:)))
    }
}

/// An active intake with its whole revision history.
public struct JournalExportIntake: Sendable, Hashable, Codable {
    public var id: String
    public var category: String
    public var occurredAt: Date
    public var timeZoneIdentifier: String
    public var meal: String?
    public var note: String?
    public var currentRevision: Int
    public var revisions: [JournalExportRevision]

    enum CodingKeys: String, CodingKey {
        case id
        case category
        case occurredAt = "occurred_at"
        case timeZoneIdentifier = "time_zone"
        case meal
        case note
        case currentRevision = "current_revision"
        case revisions
    }

    public init(
        id: String, category: String, occurredAt: Date, timeZoneIdentifier: String, meal: String?, note: String?,
        currentRevision: Int, revisions: [JournalExportRevision]
    ) {
        self.id = id
        self.category = category
        self.occurredAt = occurredAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.meal = meal
        self.note = note
        self.currentRevision = currentRevision
        self.revisions = revisions
    }
}

/// A deleted intake. The export keeps the tombstone so a later import can retract the entry instead of
/// leaving it behind as if it were still there.
public struct JournalExportTombstone: Sendable, Hashable, Codable {
    public var intakeID: String
    public var revision: Int
    public var occurredAt: Date
    public var timeZoneIdentifier: String

    enum CodingKeys: String, CodingKey {
        case intakeID = "intake_id"
        case revision
        case occurredAt = "occurred_at"
        case timeZoneIdentifier = "time_zone"
    }

    public init(intakeID: String, revision: Int, occurredAt: Date, timeZoneIdentifier: String) {
        self.intakeID = intakeID
        self.revision = revision
        self.occurredAt = occurredAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public init(intake: Intake) {
        self.init(
            intakeID: intake.id, revision: intake.currentRevision, occurredAt: intake.occurredAt,
            timeZoneIdentifier: intake.timeZoneIdentifier)
    }
}

/// A favorite, exported as the stored template it is, never as a link to an intake.
public struct JournalExportFavorite: Sendable, Hashable, Codable {
    public var id: String
    public var displayName: String
    public var category: String
    public var meal: String?
    public var productSnapshotID: String?
    public var components: [JournalExportComponent]

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case category
        case meal
        case productSnapshotID = "product_snapshot_id"
        case components
    }

    public init(
        id: String, displayName: String, category: String, meal: String?, productSnapshotID: String?,
        components: [JournalExportComponent]
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.meal = meal
        self.productSnapshotID = productSnapshotID
        self.components = components
    }

    public init(favorite: FavoriteTemplate) {
        self.init(
            id: favorite.id, displayName: favorite.displayName, category: favorite.category, meal: favorite.meal,
            productSnapshotID: favorite.productSnapshotID,
            components: favorite.components.map {
                JournalExportComponent(
                    componentID: $0.componentID, name: $0.name, amount: $0.amountText, unit: $0.unitSymbol,
                    valueState: .known)
            })
    }
}

/// The exported document, schema version 1. See `contracts/journal-export/v1.schema.json`.
///
/// A new field needs a new schema version: an existing version never gains or changes a field, so a reader
/// written against version 1 keeps working.
public struct JournalExport: Sendable, Hashable, Codable {
    /// The only schema version this build writes. Bump it when the shape changes.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var exportedAt: Date
    public var appVersion: String
    public var intakes: [JournalExportIntake]
    public var tombstones: [JournalExportTombstone]
    public var favorites: [JournalExportFavorite]
    /// Every product snapshot the document refers to, sorted by snapshot id. Revisions carry their own copy
    /// in `provenance`; this list is what lets a favorite outlive the intakes it came from, so a later import
    /// can repeat it without the catalog.
    public var products: [JournalExportProvenance]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case exportedAt = "exported_at"
        case appVersion = "app_version"
        case intakes
        case tombstones
        case favorites
        case products
    }

    public init(
        schemaVersion: Int = JournalExport.currentSchemaVersion, exportedAt: Date, appVersion: String,
        intakes: [JournalExportIntake], tombstones: [JournalExportTombstone], favorites: [JournalExportFavorite],
        products: [JournalExportProvenance] = []
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.intakes = intakes
        self.tombstones = tombstones
        self.favorites = favorites
        self.products = products
    }
}

public enum JournalExportError: Error, Sendable, Equatable {
    /// A revision points at a product snapshot the store no longer has.
    case missingProductSnapshot(String)
    /// The encoded bytes were not valid UTF-8 text.
    case notUTF8
    /// The document declares a schema version this build does not understand, so its fields are not read.
    case unsupportedSchemaVersion(Int)
}

/// One active intake with every one of its revisions, as read in a single pass.
public struct JournalExportIntakeSnapshot: Sendable {
    public var intake: Intake
    public var revisions: [IntakeRevision]

    public init(intake: Intake, revisions: [IntakeRevision]) {
        self.intake = intake
        self.revisions = revisions
    }
}

/// A consistent read of the whole journal: active intakes with their revisions, and deleted intakes, all as
/// of one moment.
public struct JournalSnapshot: Sendable {
    public var activeIntakes: [JournalExportIntakeSnapshot]
    public var deletedIntakes: [Intake]

    public init(activeIntakes: [JournalExportIntakeSnapshot], deletedIntakes: [Intake]) {
        self.activeIntakes = activeIntakes
        self.deletedIntakes = deletedIntakes
    }
}

/// A store that can read the journal in one pass. The exporter prefers this over separate list calls: an
/// entry deleted between two reads would otherwise be in neither the intakes nor the tombstones, and would
/// vanish from the backup without a trace.
public protocol JournalSnapshotSource: AnyObject, Sendable {
    /// Active intakes with all their revisions, plus deleted intakes, from one read.
    func readJournalSnapshot() throws -> JournalSnapshot
}

/// A store that also knows its deleted intakes. The SwiftData journal store keeps tombstones; a store that
/// cannot list them exports an empty tombstone list rather than pretending there is nothing deleted.
public protocol JournalTombstoneSource: AnyObject, Sendable {
    /// Deleted intakes, including their last revision.
    func deletedIntakes() throws -> [Intake]
}

/// Builds the export document and encodes it. No network and no upload: the bytes are handed back to the
/// caller, which may only pass them to the system share sheet or a file exporter the user opened.
public enum JournalExporter {
    /// Date stamp of the file name, in UTC so the name does not depend on where the export was made.
    public static let fileNameDateFormat = "yyyy-MM-dd-HHmmss"

    /// Reads the whole journal, its tombstones and the favorites, and builds the document.
    /// Collections are sorted by id so two runs over the same data produce the same document.
    ///
    /// A store that offers `readJournalSnapshot()` is read in one pass, so a deletion or an edit that lands
    /// mid-export cannot leave an entry in neither the intakes nor the tombstones.
    public static func makeExport(
        store: JournalStore, favorites: FavoritesStore? = nil, appVersion: String, exportedAt: Date
    ) throws -> JournalExport {
        let snapshot: JournalSnapshot?
        if let source = store as? JournalSnapshotSource {
            snapshot = try source.readJournalSnapshot()
        } else {
            snapshot = nil
        }
        let intakeSnapshots: [JournalExportIntakeSnapshot]
        let deletedIntakes: [Intake]
        if let snapshot {
            intakeSnapshots = snapshot.activeIntakes
            deletedIntakes = snapshot.deletedIntakes
        } else {
            // A store without a snapshot API is read call by call. Nothing can promise atomicity there, so
            // the journal store implements `JournalSnapshotSource` instead.
            var collected: [JournalExportIntakeSnapshot] = []
            for intake in try store.activeIntakes() where intake.lifecycle == .active {
                collected.append(
                    JournalExportIntakeSnapshot(intake: intake, revisions: try store.revisions(of: intake.id)))
            }
            intakeSnapshots = collected
            deletedIntakes = try (store as? JournalTombstoneSource)?.deletedIntakes() ?? []
        }

        // Every snapshot the document refers to, so a restore never has to ask the catalog for it.
        var productsByID: [String: JournalExportProvenance] = [:]
        var intakes: [JournalExportIntake] = []
        for item in intakeSnapshots {
            let intake = item.intake
            var revisions: [JournalExportRevision] = []
            for revision in item.revisions {
                var provenance: JournalExportProvenance?
                if let snapshotID = revision.productSnapshotID {
                    guard let product = try store.product(snapshotID: snapshotID) else {
                        throw JournalExportError.missingProductSnapshot(snapshotID)
                    }
                    let resolved = JournalExportProvenance(product: product)
                    provenance = resolved
                    productsByID[snapshotID] = resolved
                }
                revisions.append(JournalExportRevision(revision: revision, provenance: provenance))
            }
            intakes.append(
                JournalExportIntake(
                    id: intake.id, category: intake.category, occurredAt: intake.occurredAt,
                    timeZoneIdentifier: intake.timeZoneIdentifier, meal: intake.meal, note: intake.note,
                    currentRevision: intake.currentRevision, revisions: revisions))
        }
        var favoriteList: [JournalExportFavorite] = []
        if let favorites {
            favoriteList = try favorites.list().map { JournalExportFavorite(favorite: $0) }
            // A favorite keeps the product it was made from even when every intake that used it is deleted,
            // because repeating the favorite later needs the snapshot and not just the id.
            for favorite in favoriteList {
                guard let snapshotID = favorite.productSnapshotID else { continue }
                guard let product = try store.product(snapshotID: snapshotID) else {
                    throw JournalExportError.missingProductSnapshot(snapshotID)
                }
                productsByID[snapshotID] = JournalExportProvenance(product: product)
            }
        }
        return JournalExport(
            exportedAt: exportedAt, appVersion: appVersion,
            intakes: intakes.sorted { $0.id < $1.id },
            tombstones: deletedIntakes.map { JournalExportTombstone(intake: $0) }.sorted { $0.intakeID < $1.intakeID },
            favorites: favoriteList.sorted { $0.id < $1.id },
            products: productsByID.values.sorted { $0.snapshotID < $1.snapshotID })
    }

    /// Deterministic JSON: sorted keys and ISO-8601 dates with fractional seconds, so the same journal
    /// encodes to the same bytes and subsecond timestamps survive the round trip.
    public static func encode(_ export: JournalExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalISO8601.string(from: date))
        }
        return try encoder.encode(export)
    }

    /// The document as UTF-8 text, for a preview or a test.
    public static func json(_ export: JournalExport) throws -> String {
        let data = try encode(export)
        guard let text = String(data: data, encoding: .utf8) else { throw JournalExportError.notUTF8 }
        return text
    }

    /// Reads a document back, with the same date strategy the writer uses. Whole-second dates are still
    /// accepted, so a file written by an older build of this app imports cleanly.
    ///
    /// A document that declares another schema version is refused: this reader does not know what its extra
    /// or changed fields mean, and guessing would silently drop data.
    public static func decode(_ data: Data) throws -> JournalExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = fractionalISO8601.date(from: text) ?? wholeSecondISO8601.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not an ISO-8601 date: \(text)")
        }
        let document = try decoder.decode(JournalExport.self, from: data)
        guard document.schemaVersion == JournalExport.currentSchemaVersion else {
            throw JournalExportError.unsupportedSchemaVersion(document.schemaVersion)
        }
        return document
    }

    /// ISO-8601 in UTC with fractional seconds, the format `encode` writes.
    static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// Whole-second ISO-8601 in UTC, for reading documents written before fractional seconds were kept.
    static let wholeSecondISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// A file name such as `journal-export-2024-01-15-101500.json`.
    public static func fileName(exportedAt: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = fileNameDateFormat
        return "journal-export-\(formatter.string(from: exportedAt)).json"
    }
}