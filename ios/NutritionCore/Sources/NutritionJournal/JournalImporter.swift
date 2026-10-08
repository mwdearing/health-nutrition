import Foundation
import NutritionDomain

/// Why an import did not happen. Every case is a refusal: the importer never leaves a journal half
/// restored, so anything it cannot do as a whole it does not do at all.
public enum JournalImportError: Error, Sendable, Equatable {
    /// The document declares a schema version this build does not read. Its fields are not guessed at.
    case unsupportedVersion
    /// The store already holds intakes, active or deleted. This version restores into an empty journal
    /// only; it does not merge one journal into another.
    case notEmpty
    /// The bytes are not a journal export at all: not JSON, or not the shape the schema describes.
    case malformed(String)
    /// The file is a version 1 export that cannot be restored as it stands: a snapshot nothing defines,
    /// a revision history that does not line up, an amount that is not exact decimal text.
    case corrupt(String)
}

/// What one import wrote. Counts, not content: the journal itself is the record of what was restored.
public struct JournalImportSummary: Sendable, Equatable {
    /// Active intakes written.
    public var intakes: Int
    /// Revisions written across all of them.
    public var revisions: Int
    /// Deleted intakes written back as tombstones.
    public var tombstones: Int
    /// Favorites written.
    public var favorites: Int
    /// Product snapshots written, so a restored entry needs no catalog lookup.
    public var products: Int

    public init(intakes: Int, revisions: Int, tombstones: Int, favorites: Int, products: Int) {
        self.intakes = intakes
        self.revisions = revisions
        self.tombstones = tombstones
        self.favorites = favorites
        self.products = products
    }
}

extension ProductDefinition {
    /// The product snapshot an export describes.
    ///
    /// The document carries the identity of the product, where it came from and what kind of product it
    /// is, but not the nutrient values it states, so a snapshot built from one states none. The kind
    /// comes across as the document states it, and a version 1 document — which has no kind at all —
    /// reads as the food that every product in it was.
    ///
    /// Where the store already knows the snapshot, its values are kept instead; see
    /// `SwiftDataJournalStore.restoreSnapshot`.
    init(provenance: JournalExportProvenance) {
        self.init(
            snapshotID: provenance.snapshotID, productID: provenance.productID, name: provenance.name,
            brand: provenance.brand, barcode: provenance.barcode, labelBasis: provenance.labelBasis,
            catalogOrigin: provenance.catalogOrigin, catalogVersion: provenance.catalogVersion,
            kind: provenance.kind)
    }
}

/// The keys each object in a version 1 export has, taken from `contracts/journal-export/v1.schema.json`.
///
/// Every object the v1 schema defines lists all of its properties in `required` and forbids any other
/// through `additionalProperties: false`, so one set per object is both the required list and the allowed
/// list. A test holds these sets to the committed schema, so they cannot drift from the contract.
///
/// The schema version is checked separately: `readDocument` has already turned a version spelled as text
/// into the number the export writes, and the constant is compared there.
enum JournalImportV1Keys {
    static let root: Set<String> = [
        "schema_version", "exported_at", "app_version", "intakes", "tombstones", "favorites", "products",
    ]
    static let intake: Set<String> = [
        "id", "category", "occurred_at", "time_zone", "meal", "note", "current_revision", "revisions",
    ]
    static let revision: Set<String> = [
        "number", "created_at", "change_reason", "product_snapshot_id", "provenance", "components",
    ]
    static let provenance: Set<String> = [
        "snapshot_id", "product_id", "name", "brand", "barcode", "label_basis", "catalog_origin",
        "catalog_version",
    ]
    static let component: Set<String> = ["component_id", "name", "amount", "unit", "value_state"]
    static let tombstone: Set<String> = ["intake_id", "revision", "occurred_at", "time_zone"]
    static let favorite: Set<String> = [
        "id", "display_name", "category", "meal", "product_snapshot_id", "components",
    ]
}

/// The keys each object in a version 2 export has, taken from `contracts/journal-export/v2.schema.json`.
///
/// Version 2 is version 1 with one field: a product's `kind`. Every other object is unchanged, so the
/// sets are the version 1 sets taken again, and the one that differs is the provenance.
enum JournalImportV2Keys {
    static let root = JournalImportV1Keys.root
    static let intake = JournalImportV1Keys.intake
    static let revision = JournalImportV1Keys.revision
    static let provenance: Set<String> = JournalImportV1Keys.provenance.union(["kind"])
    static let component = JournalImportV1Keys.component
    static let tombstone = JournalImportV1Keys.tombstone
    static let favorite = JournalImportV1Keys.favorite
}

/// Restores a journal export into an empty journal: the entries with their whole revision history, the
/// tombstones of deleted entries and the favorites.
///
/// An imported entry is history, not something new to deliver, so an import writes no outbox operation
/// and no projection: sending yesterday's breakfast to Health again because a phone was replaced would
/// be a delivery, and this is not one. The ids, the timestamps and the revision numbers are the ones the
/// file carries, so a restore does not renumber anything or move an entry to a new instant.
public enum JournalImporter {
    /// Reads `data` and writes it into `store`, and into `favorites` when the document needs them.
    ///
    /// The whole document is read and checked before the first row is written, so a file that is malformed,
    /// from a version this build does not read, or internally inconsistent changes nothing.
    ///
    /// The journal is written first, in one save that queues no delivery work, and the favorites after it.
    /// That order is what makes the import all-or-nothing: the journal is the larger write and the one that
    /// can be put back, so when the favorites write fails afterwards the journal is emptied again and the
    /// import reports a failure with both stores as it found them.
    public static func importExport(
        _ data: Data, into store: JournalStore, favorites: FavoritesStore?
    ) throws -> JournalImportSummary {
        let document = try readDocument(data)
        let plan = try makePlan(document)
        guard let journal = store as? JournalRestoreTarget else {
            throw JournalImportError.corrupt("this journal store cannot be restored into")
        }
        // A document that carries favorites needs somewhere to put them. The favorites store is optional and
        // the screen can be built without one, so this is refused before anything is written rather than
        // reported as a success that quietly dropped them.
        let favoritesTarget: FavoritesRestoreTarget?
        if plan.favorites.isEmpty {
            favoritesTarget = nil
        } else {
            guard let favorites, let target = favorites as? FavoritesRestoreTarget else {
                throw JournalImportError.corrupt(
                    "the export carries \(plan.favorites.count) favorites and no favorites store was given")
            }
            favoritesTarget = target
        }

        // The store refuses a journal that is not empty, and refuses it from inside this same transaction,
        // so the check and the inserts cannot be pulled apart by another write.
        let receipt = try journal.restore(plan)
        if let favoritesTarget {
            do {
                try favoritesTarget.restore(plan.favorites)
            } catch {
                let failure = error
                do {
                    try journal.undoRestore(receipt)
                } catch {
                    throw JournalImportError.corrupt(
                        "the favorites could not be restored (\(failure)) and the journal could not be put "
                            + "back either (\(error))")
                }
                throw failure
            }
        }
        return JournalImportSummary(
            intakes: plan.entries.count,
            revisions: plan.entries.reduce(0) { $0 + $1.revisions.count },
            tombstones: plan.tombstones.count,
            favorites: plan.favorites.count,
            products: plan.products.count)
    }

    // MARK: Reading

    /// The document, after the version has been checked by hand.
    ///
    /// The version is read from the raw JSON first, so a file from a newer build is refused as such even
    /// when its other fields would not decode. Refusing by version rather than by shape is the whole
    /// point of `schema_version`: a reader that does not know what a field means would otherwise hand
    /// back a journal with parts of it silently dropped.
    static func readDocument(_ data: Data) throws -> JournalExport {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw JournalImportError.malformed("the file is not a JSON object")
        }
        guard let declared = schemaVersion(in: root),
              JournalExport.readableSchemaVersions.contains(declared)
        else {
            throw JournalImportError.unsupportedVersion
        }
        var bytes = data
        if root["schema_version"] is String {
            // A file that spells the version as "1" names a version this build reads, so only the
            // spelling differs. The decoder wants the number the export writes, so that one field is set
            // to it and the document is decoded from that.
            root["schema_version"] = declared
            guard let rewritten = try? JSONSerialization.data(withJSONObject: root) else {
                throw JournalImportError.malformed("the file could not be read again after its version was checked")
            }
            bytes = rewritten
        }
        // The shape is checked before anything is decoded, because a decoder cannot see either kind of
        // difference: it ignores a key the schema does not define, and it reads a required-but-nullable key
        // that is absent the same as one written as an explicit null. A file that breaks the contract is a
        // malformed file, refused here rather than half-understood below.
        try validateShape(root, version: declared)
        do {
            return try JournalExporter.decode(bytes)
        } catch {
            // The version and the shape are already known to be this build's, so whatever the decoder
            // objected to now is a value rather than the document's structure.
            throw JournalImportError.malformed("\(error)")
        }
    }

    /// Checks a document against the key rules the schema of the version it declares states, at every
    /// level that schema defines.
    ///
    /// Every object must carry exactly the keys its shape defines: no unknown key, because a reader that
    /// does not know what a field means drops it and the next export writes the file without it; and no
    /// missing key, because a required-but-nullable one that is absent is a document the schema does not
    /// describe, even though it decodes to the same value.
    ///
    /// The version decides the sets, and it is the whole of what it decides: version 2 is version 1 with
    /// `kind` added to a provenance, so a version 1 document is still a document this build reads, and a
    /// `kind` in one is as unknown a key as any other.
    static func validateShape(_ root: [String: Any], version: Int) throws {
        let provenanceKeys = version >= 2 ? JournalImportV2Keys.provenance : JournalImportV1Keys.provenance
        try checkObject(root, keys: JournalImportV1Keys.root, path: "$", version: version)
        for (index, item) in try objects(root["intakes"], path: "$.intakes").enumerated() {
            let path = "$.intakes[\(index)]"
            let intake = try object(item, path: path)
            try checkObject(intake, keys: JournalImportV1Keys.intake, path: path, version: version)
            let revisionList = try objects(intake["revisions"], path: "\(path).revisions")
            for (revisionIndex, revisionItem) in revisionList.enumerated() {
                let revisionPath = "\(path).revisions[\(revisionIndex)]"
                let revision = try object(revisionItem, path: revisionPath)
                try checkObject(revision, keys: JournalImportV1Keys.revision, path: revisionPath, version: version)
                if let provenance = revision["provenance"], !(provenance is NSNull) {
                    let provenancePath = "\(revisionPath).provenance"
                    try checkObject(
                        try object(provenance, path: provenancePath),
                        keys: provenanceKeys, path: provenancePath, version: version)
                }
                try checkComponents(revision["components"], path: "\(revisionPath).components", version: version)
            }
        }
        let tombstoneList = try objects(root["tombstones"], path: "$.tombstones")
        for (index, item) in tombstoneList.enumerated() {
            let path = "$.tombstones[\(index)]"
            try checkObject(
                try object(item, path: path), keys: JournalImportV1Keys.tombstone, path: path, version: version)
        }
        let favoriteList = try objects(root["favorites"], path: "$.favorites")
        for (index, item) in favoriteList.enumerated() {
            let path = "$.favorites[\(index)]"
            let favorite = try object(item, path: path)
            try checkObject(favorite, keys: JournalImportV1Keys.favorite, path: path, version: version)
            try checkComponents(favorite["components"], path: "\(path).components", version: version)
        }
        let productList = try objects(root["products"], path: "$.products")
        for (index, item) in productList.enumerated() {
            let path = "$.products[\(index)]"
            try checkObject(
                try object(item, path: path), keys: provenanceKeys, path: path, version: version)
        }
    }

    private static func checkComponents(_ value: Any?, path: String, version: Int) throws {
        let list = try objects(value, path: path)
        for (index, item) in list.enumerated() {
            let componentPath = "\(path)[\(index)]"
            try checkObject(
                try object(item, path: componentPath), keys: JournalImportV1Keys.component, path: componentPath,
                version: version)
        }
    }

    /// One list, whose every item is an object. The items are checked here so that a list holding a string
    /// or a number is refused as the wrong shape rather than read as an object with no keys.
    private static func objects(_ value: Any?, path: String) throws -> [Any] {
        guard let list = value as? [Any] else {
            throw JournalImportError.malformed("\(path) is not a list")
        }
        for (index, item) in list.enumerated() where !(item is [String: Any]) {
            throw JournalImportError.malformed("\(path)[\(index)] is not an object")
        }
        return list
    }

    private static func object(_ value: Any, path: String) throws -> [String: Any] {
        guard let fields = value as? [String: Any] else {
            throw JournalImportError.malformed("\(path) is not an object")
        }
        return fields
    }

    /// The keys of one object, against the keys its shape defines. They are walked in order, so the message
    /// names the first one that is wrong rather than whichever the dictionary happened to hash to. The
    /// version it was checked against is named in the message, because "a key this build does not know"
    /// is a different thing in a version 1 document and in a version 2 one.
    private static func checkObject(
        _ fields: [String: Any], keys: Set<String>, path: String, version: Int
    ) throws {
        for key in fields.keys.sorted() where !keys.contains(key) {
            throw JournalImportError.malformed(
                "\(path) has \(key), which the version \(version) schema does not define")
        }
        // An explicit null is a value, so a required-but-nullable key written as null is present. Only a key
        // that is not there at all is refused.
        for key in keys.sorted() where fields[key] == nil {
            throw JournalImportError.malformed(
                "\(path) is missing \(key), which the version \(version) schema requires")
        }
    }

    /// The version the document declares, or nil when it does not declare one this build can read. The
    /// export writes the number 1; a file that spells the same version as `"1"` is accepted, and anything
    /// else, a missing key included, is refused rather than assumed to be this build's own.
    static func schemaVersion(in root: [String: Any]) -> Int? {
        guard let raw = root["schema_version"] else { return nil }
        if let number = raw as? Int { return number }
        if let text = raw as? String { return Int(text) }
        return nil
    }

    // MARK: Checking

    /// The whole document as the rows to write, checked. Nothing is written while this runs, so the first
    /// problem it finds leaves the journal exactly as it was.
    static func makePlan(_ document: JournalExport) throws -> JournalRestorePlan {
        var productsByID = try productIndex(document.products)

        var seenIntakeIDs = Set<String>()
        var entries: [JournalRestoreEntry] = []
        for exported in document.intakes {
            guard JournalValidation.isValidIntakeID(exported.id) else {
                throw JournalImportError.corrupt("\(exported.id) is not an intake id")
            }
            guard seenIntakeIDs.insert(exported.id).inserted else {
                throw JournalImportError.corrupt("the export lists \(exported.id) twice")
            }
            // A revision repeats the snapshot it used, so a file that carries one can be restored even if
            // its products list was trimmed. The provenance has to be the provenance of the snapshot the
            // revision names: a file that points at snapshot A and describes snapshot B is saying two
            // things at once, and honouring either of them alone would attach the wrong product to the
            // entry and quietly drop the other on the next export.
            for revision in exported.revisions {
                guard let provenance = revision.provenance else { continue }
                guard provenance.snapshotID == revision.productSnapshotID else {
                    throw JournalImportError.corrupt(
                        "revision \(revision.number) of \(exported.id) uses the product snapshot "
                            + "\(revision.productSnapshotID ?? "none") but carries the provenance of "
                            + "\(provenance.snapshotID)")
                }
                try merge(ProductDefinition(provenance: provenance), into: &productsByID)
            }

            var revisions: [IntakeRevision] = []
            for revision in exported.revisions {
                if let snapshotID = revision.productSnapshotID, productsByID[snapshotID] == nil {
                    throw JournalImportError.corrupt(
                        "revision \(revision.number) of \(exported.id) uses the product snapshot "
                            + "\(snapshotID), which the export does not define")
                }
                revisions.append(
                    IntakeRevision(
                        intakeID: exported.id, number: revision.number,
                        components: try components(of: revision, in: exported.id),
                        productSnapshotID: revision.productSnapshotID, changeReason: revision.changeReason,
                        createdAt: revision.createdAt))
            }
            // The revisions must read 1, 2, ... in order and the current one must be the last: an importer
            // that kept the file's order as it stands would write a history that reads as if time ran
            // backwards. This walks the revisions the file actually holds and compares each number with its
            // position, rather than building the range the file claims: a hand-edited current_revision of two
            // billion would otherwise turn into an enormous set of numbers to check two revisions against.
            guard exported.currentRevision == revisions.count,
                  revisions.indices.allSatisfy({ revisions[$0].number == $0 + 1 })
            else {
                throw JournalImportError.corrupt(
                    "\(exported.id) does not hold the revisions 1 to \(exported.currentRevision) in order")
            }
            try checkTimeZone(exported.timeZoneIdentifier, of: exported.id)
            entries.append(
                JournalRestoreEntry(
                    intake: Intake(
                        id: exported.id, category: exported.category, occurredAt: exported.occurredAt,
                        timeZoneIdentifier: exported.timeZoneIdentifier, meal: exported.meal,
                        note: exported.note, lifecycle: .active,
                        currentRevision: exported.currentRevision),
                    revisions: revisions))
        }

        var tombstones: [Intake] = []
        for tombstone in document.tombstones {
            guard JournalValidation.isValidIntakeID(tombstone.intakeID) else {
                throw JournalImportError.corrupt("\(tombstone.intakeID) is not an intake id")
            }
            guard tombstone.revision >= 1 else {
                throw JournalImportError.corrupt("\(tombstone.intakeID) has no revision to retract")
            }
            guard seenIntakeIDs.insert(tombstone.intakeID).inserted else {
                throw JournalImportError.corrupt(
                    "\(tombstone.intakeID) is both an entry and a tombstone in the same export")
            }
            // A tombstone carries the id, the revision it was deleted at, when it happened and where, which
            // is all a retraction needs. Its category is not in the file, and a deleted entry is never
            // listed, so the restored row carries an empty category rather than an invented one.
            try checkTimeZone(tombstone.timeZoneIdentifier, of: tombstone.intakeID)
            tombstones.append(
                Intake(
                    id: tombstone.intakeID, category: "", occurredAt: tombstone.occurredAt,
                    timeZoneIdentifier: tombstone.timeZoneIdentifier, lifecycle: .deleted,
                    currentRevision: tombstone.revision))
        }

        var favoriteIDs = Set<String>()
        var favorites: [FavoriteTemplate] = []
        for favorite in document.favorites {
            guard favoriteIDs.insert(favorite.id).inserted else {
                throw JournalImportError.corrupt("the export lists the favorite \(favorite.id) twice")
            }
            // A favorite with nothing in it cannot be repeated: there are no amounts to repeat, so the row
            // would show a name and no numbers and the intake it created would claim nothing. An empty list
            // is a file that does not say what the template is, not a template of "none of the above".
            guard !favorite.components.isEmpty else {
                throw JournalImportError.corrupt("the favorite \(favorite.id) has no components")
            }
            var favoriteComponents: [FavoriteComponent] = []
            var favoriteComponentIDs = Set<String>()
            for component in favorite.components {
                guard JournalValidation.isValidComponentID(component.componentID) else {
                    throw JournalImportError.corrupt(
                        "the favorite \(favorite.id) has the component id \(component.componentID)")
                }
                guard favoriteComponentIDs.insert(component.componentID).inserted else {
                    throw JournalImportError.corrupt(
                        "the favorite \(favorite.id) names \(component.componentID) twice")
                }
                guard component.valueState == .known, let text = component.amount,
                      DecimalText.isValidDecimalText(text), let amount = DecimalText.decode(text)
                else {
                    throw JournalImportError.corrupt(
                        "the favorite \(favorite.id) has no exact decimal amount for \(component.componentID)")
                }
                // A favorite is a template to repeat, so every component has to name a quantity. Zero and
                // negative amounts are refused rather than stored: repeating one asks the person to eat
                // nothing, or to subtract something from a meal, and neither is a template that can be shown
                // as amounts or turned into an intake.
                guard amount > 0 else {
                    throw JournalImportError.corrupt(
                        "the favorite \(favorite.id) has the amount \(text) for \(component.componentID), "
                            + "which is not a quantity")
                }
                // The favorites store keeps a unit symbol as text and never parses it, so an unusable symbol
                // would be stored happily and only fail later, when the person repeats the favorite and the
                // amounts come back empty. A template that cannot be repeated is not worth restoring.
                guard (try? MeasureUnit(symbol: component.unit)) != nil else {
                    throw JournalImportError.corrupt(
                        "the favorite \(favorite.id) uses the unit \(component.unit), "
                            + "which this build does not know")
                }
                favoriteComponents.append(
                    FavoriteComponent(
                        componentID: component.componentID, name: component.name, amountText: text,
                        unitSymbol: component.unit))
            }
            if let snapshotID = favorite.productSnapshotID, productsByID[snapshotID] == nil {
                throw JournalImportError.corrupt(
                    "the favorite \(favorite.id) uses the product snapshot "
                        + "\(snapshotID), which the export does not define")
            }
            favorites.append(
                FavoriteTemplate(
                    id: favorite.id, displayName: favorite.displayName, category: favorite.category,
                    components: favoriteComponents, productSnapshotID: favorite.productSnapshotID,
                    meal: favorite.meal))
        }

        return JournalRestorePlan(
            entries: entries, tombstones: tombstones,
            products: productsByID.values.sorted { $0.snapshotID < $1.snapshotID }, favorites: favorites)
    }

    /// The time zone an entry was recorded in. It is what says when an entry happened where the person was,
    /// so it has to be a name a calendar can actually resolve: an empty string, or one nothing knows, would
    /// be stored as text and read back as a zone the app cannot use, and there would be nothing to repair it
    /// from later.
    private static func checkTimeZone(_ identifier: String, of intakeID: String) throws {
        guard !identifier.isEmpty, TimeZone(identifier: identifier) != nil else {
            throw JournalImportError.corrupt(
                "\(intakeID) has the time zone \"\(identifier)\", which is not a time zone")
        }
    }

    private static func productIndex(
        _ provenance: [JournalExportProvenance]
    ) throws -> [String: ProductDefinition] {
        var productsByID: [String: ProductDefinition] = [:]
        for item in provenance {
            try merge(ProductDefinition(provenance: item), into: &productsByID)
        }
        return productsByID
    }

    /// Adds a snapshot to the index. The same id twice is fine when both copies say the same thing, which
    /// is what a revision's own provenance and the products list always are in a file this app wrote; two
    /// different products under one id is a corrupt file.
    private static func merge(
        _ product: ProductDefinition, into productsByID: inout [String: ProductDefinition]
    ) throws {
        guard let existing = productsByID[product.snapshotID] else {
            productsByID[product.snapshotID] = product
            return
        }
        guard existing == product else {
            throw JournalImportError.corrupt(
                "the export gives the product snapshot \(product.snapshotID) two different definitions")
        }
    }

    /// The components of one revision, with exact decimal amounts.
    private static func components(
        of revision: JournalExportRevision, in intakeID: String
    ) throws -> [IntakeComponent] {
        var seen = Set<String>()
        var components: [IntakeComponent] = []
        for component in revision.components {
            guard JournalValidation.isValidComponentID(component.componentID) else {
                throw JournalImportError.corrupt(
                    "revision \(revision.number) of \(intakeID) has the component id \(component.componentID)")
            }
            guard seen.insert(component.componentID).inserted else {
                throw JournalImportError.corrupt(
                    "revision \(revision.number) of \(intakeID) names \(component.componentID) twice")
            }
            guard let unit = try? MeasureUnit(symbol: component.unit) else {
                throw JournalImportError.corrupt(
                    "revision \(revision.number) of \(intakeID) uses the unit \(component.unit), "
                        + "which this build does not know")
            }
            switch component.valueState {
            case .known:
                guard let text = component.amount, DecimalText.isValidDecimalText(text),
                      let amount = DecimalText.decode(text) else {
                    throw JournalImportError.corrupt(
                        "revision \(revision.number) of \(intakeID) has an amount for "
                            + "\(component.componentID) that is not exact decimal text")
                }
                components.append(
                    IntakeComponent(
                        componentID: component.componentID, name: component.name, amount: amount, unit: unit))
            case .unknown:
                // The journal keeps a missing amount as a not-a-number decimal and refuses to write one,
                // so a revision that carries a missing amount cannot be stored. Restoring it as 0 would
                // turn "not known" into "none", which is the one thing the contract never allows, so the
                // file is refused and the journal is left alone.
                throw JournalImportError.corrupt(
                    "revision \(revision.number) of \(intakeID) has no amount for "
                        + "\(component.componentID), which this journal cannot store")
            }
        }
        return components
    }
}
