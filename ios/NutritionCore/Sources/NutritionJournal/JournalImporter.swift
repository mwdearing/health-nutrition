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
    /// The document carries the identity of the product and where it came from, not the nutrient values
    /// it states, so a restored snapshot states none. That is the same information the export held, so a
    /// re-export of a restored journal is the same document; the values themselves still come from the
    /// catalog when something needs them.
    init(provenance: JournalExportProvenance) {
        self.init(
            snapshotID: provenance.snapshotID, productID: provenance.productID, name: provenance.name,
            brand: provenance.brand, barcode: provenance.barcode, labelBasis: provenance.labelBasis,
            catalogOrigin: provenance.catalogOrigin, catalogVersion: provenance.catalogVersion)
    }
}

/// Restores a journal export into an empty journal: the entries with their whole revision history, the
/// tombstones of deleted entries and the favorites.
///
/// An imported entry is history, not something new to deliver, so an import writes no outbox operation
/// and no projection: sending yesterday's breakfast to Health again because a phone was replaced would
/// be a delivery, and this is not one. The ids, the timestamps and the revision numbers are the ones the
/// file carries, so a restore does not renumber anything or move an entry to a new instant.
public enum JournalImporter {
    /// Reads `data` and writes it into `store`, and into `favorites` when one is given.
    ///
    /// The whole document is read and checked before the first row is written, so a file that is
    /// malformed, from a version this build does not read, or internally inconsistent changes nothing.
    /// The journal is then written in a single save that queues no delivery work.
    public static func importExport(
        _ data: Data, into store: JournalStore, favorites: FavoritesStore?
    ) throws -> JournalImportSummary {
        let document = try readDocument(data)
        let plan = try makePlan(document)
        guard let journal = store as? JournalRestoreTarget else {
            throw JournalImportError.corrupt("this journal store cannot be restored into")
        }
        guard try journal.isEmptyForImport() else { throw JournalImportError.notEmpty }

        // The journal and the favorites live in two files, so two writes cannot be one transaction. The
        // favorites go first, because that is the order that keeps a retry possible: a journal write that
        // fails leaves an empty journal and nothing to undo, while the other order would leave a restored
        // journal that refuses the next attempt because it is no longer empty.
        if let favorites, !plan.favorites.isEmpty {
            guard let target = favorites as? FavoritesRestoreTarget else {
                throw JournalImportError.corrupt("this favorites store cannot be restored into")
            }
            try target.restore(plan.favorites)
        }
        try journal.restore(plan)
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
              declared == JournalExport.currentSchemaVersion
        else {
            throw JournalImportError.unsupportedVersion
        }
        var bytes = data
        if root["schema_version"] is String {
            // A file that spells the version as "1" names the version this build reads, so only the
            // spelling differs. The decoder wants the number the export writes, so that one field is set
            // to it and the document is decoded from that.
            root["schema_version"] = declared
            guard let rewritten = try? JSONSerialization.data(withJSONObject: root) else {
                throw JournalImportError.malformed("the file could not be read again after its version was checked")
            }
            bytes = rewritten
        }
        do {
            return try JournalExporter.decode(bytes)
        } catch {
            // The version is already known to be this build's, so whatever the decoder objected to is the
            // file's shape rather than its version.
            throw JournalImportError.malformed("\(error)")
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
            // its products list was trimmed. A disagreement between the two is a corrupt file, not a
            // preference: one snapshot id cannot name two products.
            for revision in exported.revisions {
                guard let provenance = revision.provenance else { continue }
                try merge(ProductDefinition(provenance: provenance), into: &productsByID)
            }

            var numbers = Set<Int>()
            var revisions: [IntakeRevision] = []
            for revision in exported.revisions {
                guard numbers.insert(revision.number).inserted else {
                    throw JournalImportError.corrupt(
                        "\(exported.id) has two revisions numbered \(revision.number)")
                }
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
            // The revisions must read 1, 2, ... in order and the current one must be the last: an
            // importer that kept the file's order as it stands would write a history that reads as if
            // time ran backwards.
            guard exported.currentRevision >= 1 else {
                throw JournalImportError.corrupt("\(exported.id) has no current revision")
            }
            guard numbers == Set(1...exported.currentRevision),
                  revisions.map(\.number) == Array(1...exported.currentRevision)
            else {
                throw JournalImportError.corrupt(
                    "\(exported.id) does not hold the revisions 1 to \(exported.currentRevision) in order")
            }
            entries.append(
                JournalRestoreEntry(
                    intake: Intake(
                        id: exported.id, category: exported.category, occurredAt: exported.occurredAt,
                        timeZoneIdentifier: exported.timeZoneIdentifier, meal: exported.meal, note: exported.note),
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
            var favoriteComponents: [FavoriteComponent] = []
            for component in favorite.components {
                guard JournalValidation.isValidComponentID(component.componentID) else {
                    throw JournalImportError.corrupt(
                        "the favorite \(favorite.id) has the component id \(component.componentID)")
                }
                guard component.valueState == .known, let text = component.amount,
                      DecimalText.isValidDecimalText(text) else {
                    throw JournalImportError.corrupt(
                        "the favorite \(favorite.id) has no exact decimal amount for \(component.componentID)")
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
