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

    /// Writes `amount` as an explicit `null` when it is missing. Synthesized encoding would leave the key out
    /// with `encodeIfPresent`, and the v1 schema marks `amount` as required-but-nullable.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(componentID, forKey: .componentID)
        try container.encode(name, forKey: .name)
        try encodeNullable(amount, forKey: .amount, in: &container)
        try container.encode(unit, forKey: .unit)
        try container.encode(valueState, forKey: .valueState)
    }
}

/// Encodes an optional as the value or as an explicit JSON `null`, never by leaving the key out.
func encodeNullable<T: Encodable, Key: CodingKey>(
    _ value: T?, forKey key: Key, in container: inout KeyedEncodingContainer<Key>
) throws {
    if let value {
        try container.encode(value, forKey: key)
    } else {
        try container.encodeNil(forKey: key)
    }
}

private let exportSchemaVersionKey = CodingUserInfoKey(rawValue: "journalExportSchemaVersion")!

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
    /// What kind of product this is. Version 2 requires it; version 1 defaults to food.
    public var kind: ProductKind

    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
        case productID = "product_id"
        case name
        case brand
        case barcode
        case labelBasis = "label_basis"
        case catalogOrigin = "catalog_origin"
        case catalogVersion = "catalog_version"
        case kind
    }

    public init(
        snapshotID: String, productID: String, name: String, brand: String?, barcode: String?,
        labelBasis: String, catalogOrigin: String, catalogVersion: String, kind: ProductKind = .food
    ) {
        self.snapshotID = snapshotID
        self.productID = productID
        self.name = name
        self.brand = brand
        self.barcode = barcode
        self.labelBasis = labelBasis
        self.catalogOrigin = catalogOrigin
        self.catalogVersion = catalogVersion
        self.kind = kind
    }

    /// Default the kind only for version 1; a missing or null version 2 kind is a decoding error.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind: ProductKind
        if (decoder.userInfo[exportSchemaVersionKey] as? Int ?? 1) >= 2 {
            kind = try container.decode(ProductKind.self, forKey: .kind)
        } else {
            kind = try container.decodeIfPresent(ProductKind.self, forKey: .kind) ?? .food
        }
        self.init(
            snapshotID: try container.decode(String.self, forKey: .snapshotID),
            productID: try container.decode(String.self, forKey: .productID),
            name: try container.decode(String.self, forKey: .name),
            brand: try container.decodeIfPresent(String.self, forKey: .brand),
            barcode: try container.decodeIfPresent(String.self, forKey: .barcode),
            labelBasis: try container.decode(String.self, forKey: .labelBasis),
            catalogOrigin: try container.decode(String.self, forKey: .catalogOrigin),
            catalogVersion: try container.decode(String.self, forKey: .catalogVersion),
            kind: kind)
    }

    public init(product: ProductDefinition) {
        self.init(
            snapshotID: product.snapshotID, productID: product.productID, name: product.name, brand: product.brand,
            barcode: product.barcode, labelBasis: product.labelBasis, catalogOrigin: product.catalogOrigin,
            catalogVersion: product.catalogVersion, kind: product.kind)
    }

    /// `brand` and `barcode` are required-but-nullable in the schema, so both are always written, as `null`
    /// when the product has neither. `kind` is written only for version 2 and later.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(snapshotID, forKey: .snapshotID)
        try container.encode(productID, forKey: .productID)
        try container.encode(name, forKey: .name)
        try encodeNullable(brand, forKey: .brand, in: &container)
        try encodeNullable(barcode, forKey: .barcode, in: &container)
        try container.encode(labelBasis, forKey: .labelBasis)
        try container.encode(catalogOrigin, forKey: .catalogOrigin)
        try container.encode(catalogVersion, forKey: .catalogVersion)
        if (encoder.userInfo[exportSchemaVersionKey] as? Int ?? JournalExport.currentSchemaVersion) >= 2 {
            try container.encode(kind, forKey: .kind)
        }
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

    /// `product_snapshot_id` and `provenance` are required-but-nullable in the schema, so an intake recorded
    /// by hand rather than from a product writes both as `null` instead of leaving them out.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(number, forKey: .number)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(changeReason, forKey: .changeReason)
        try encodeNullable(productSnapshotID, forKey: .productSnapshotID, in: &container)
        try encodeNullable(provenance, forKey: .provenance, in: &container)
        try container.encode(components, forKey: .components)
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

    /// `meal` and `note` are required-but-nullable in the schema, so an entry without them writes both as
    /// `null` rather than omitting the keys.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(category, forKey: .category)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try encodeNullable(meal, forKey: .meal, in: &container)
        try encodeNullable(note, forKey: .note, in: &container)
        try container.encode(currentRevision, forKey: .currentRevision)
        try container.encode(revisions, forKey: .revisions)
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

    /// A stored favorite holds decimal text that the favorites store does not itself validate. Writing a
    /// malformed or inexact amount as `value_state: known` would produce a document that cannot be restored.
    public init(favorite: FavoriteTemplate) throws {
        self.init(
            id: favorite.id, displayName: favorite.displayName, category: favorite.category, meal: favorite.meal,
            productSnapshotID: favorite.productSnapshotID,
            components: try favorite.components.map { component in
                guard DecimalText.isValidDecimalText(component.amountText),
                      DecimalText.decode(component.amountText) != nil else {
                    throw JournalExportError.malformedFavoriteAmount(favorite.id, component.amountText)
                }
                return JournalExportComponent(
                    componentID: component.componentID, name: component.name, amount: component.amountText,
                    unit: component.unitSymbol, valueState: .known)
            })
    }

    /// `meal` and `product_snapshot_id` are required-but-nullable in the schema and are always written.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(category, forKey: .category)
        try encodeNullable(meal, forKey: .meal, in: &container)
        try encodeNullable(productSnapshotID, forKey: .productSnapshotID, in: &container)
        try container.encode(components, forKey: .components)
    }
}

/// The exported document, schema version 2. See `contracts/journal-export/v2.schema.json`.
///
/// A new field needs a new schema version: an existing version never gains or changes a field, so a reader
/// written against version 1 keeps working. This build writes only version 2 and reads both, so a backup
/// taken before the product kind existed still restores.
public struct JournalExport: Sendable, Hashable, Codable {
    /// The only schema version this build writes. Bump it when the shape changes.
    public static let currentSchemaVersion = 2

    /// Every version this build reads, in the order they were written.
    ///
    /// Version 1 is here because its documents are still backups people hold: it has no product kind and
    /// nothing else this build cannot read, so a reader that refused it would refuse a person's own
    /// backup. Anything outside this set is refused by value rather than by shape.
    public static let readableSchemaVersions: Set<Int> = [1, currentSchemaVersion]

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
    /// A stored favorite holds an amount that is not exact decimal text, which the schema cannot express.
    case malformedFavoriteAmount(String, String)
    /// A revision with no components cannot be restored under the journal export contract.
    case emptyRevisionComponents(String, Int)
    /// An active intake without any revision history cannot be restored under the journal export contract.
    case emptyRevisionHistory(String)
    /// A date in the document cannot be represented as a finite timestamp.
    case nonFiniteDate
    /// A finite timestamp falls outside the four-digit UTC date format this export writes.
    case unrepresentableDate
    /// A stored value is empty where the journal export schema requires a nonempty string.
    case emptyRequiredField(String)
    /// A favorite uses a unit the importer cannot restore; the field path is safe to show in diagnostics.
    case unknownFavoriteUnit(String)
}

private func requireExportText(_ text: String, field: String) throws {
    guard !text.isEmpty else { throw JournalExportError.emptyRequiredField(field) }
}

private func validateExportProvenance(_ provenance: JournalExportProvenance, path: String) throws {
    try requireExportText(provenance.snapshotID, field: "\(path).snapshot_id")
    try requireExportText(provenance.productID, field: "\(path).product_id")
    try requireExportText(provenance.name, field: "\(path).name")
    try requireExportText(provenance.labelBasis, field: "\(path).label_basis")
    try requireExportText(provenance.catalogOrigin, field: "\(path).catalog_origin")
    try requireExportText(provenance.catalogVersion, field: "\(path).catalog_version")
}

private func validateExportRequiredFields(_ document: JournalExport) throws {
    try requireExportText(document.appVersion, field: "app_version")
    for (index, intake) in document.intakes.enumerated() {
        let path = "intakes[\(index)]"
        try requireExportText(intake.category, field: "\(path).category")
        try requireExportText(intake.timeZoneIdentifier, field: "\(path).time_zone")
        guard !intake.revisions.isEmpty else {
            throw JournalExportError.emptyRevisionHistory(intake.id)
        }
        for (revisionIndex, revision) in intake.revisions.enumerated() {
            guard !revision.components.isEmpty else {
                throw JournalExportError.emptyRevisionComponents(intake.id, revision.number)
            }
            if let provenance = revision.provenance {
                try validateExportProvenance(provenance, path: "\(path).revisions[\(revisionIndex)].provenance")
            }
        }
    }
    for (index, tombstone) in document.tombstones.enumerated() {
        try requireExportText(tombstone.timeZoneIdentifier, field: "tombstones[\(index)].time_zone")
    }
    for (index, favorite) in document.favorites.enumerated() {
        let path = "favorites[\(index)]"
        try requireExportText(favorite.id, field: "\(path).id")
        try requireExportText(favorite.displayName, field: "\(path).display_name")
        try requireExportText(favorite.category, field: "\(path).category")
        for (componentIndex, component) in favorite.components.enumerated() {
            let field = "\(path).components[\(componentIndex)].unit"
            try requireExportText(component.unit, field: field)
            guard (try? MeasureUnit(symbol: component.unit)) != nil else {
                throw JournalExportError.unknownFavoriteUnit(field)
            }
        }
    }
    for (index, product) in document.products.enumerated() {
        try validateExportProvenance(product, path: "products[\(index)]")
    }
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
                guard !revision.components.isEmpty else {
                    throw JournalExportError.emptyRevisionComponents(intake.id, revision.number)
                }
                var provenance: JournalExportProvenance?
                if let snapshotID = revision.productSnapshotID {
                    // A snapshot is immutable, so one that is already resolved needs no second query. A long
                    // journal that keeps using the same product would otherwise cost one fetch per revision.
                    let resolved: JournalExportProvenance
                    if let cached = productsByID[snapshotID] {
                        resolved = cached
                    } else {
                        guard let product = try store.product(snapshotID: snapshotID) else {
                            throw JournalExportError.missingProductSnapshot(snapshotID)
                        }
                        resolved = JournalExportProvenance(product: product)
                        productsByID[snapshotID] = resolved
                    }
                    provenance = resolved
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
            favoriteList = try favorites.list().map { try JournalExportFavorite(favorite: $0) }
            // A favorite keeps the product it was made from even when every intake that used it is deleted,
            // because repeating the favorite later needs the snapshot and not just the id.
            for favorite in favoriteList {
                guard let snapshotID = favorite.productSnapshotID, productsByID[snapshotID] == nil else { continue }
                guard let product = try store.product(snapshotID: snapshotID) else {
                    throw JournalExportError.missingProductSnapshot(snapshotID)
                }
                productsByID[snapshotID] = JournalExportProvenance(product: product)
            }
        }
        let document = JournalExport(
            exportedAt: exportedAt, appVersion: appVersion,
            intakes: intakes.sorted { $0.id < $1.id },
            tombstones: deletedIntakes.map { JournalExportTombstone(intake: $0) }.sorted { $0.intakeID < $1.intakeID },
            // Favorites are sorted by id so two runs over the same favorites produce the same bytes: the favorites
            // store lists newest first, which would otherwise make the order depend on when things were added.
            favorites: favoriteList.sorted { $0.id < $1.id },
            products: productsByID.values.sorted { $0.snapshotID < $1.snapshotID })
        try validateExportRequiredFields(document)
        return document
    }

    /// Deterministic JSON: sorted keys and ISO-8601 dates with microsecond precision, so the same journal
    /// encodes to the same bytes and no timestamp is rounded on its way out.
    public static func encode(_ export: JournalExport) throws -> Data {
        try validateExportRequiredFields(export)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.userInfo[exportSchemaVersionKey] = export.schemaVersion
        // One formatter for the whole run: building a `DateFormatter` is the expensive part of formatting a
        // date, and encoding is synchronous on the calling thread, so this one is only ever used here.
        let formatter = dateFormatter()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(microsecondText(from: date, using: formatter))
        }
        return try encoder.encode(export)
    }

    /// The document as UTF-8 text, for a preview or a test.
    public static func json(_ export: JournalExport) throws -> String {
        let data = try encode(export)
        guard let text = String(data: data, encoding: .utf8) else { throw JournalExportError.notUTF8 }
        return text
    }

    /// Reads a document back, with the same date strategy the writer uses. Millisecond and whole-second dates
    /// are still accepted, so a file written by an earlier build of this app imports cleanly.
    ///
    /// A document that declares a version outside `readableSchemaVersions` is refused: this reader does
    /// not know what its extra or changed fields mean, and guessing would silently drop data.
    public static func decode(_ data: Data) throws -> JournalExport {
        let decoder = JSONDecoder()
        struct VersionHeader: Decodable {
            let schema_version: Int
        }
        let version = try JSONDecoder().decode(VersionHeader.self, from: data).schema_version
        guard JournalExport.readableSchemaVersions.contains(version) else {
            throw JournalExportError.unsupportedSchemaVersion(version)
        }
        decoder.userInfo[exportSchemaVersionKey] = version
        // One set of readers for the whole run; see `encode` for why they are not rebuilt per date.
        let formatter = dateFormatter()
        let fallback = wholeSecondFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = date(
                fromExportedText: text, schemaVersion: version, using: formatter, fallback: fallback
            ) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not an ISO-8601 date: \(text)")
        }
        let document = try decoder.decode(JournalExport.self, from: data)
        guard JournalExport.readableSchemaVersions.contains(document.schemaVersion) else {
            throw JournalExportError.unsupportedSchemaVersion(document.schemaVersion)
        }
        return document
    }

    /// The whole-second part of an exported date, in UTC. The fractional part is written and read by this
    /// module rather than by the formatter.
    public static let secondsDateFormat = "yyyy-MM-dd'T'HH:mm:ss"

    /// Builds the one `DateFormatter` a run of `encode` or `decode` uses. Building a formatter is the expensive
    /// part of formatting a date, so a run builds one and reuses it; encoding and decoding are synchronous on
    /// the calling thread, so nothing else can reach it.
    ///
    /// This is a seam so a test can count the formatters a run builds. Production code never assigns it.
    nonisolated(unsafe) public static var dateFormatter: () -> DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = secondsDateFormat
        return formatter
    }

    /// Whole-second ISO-8601 in UTC, used as a fallback for text that carries a zone offset rather than a `Z`,
    /// which this module never writes but another writer might.
    static func wholeSecondFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    /// An exported date as ISO-8601 in UTC with exactly six fractional digits, for example
    /// `2024-01-14T20:30:00.123400Z`.
    ///
    /// The six digits are computed here rather than asked of the formatter. `DateFormatter` only ever writes
    /// three fractional digits, no matter how many `S` the format string has, and `ISO8601DateFormatter`'s
    /// `.withFractionalSeconds` does the same, so both would round a timestamp to the nearest millisecond and
    /// could move two entries onto the same instant. A `Date` is a floating-point count of seconds, and an
    /// epoch value near 1.7e9 spends ten of its sixteen significant decimal digits on the whole seconds, so six
    /// fractional digits is the finest text that still parses back to the same instant. The schema describes the
    /// dates as `format: date-time`, which RFC 3339 allows at any fractional length.
    static func microsecondText(from date: Date, using formatter: DateFormatter) throws -> String {
        let interval = date.timeIntervalSince1970
        guard interval.isFinite else { throw JournalExportError.nonFiniteDate }
        let whole = interval.rounded(.down)
        // This export's existing contract floors seconds and rounds the positive remainder, so exact
        // negative half-microseconds round toward positive infinity (for example, -0.5 μs becomes epoch).
        var microseconds = Int(((interval - whole) * 1_000_000).rounded())
        var seconds = whole
        if microseconds >= 1_000_000 {
            // Rounding up out of the fraction carries into the next second.
            microseconds -= 1_000_000
            seconds += 1
        }
        let digits = String(format: "%06d", microseconds)
        let secondDate = Date(timeIntervalSince1970: seconds)
        guard seconds.isFinite, seconds >= earliestLegacyExportableUTCSecond,
              seconds <= latestExportableUTCSecond else {
            throw JournalExportError.unrepresentableDate
        }
        let formatted = formatter.string(from: secondDate)
        // Versions 1 and 2 wrote Foundation's historical Julian/Gregorian calendar text. Keep doing so
        // while those versions remain current, or a backup made before the cutover would restore to a
        // different instant. The round-trip also prevents Foundation from normalizing an unrepresentable
        // calendar date at the year boundaries.
        guard let legacyDate = legacyUTCDate(fromWholeSecondText: formatted, using: formatter),
              legacyDate.timeIntervalSince1970 == seconds else {
            throw JournalExportError.unrepresentableDate
        }
        return "\(formatted).\(digits)Z"
    }

    /// Reads back fractional dates from earlier builds and other RFC-3339 writers. Fractions are converted
    /// with a bounded decimal accumulator, while leading zeroes do not consume the significant-digit bound.
    static func date(
        fromExportedText text: String,
        schemaVersion: Int,
        using formatter: DateFormatter,
        fallback: ISO8601DateFormatter
    ) -> Date? {
        guard hasSupportedFourDigitYearPrefix(text) else { return nil }
        let dot = text.firstIndex(of: ".")
        let digits: Substring?
        let secondsText: String
        if let dot {
            let zoneStart = text[text.index(after: dot)...].firstIndex {
                $0 == "Z" || $0 == "z" || $0 == "+" || $0 == "-"
            }
            guard let zoneStart else { return nil }
            let fractionEnd = zoneStart
            let fraction = text[text.index(after: dot)..<fractionEnd]
            guard !fraction.isEmpty, fraction.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            digits = fraction
            let zone = String(text[zoneStart...])
            guard isValidRFC3339Zone(zone) else { return nil }
            secondsText = String(text[..<dot]) + zone
        } else {
            guard text.count > 19 else { return nil }
            let zoneStart = text.index(text.startIndex, offsetBy: 19)
            guard isValidRFC3339Zone(String(text[zoneStart...])) else { return nil }
            digits = nil
            secondsText = text
        }

        let seconds: Date
        if hasCanonicalISOWholeSecondShape(secondsText) {
            // V1/v2 backups were written and read with Foundation's historical Julian/Gregorian calendar.
            // Keep that meaning for the schemas people already hold, while requiring a formatter round-trip
            // so invalid or normalized calendar dates are still refused.
            if (1...2).contains(schemaVersion), (secondsText.hasSuffix("Z") || secondsText.hasSuffix("z")) {
                guard let parsed = legacyUTCDate(
                    fromWholeSecondText: String(secondsText.dropLast()), using: formatter) else { return nil }
                seconds = parsed
            } else {
                // A canonical four-digit timestamp that fails strict Gregorian parsing is invalid. Do not
                // let DateFormatter normalize it (for example, February 29 in a non-leap Gregorian year).
                guard let parsed = prolepticUTCDate(fromWholeSecondText: secondsText) else { return nil }
                seconds = parsed
            }
        } else {
            guard let parsed = formatter.date(from: secondsText) ?? fallback.date(from: secondsText) else {
                return nil
            }
            seconds = parsed
        }

        let earliest = (1...2).contains(schemaVersion)
            ? earliestLegacyExportableUTCSecond
            : earliestExportableUTCSecond
        guard let digits else { return finiteDate(seconds, earliest: earliest) }

        // All digits were validated above. Once the binary place underflows to zero, later
        // fractional digits cannot affect the representable TimeInterval, so very long valid
        // fractions remain compatible without an unbounded numeric-conversion loop.
        var scaled: TimeInterval = 0
        var place: TimeInterval = 0.1 // Date fractional seconds use TimeInterval. // lint-allow: binary-float
        for character in digits {
            if place == 0 { break }
            let digit = TimeInterval(character.wholeNumberValue!)
            scaled += digit * place
            place /= 10
        }
        return finiteDate(seconds.addingTimeInterval(scaled), earliest: earliest)
    }

    /// Parses a whole-second UTC date using Foundation's historic Gregorian cutover. Exact formatting back
    /// to the same text rejects values Foundation would otherwise normalize, including the skipped 1582 days.
    private static func legacyUTCDate(fromWholeSecondText text: String, using formatter: DateFormatter) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count == 19, bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
              bytes[13] == 58, bytes[16] == 58,
              (0..<4).allSatisfy({ (48...57).contains(bytes[$0]) }),
              (0..<4).contains(where: { bytes[$0] != 48 }) else { return nil }
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date.timeIntervalSince1970.isFinite ? date : nil
    }

    private static func isValidRFC3339Zone(_ zone: String) -> Bool {
        if zone == "Z" || zone == "z" { return true }
        let bytes = Array(zone.utf8)
        guard bytes.count == 6, bytes[0] == 43 || bytes[0] == 45, bytes[3] == 58,
              [1, 2, 4, 5].allSatisfy({ (48...57).contains(bytes[$0]) }) else { return false }
        let hour = Int(bytes[1] - 48) * 10 + Int(bytes[2] - 48)
        let minute = Int(bytes[4] - 48) * 10 + Int(bytes[5] - 48)
        return hour <= 23 && minute <= 59
    }

    private static func finiteDate(_ date: Date?, earliest: TimeInterval = earliestExportableUTCSecond) -> Date? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince1970
        guard interval.isFinite else { return nil }
        let whole = interval.rounded(.down)
        let microseconds = ((interval - whole) * 1_000_000).rounded()
        let exportedSecond = microseconds >= 1_000_000 ? whole + 1 : whole
        guard exportedSecond >= earliest,
              exportedSecond <= latestExportableUTCSecond else { return nil }
        return date
    }

    private static func hasCanonicalISOWholeSecondShape(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (bytes.count == 20 || bytes.count == 25),
              bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
              bytes[13] == 58, bytes[16] == 58,
              [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
                .allSatisfy({ (48...57).contains(bytes[$0]) }) else { return false }
        if bytes.count == 20 { return bytes[19] == 90 || bytes[19] == 122 }
        return (bytes[19] == 43 || bytes[19] == 45) && bytes[22] == 58
            && (48...57).contains(bytes[20]) && (48...57).contains(bytes[21])
            && (48...57).contains(bytes[23]) && (48...57).contains(bytes[24])
    }

    private static func hasSupportedFourDigitYearPrefix(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count >= 5, bytes[4] == 45,
              (0..<4).allSatisfy({ (48...57).contains(bytes[$0]) }) else { return false }
        return bytes[0..<4].contains(where: { $0 != 48 })
    }

    private static func prolepticUTCDate(fromWholeSecondText text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count == 20 || bytes.count == 25,
              bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
              bytes[13] == 58, bytes[16] == 58 else { return nil }
        let digitPositions = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
        guard digitPositions.allSatisfy({ (48...57).contains(bytes[$0]) }) else { return nil }
        func number(_ start: Int, _ count: Int) -> Int {
            bytes[start..<(start + count)].reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        let year = number(0, 4)
        let month = number(5, 2)
        let day = number(8, 2)
        let hour = number(11, 2)
        let minute = number(14, 2)
        let second = number(17, 2)
        guard (1...9_999).contains(year), (1...12).contains(month),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let daysInMonth = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...daysInMonth[month - 1]).contains(day) else { return nil }

        var offset = 0
        if bytes.count == 20 {
            guard bytes[19] == 90 || bytes[19] == 122 else { return nil }
        } else {
            guard (bytes[19] == 43 || bytes[19] == 45), bytes[22] == 58,
                  (48...57).contains(bytes[20]), (48...57).contains(bytes[21]),
                  (48...57).contains(bytes[23]), (48...57).contains(bytes[24]) else { return nil }
            let offsetHour = number(20, 2)
            let offsetMinute = number(23, 2)
            guard (0...23).contains(offsetHour), (0...59).contains(offsetMinute) else { return nil }
            let sign = bytes[19] == 43 ? 1 : -1
            offset = sign * (offsetHour * 3_600 + offsetMinute * 60)
        }

        // Inverse of the proleptic-Gregorian day conversion used by the writer.
        var adjustedYear = year
        adjustedYear -= month <= 2 ? 1 : 0
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let daysSinceEpoch = era * 146_097 + dayOfEra - 719_468
        let localSeconds = daysSinceEpoch * 86_400 + hour * 3_600 + minute * 60 + second
        return Date(timeIntervalSince1970: TimeInterval(localSeconds - offset))
    }

    private static let earliestExportableUTCSecond = -62_135_596_800.0 // Proleptic 0001-01-01T00:00:00Z. // lint-allow: binary-float
    private static let earliestLegacyExportableUTCSecond = -62_135_769_600.0 // Julian 0001-01-01T00:00:00Z. // lint-allow: binary-float
    private static let latestExportableUTCSecond = 253_402_300_799.0 // 9999-12-31T23:59:59Z; Date boundary uses TimeInterval. // lint-allow: binary-float

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
