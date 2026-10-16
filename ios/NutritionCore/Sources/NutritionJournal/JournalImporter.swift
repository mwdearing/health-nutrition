import CryptoKit
import Foundation
import NutritionDomain

/// Why an import did not complete. Most failures leave both stores unchanged; `partialRestore` means the
/// favorites write and its protected journal undo both failed, so restored journal rows may remain.
public enum JournalImportError: Error, Sendable, Equatable {
    /// The encoded file or its combined collections exceed the import limits for this build.
    case tooLarge
    /// The document declares a schema version this build does not read. Its fields are not guessed at.
    case unsupportedVersion
    /// The store already holds intakes, active or deleted. This version restores into an empty journal
    /// only; it does not merge one journal into another.
    case notEmpty
    /// A version 4 file states the whole saved meals list, and the phone already keeps saved meals. It is not
    /// merged into them.
    case savedMealsNotEmpty
    /// The bytes are not a journal export at all: not JSON, or not the shape the schema describes.
    case malformed(String)
    /// The file is a version 1 export that cannot be restored as it stands: a snapshot nothing defines,
    /// a revision history that does not line up, an amount that is not exact decimal text.
    case corrupt(String)
    /// Favorites could not be restored and the journal refused its narrow undo. These counts describe
    /// rows from the restore that may remain; no entry content or underlying store error is exposed.
    case partialRestore(retainedIntakes: Int, retainedTombstones: Int)
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
    /// Saved meals written.
    public var savedMeals: Int
    /// Restored entries whose product is kept out of Library > Products.
    public var keptOutOfLibrary: Int

    public init(intakes: Int, revisions: Int, tombstones: Int, favorites: Int, products: Int, savedMeals: Int = 0,
                keptOutOfLibrary: Int = 0) {
        self.intakes = intakes
        self.revisions = revisions
        self.tombstones = tombstones
        self.favorites = favorites
        self.products = products
        self.savedMeals = savedMeals
        self.keptOutOfLibrary = keptOutOfLibrary
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

/// The keys each object in a version 3 export has, taken from `contracts/journal-export/v3.schema.json`.
///
/// Version 3 is version 2 with a revision's own `occurred_at` and `time_zone`, both required and nullable.
enum JournalImportV3Keys {
    static let root = JournalImportV2Keys.root
    static let intake = JournalImportV2Keys.intake
    static let revision: Set<String> = JournalImportV2Keys.revision.union(["occurred_at", "time_zone"])
    static let provenance = JournalImportV2Keys.provenance
    static let component = JournalImportV2Keys.component
    static let tombstone = JournalImportV2Keys.tombstone
    static let favorite = JournalImportV2Keys.favorite
}

/// The keys each object in a version 5 export has, taken from `contracts/journal-export/v5.schema.json`.
///
/// Version 5 is version 4 with `kept_out_of_library` at the root: the intake ids whose product is kept out of
/// Library > Products. Every other object is as it was in version 4.
enum JournalImportV5Keys {
    static let root: Set<String> = JournalImportV4Keys.root.union(["kept_out_of_library"])
}

/// The keys each object in a version 4 export has, taken from `contracts/journal-export/v4.schema.json`.
///
/// Version 4 is version 3 with `saved_meals` at the root, each a saved meal whose items have a favorite's keys.
enum JournalImportV4Keys {
    static let root: Set<String> = JournalImportV3Keys.root.union(["saved_meals"])
    static let intake = JournalImportV3Keys.intake
    static let revision = JournalImportV3Keys.revision
    static let provenance = JournalImportV3Keys.provenance
    static let component = JournalImportV3Keys.component
    static let tombstone = JournalImportV3Keys.tombstone
    static let favorite = JournalImportV3Keys.favorite
    static let savedMeal: Set<String> = ["id", "name", "meal", "items"]
}

/// Restores a journal export into an empty journal: the entries with their whole revision history, the
/// tombstones of deleted entries and the favorites.
///
/// An imported entry is history, not something new to deliver, so an import writes no outbox operation
/// and no projection: sending yesterday's breakfast to Health again because a phone was replaced would
/// be a delivery, and this is not one. The ids, the timestamps and the revision numbers are the ones the
/// file carries, so a restore does not renumber anything or move an entry to a new instant.
public enum JournalImporter {
    /// Reads `data` and writes it into `store`, and into `favorites` and `savedMeals` when the document needs
    /// them.
    ///
    /// The whole document is read and checked before the first row is written, so a file that is malformed,
    /// from a version this build does not read, or internally inconsistent changes nothing.
    ///
    /// The journal is written first, in one save that queues no delivery work, then the saved meals and the
    /// favorites (the second phase). When a second-phase write fails, the saved meals list is emptied again and
    /// a narrow undo puts the journal back if its rows are untouched. If a concurrent write means that undo
    /// would throw away somebody's work, a typed partial outcome reports how many imported rows may remain
    /// rather than mislabeling the file as corrupt. Saved meals are restored only into an empty list.
    ///
    /// A restore the app was stopped in after the journal's save is finished by importing the same file again:
    /// a flag beside the journal store names the file, and only the second phase's unwritten parts are written
    /// (#118). One import
    /// runs at a time; another started meanwhile is refused as `notEmpty`, as it would be once the first one's
    /// journal is written.
    public static func importExport(
        _ data: Data, into store: JournalStore, favorites: FavoritesStore?,
        savedMeals: JournalSavedMealsStore? = nil, limits: JournalImportLimits = .default
    ) throws -> JournalImportSummary {
        try limits.validate(data)
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
        // The same holds for saved meals, from version 4.
        let savedMealsTarget: JournalSavedMealsStore?
        if plan.savedMeals.isEmpty {
            savedMealsTarget = nil
        } else {
            guard let savedMeals else {
                throw JournalImportError.corrupt(
                    "the export carries \(plan.savedMeals.count) saved meals and no saved meals store was given")
            }
            savedMealsTarget = savedMeals
        }

        // **One import at a time.** The flag below belongs to the run that wrote it, and a second import running
        // alongside could resume over a journal the first is about to undo, or clear a flag the first still
        // needs. A second import is refused at once rather than queued: it would be refused as `notEmpty` as soon
        // as the first one's journal is written, and waiting here would hold its caller for as long as the
        // first takes.
        guard importLock.try() else { throw JournalImportError.notEmpty }
        defer { importLock.unlock() }

        // The second phase is everything written after the journal: the saved meals, then the favorites. The
        // flag below covers it whenever it has anything to write.
        let hasSecondPhase = favoritesTarget != nil || savedMealsTarget != nil
        let progress = hasSecondPhase ? store as? JournalRestoreProgress : nil
        let digest = fileDigest(data)
        // A file with no entries and no deleted ones writes nothing to the journal, so a stop after its saved meals
        // leaves an empty journal; the flag naming this file is then what says a restore of it is unfinished.
        let writesJournal = !plan.entries.isEmpty || !plan.tombstones.isEmpty
        var resumesEmptyJournal = false
        if !writesJournal, let progress { resumesEmptyJournal = try progress.restoreInProgressDigest() == digest }
        if try journalHoldsAnything(store) || resumesEmptyJournal {
            // **A restore of this same file that the app stopped after its journal's save is finished (#118).**
            // The flag beside the store names the file whose journal was written and whose second phase was not
            // finished, and the journal has to hold exactly that file's journal: a flag left by a stop before
            // the journal's save, with entries logged since, is not taken for one. Only what the second phase
            // has not yet written is written. The flag stays until it is, so a failure here can be retried the
            // same way. Anything else in a journal that is not empty is refused as before, and the flag is left
            // alone: it is not this run's. An import of the same file still running in parallel writes the same
            // rows, so the overlap writes identical rows twice at most; nothing here is read back from the other.
            guard let progress, try progress.restoreInProgressDigest() == digest,
                  try journalHolds(plan, store: store)
            else { throw JournalImportError.notEmpty }
            // Each part of the second phase is one save that writes a receipt with it, so the receipt is the
            // durable record that the part happened. A part with no receipt must not have happened either: the
            // saved meals list must be empty, or hold exactly the file's meals (a stop between the list's write
            // and its receipt's), and none of the file's favorites may be on the phone.
            let savedMealsWritten = try savedMealsTarget.map { try $0.hasSavedMealsRestoreReceipt(digest) } ?? true
            if let savedMealsTarget, !savedMealsWritten {
                let present = try savedMealsTarget.journalSavedMeals()
                guard present.isEmpty || present == plan.savedMeals else { throw JournalImportError.savedMealsNotEmpty }
            }
            let favoritesWritten = try favoritesTarget.map { try $0.hasRestoreReceipt(digest) } ?? true
            if favoritesTarget != nil, !favoritesWritten {
                guard let favorites,
                      try Set(favorites.list().map(\.id)).isDisjoint(with: plan.favorites.map(\.id))
                else { throw JournalImportError.notEmpty }
            }
            // A flag that outlived every part of the second phase (a stop after the last save, before the flag
            // was cleared) is not an unfinished restore, however much of it was deleted since.
            guard !(savedMealsWritten && favoritesWritten) else { throw JournalImportError.notEmpty }
            if let savedMealsTarget, !savedMealsWritten {
                try savedMealsTarget.restoreJournalSavedMeals(plan.savedMeals, receipt: digest)
            }
            if let favoritesTarget, !favoritesWritten {
                try favoritesTarget.restore(plan.favorites, receipt: digest)
            }
            // A flag that outlived a finished resume would let a later import of this file write rows the
            // person deleted since, so a failure to clear it is reported rather than swallowed.
            try progress.clearRestoreInProgress()
            // The flag is gone, so the receipts have nothing left to answer; one left by a stop here is harmless.
            try? favoritesTarget?.removeRestoreReceipt(digest)
            try? savedMealsTarget?.removeSavedMealsRestoreReceipt(digest)
            return summary(of: plan)
        }

        // Saved meals are restored only into an empty list: merging a file's meals into the phone's would have
        // to choose between two meals of one name, and a restore does not choose. A version 4 file states the
        // whole list, an empty one included, so it is refused over a phone that keeps any. The store checks again
        // as it writes, so a meal saved in another window meanwhile is not overwritten.
        if document.schemaVersion >= 4, let savedMeals, try !savedMeals.journalSavedMeals().isEmpty {
            throw JournalImportError.savedMealsNotEmpty
        }
        // The journal is empty, so any flag found is stale and this run's own replaces it. It goes down before
        // the journal's save, so a stop after that save leaves it behind. A flag that cannot be written only
        // loses the resume; the import itself goes ahead as before.
        try? progress?.markRestoreInProgress(fileDigest: digest)
        // The store refuses a journal that is not empty, and refuses it from inside this same transaction,
        // so the check and the inserts cannot be pulled apart by another write.
        let receipt: JournalRestoreReceipt
        do {
            receipt = try journal.restore(plan)
        } catch {
            // The journal wrote nothing, so there is nothing to resume.
            try? progress?.clearRestoreInProgress()
            throw error
        }
        if hasSecondPhase {
            var savedMealsWritten = false
            do {
                // Saved meals first: a replace of an empty list can be written again, so a resume after a stop
                // between the two saves only has the favorites left to write.
                if let savedMealsTarget {
                    try savedMealsTarget.restoreJournalSavedMeals(plan.savedMeals, receipt: digest)
                    savedMealsWritten = true
                }
                if let favoritesTarget { try favoritesTarget.restore(plan.favorites, receipt: digest) }
            } catch let secondPhaseFailure {
                // The journal is undone or reported as partial, so there is no unfinished restore of this file
                // to finish, and a flag left here could only be misread later.
                defer { try? progress?.clearRestoreInProgress() }
                // The list was empty before this restore, so putting it back is emptying it, but only while it
                // still holds exactly what this restore wrote: a meal saved meanwhile is not thrown away.
                var savedMealsLeft = false
                if let savedMealsTarget, savedMealsWritten {
                    do { try savedMealsTarget.clearRestoredSavedMeals(plan.savedMeals) } catch { savedMealsLeft = true }
                }
                let retainedIntakes = receipt.intakes.filter { $0.lifecycle == .active }.count
                let retainedTombstones = receipt.intakes.filter { $0.lifecycle == .deleted }.count
                // Saved meals that could not be taken back still name the product snapshots this restore wrote,
                // which the journal's undo would remove. So the journal stays as well, and the restore is reported
                // as partial: both are there, and the person can check them before importing again.
                guard !savedMealsLeft else {
                    throw JournalImportError.partialRestore(
                        retainedIntakes: retainedIntakes, retainedTombstones: retainedTombstones)
                }
                do {
                    try journal.undoRestore(receipt)
                } catch {
                    throw JournalImportError.partialRestore(
                        retainedIntakes: retainedIntakes, retainedTombstones: retainedTombstones)
                }
                throw secondPhaseFailure
            }
            // A flag that cannot be cleared is reported rather than swallowed. It cannot start a resume over this
            // second phase: every part of it now has its receipt.
            try progress?.clearRestoreInProgress()
            try? favoritesTarget?.removeRestoreReceipt(digest)
            try? savedMealsTarget?.removeSavedMealsRestoreReceipt(digest)
        }
        return summary(of: plan)
    }

    private static let importLock = NSLock()

    /// Whether the journal holds this plan's journal and nothing else: the same live intakes, field for field,
    /// with the same revisions, and the same deleted ones.
    static func journalHolds(_ plan: JournalRestorePlan, store: JournalStore) throws -> Bool {
        let active = try store.activeIntakes()
        let planned = Dictionary(
            plan.entries.map { ($0.intake.id, $0.intake) }, uniquingKeysWith: { first, _ in first })
        guard active.count == plan.entries.count, active.allSatisfy({ planned[$0.id] == $0 }) else { return false }
        for entry in plan.entries {
            guard try store.revisions(of: entry.intake.id).sorted(by: { $0.number < $1.number }) == entry.revisions
            else { return false }
        }
        let deleted = try (store as? JournalTombstoneSource)?.deletedIntakes() ?? []
        return Set(deleted.map(\.id)) == Set(plan.tombstones.map(\.id)) && deleted.count == plan.tombstones.count
    }

    private static func summary(of plan: JournalRestorePlan) -> JournalImportSummary {
        JournalImportSummary(
            intakes: plan.entries.count,
            revisions: plan.entries.reduce(0) { $0 + $1.revisions.count },
            tombstones: plan.tombstones.count,
            favorites: plan.favorites.count,
            products: plan.products.count,
            savedMeals: plan.savedMeals.count,
            keptOutOfLibrary: plan.entries.reduce(0) { count, entry in
                count + (plan.keptOutOfLibrary.contains(entry.intake.id) ? 1 : 0)
            })
    }

    /// Whether the journal holds any intake, live or deleted.
    private static func journalHoldsAnything(_ store: JournalStore) throws -> Bool {
        if try !store.activeIntakes().isEmpty { return true }
        return try !((store as? JournalTombstoneSource)?.deletedIntakes().isEmpty ?? true)
    }

    /// The SHA-256 of the file's bytes as lowercase hex, which is how the restore flag names the file.
    static func fileDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
        let revisionKeys = version >= 3 ? JournalImportV3Keys.revision : JournalImportV1Keys.revision
        let rootKeys = version >= 5 ? JournalImportV5Keys.root : version >= 4 ? JournalImportV4Keys.root : JournalImportV1Keys.root
        try checkObject(root, keys: rootKeys, path: "$", version: version)
        try checkMinimumLengthOne(root, keys: ["app_version"], path: "$", version: version)
        for (index, item) in try objects(root["intakes"], path: "$.intakes").enumerated() {
            let path = "$.intakes[\(index)]"
            let intake = try object(item, path: path)
            try checkObject(intake, keys: JournalImportV1Keys.intake, path: path, version: version)
            try checkMinimumLengthOne(intake, keys: ["category", "time_zone"], path: path, version: version)
            let revisionList = try objects(intake["revisions"], path: "\(path).revisions")
            guard !revisionList.isEmpty else {
                throw JournalImportError.malformed("\(path).revisions must contain at least one revision")
            }
            for (revisionIndex, revisionItem) in revisionList.enumerated() {
                let revisionPath = "\(path).revisions[\(revisionIndex)]"
                let revision = try object(revisionItem, path: revisionPath)
                try checkObject(revision, keys: revisionKeys, path: revisionPath, version: version)
                if version >= 3 {
                    try checkMinimumLengthOne(revision, keys: ["time_zone"], path: revisionPath, version: version)
                }
                if let provenance = revision["provenance"], !(provenance is NSNull) {
                    let provenancePath = "\(revisionPath).provenance"
                    let provenanceFields = try object(provenance, path: provenancePath)
                    try checkObject(
                        provenanceFields, keys: provenanceKeys, path: provenancePath, version: version)
                    try checkProvenanceMinimumLengths(
                        provenanceFields, path: provenancePath, version: version)
                }
                let componentList = try objects(
                    revision["components"], path: "\(revisionPath).components")
                guard !componentList.isEmpty else {
                    throw JournalImportError.malformed(
                        "\(revisionPath).components must contain at least one component")
                }
                try checkComponents(revision["components"], path: "\(revisionPath).components", version: version)
            }
        }
        let tombstoneList = try objects(root["tombstones"], path: "$.tombstones")
        for (index, item) in tombstoneList.enumerated() {
            let path = "$.tombstones[\(index)]"
            try checkObject(
                try object(item, path: path), keys: JournalImportV1Keys.tombstone, path: path, version: version)
            try checkMinimumLengthOne(
                try object(item, path: path), keys: ["time_zone"], path: path, version: version)
        }
        let favoriteList = try objects(root["favorites"], path: "$.favorites")
        for (index, item) in favoriteList.enumerated() {
            let path = "$.favorites[\(index)]"
            let favorite = try object(item, path: path)
            try checkObject(favorite, keys: JournalImportV1Keys.favorite, path: path, version: version)
            try checkMinimumLengthOne(
                favorite, keys: ["id", "display_name", "category"], path: path, version: version)
            try checkComponents(favorite["components"], path: "\(path).components", version: version)
        }
        if version >= 5 {
            guard root["kept_out_of_library"] is [String] else {
                throw JournalImportError.malformed("$.kept_out_of_library must be a list of intake ids")
            }
        }
        if version >= 4 {
            for (index, item) in try objects(root["saved_meals"], path: "$.saved_meals").enumerated() {
                let path = "$.saved_meals[\(index)]"
                let savedMeal = try object(item, path: path)
                try checkObject(savedMeal, keys: JournalImportV4Keys.savedMeal, path: path, version: version)
                try checkMinimumLengthOne(savedMeal, keys: ["id", "name"], path: path, version: version)
                for (itemIndex, mealItem) in try objects(savedMeal["items"], path: "\(path).items").enumerated() {
                    let itemPath = "\(path).items[\(itemIndex)]"
                    let template = try object(mealItem, path: itemPath)
                    try checkObject(template, keys: JournalImportV4Keys.favorite, path: itemPath, version: version)
                    try checkMinimumLengthOne(
                        template, keys: ["id", "display_name", "category"], path: itemPath, version: version)
                    try checkComponents(template["components"], path: "\(itemPath).components", version: version)
                }
            }
        }
        let productList = try objects(root["products"], path: "$.products")
        for (index, item) in productList.enumerated() {
            let path = "$.products[\(index)]"
            let provenance = try object(item, path: path)
            try checkObject(provenance, keys: provenanceKeys, path: path, version: version)
            try checkProvenanceMinimumLengths(provenance, path: path, version: version)
        }
    }

    private static func checkComponents(_ value: Any?, path: String, version: Int) throws {
        let list = try objects(value, path: path)
        for (index, item) in list.enumerated() {
            let componentPath = "\(path)[\(index)]"
            try checkObject(
                try object(item, path: componentPath), keys: JournalImportV1Keys.component, path: componentPath,
                version: version)
            try checkMinimumLengthOne(
                try object(item, path: componentPath), keys: ["unit"], path: componentPath, version: version)
        }
    }

    private static func checkProvenanceMinimumLengths(
        _ fields: [String: Any], path: String, version: Int
    ) throws {
        try checkMinimumLengthOne(
            fields,
            keys: ["snapshot_id", "product_id", "name", "label_basis", "catalog_origin", "catalog_version"],
            path: path, version: version)
    }

    /// JSON Schema's minLength counts characters, and every constrained string here has a minimum of one.
    /// Type checks remain the decoder's job; this pass only refuses an empty string where the schema does.
    private static func checkMinimumLengthOne(
        _ fields: [String: Any], keys: Set<String>, path: String, version: Int
    ) throws {
        for key in keys.sorted() where (fields[key] as? String)?.isEmpty == true {
            throw JournalImportError.malformed(
                "\(path).\(key) is empty, but the version \(version) schema requires at least one character")
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
            // things at once, and honoring either of them alone would attach the wrong product to the
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
                // A revision's own time is all or nothing: an instant with no zone, or a zone with no instant,
                // cannot say when the intake happened where the person was.
                switch (revision.occurredAt, revision.timeZoneIdentifier) {
                case (nil, nil):
                    break
                case (.some, .some(let zone)):
                    try checkTimeZone(zone, of: exported.id)
                default:
                    throw JournalImportError.corrupt(
                        "revision \(revision.number) of \(exported.id) has an occurred_at or a time_zone "
                            + "without the other")
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
                        createdAt: revision.createdAt, occurredAt: revision.occurredAt,
                        timeZoneIdentifier: revision.timeZoneIdentifier))
            }
            // The revisions must read 1, 2, ... in order and the current one must be the last: an importer
            // that kept the file's order as it stands would write a history that reads as if time ran
            // backwards. This walks the revisions the file actually holds and compares each number with its
            // position, rather than building the range the file claims: a hand-edited current_revision of two
            // billion would otherwise turn into an enormous set of numbers to check two revisions against.
            guard exported.currentRevision > 0, !revisions.isEmpty,
                  exported.currentRevision == revisions.count,
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
            favorites.append(
                try restoredTemplate(favorite, named: "the favorite \(favorite.id)", products: productsByID))
        }

        return JournalRestorePlan(
            entries: entries, tombstones: tombstones,
            products: productsByID.values.sorted { $0.snapshotID < $1.snapshotID }, favorites: favorites,
            savedMeals: try restoredSavedMeals(document.savedMeals, products: productsByID),
            keptOutOfLibrary: document.keptOutOfLibrary)
    }

    /// The saved meals a version 4 file carries, refused as a whole when any breaks a rule the app keeps when
    /// it saves one (`JournalSavedMealLimits`): a restore must never write a list the app would refuse to save.
    private static func restoredSavedMeals(
        _ exported: [JournalExportSavedMeal], products: [String: ProductDefinition]
    ) throws -> [JournalSavedMeal] {
        guard exported.count <= JournalSavedMealLimits.maximumMeals else {
            throw JournalImportError.corrupt(
                "the export lists \(exported.count) saved meals, more than \(JournalSavedMealLimits.maximumMeals)")
        }
        var ids = Set<String>()
        var names: [String] = []
        var meals: [JournalSavedMeal] = []
        for savedMeal in exported {
            guard ids.insert(savedMeal.id).inserted else {
                throw JournalImportError.corrupt("the export lists the saved meal \(savedMeal.id) twice")
            }
            let name = JournalSavedMealLimits.trimmedName(savedMeal.name)
            guard !name.isEmpty, name.count <= JournalSavedMealLimits.maximumNameLength else {
                throw JournalImportError.corrupt("the saved meal \(savedMeal.id) has a name the app cannot keep")
            }
            guard !names.contains(where: { JournalSavedMealLimits.sameName($0, name) }) else {
                throw JournalImportError.corrupt("the saved meal \(savedMeal.id) repeats another saved meal's name")
            }
            names.append(name)
            var meal: MealLabel?
            if let raw = savedMeal.meal {
                guard let label = MealLabel(rawValue: raw) else {
                    throw JournalImportError.corrupt("the saved meal \(savedMeal.id) names the meal \(raw)")
                }
                meal = label
            }
            guard (1...JournalSavedMealLimits.maximumItems).contains(savedMeal.items.count) else {
                throw JournalImportError.corrupt(
                    "the saved meal \(savedMeal.id) has \(savedMeal.items.count) items, not 1 to "
                        + "\(JournalSavedMealLimits.maximumItems)")
            }
            var itemIDs = Set<String>()
            var items: [FavoriteTemplate] = []
            for item in savedMeal.items {
                let label = "the saved meal \(savedMeal.id) item \(item.id)"
                guard itemIDs.insert(item.id).inserted else { throw JournalImportError.corrupt("\(label) is listed twice") }
                // The group's meal applies to every item, so an item that names one of its own is not what the
                // app writes and is refused rather than silently changed.
                guard item.meal == nil else { throw JournalImportError.corrupt("\(label) names a meal of its own") }
                // An item with no amounts is one the app never saves, and logging it would add nothing.
                guard !item.components.isEmpty else { throw JournalImportError.corrupt("\(label) has no components") }
                items.append(try restoredTemplate(item, named: label, products: products))
            }
            meals.append(JournalSavedMeal(id: savedMeal.id, name: name, meal: meal, items: items))
        }
        return meals
    }

    /// A favorite, or a saved meal's item, as the template the app keeps. `named` says which, in a refusal.
    private static func restoredTemplate(
        _ template: JournalExportFavorite, named label: String, products: [String: ProductDefinition]
    ) throws -> FavoriteTemplate {
        var restoredComponents: [FavoriteComponent] = []
        var componentIDs = Set<String>()
        for component in template.components {
            guard JournalValidation.isValidComponentID(component.componentID) else {
                throw JournalImportError.corrupt("\(label) has the component id \(component.componentID)")
            }
            guard componentIDs.insert(component.componentID).inserted else {
                throw JournalImportError.corrupt("\(label) names \(component.componentID) twice")
            }
            guard component.valueState == .known, let text = component.amount,
                  DecimalText.isValidDecimalText(text), let amount = DecimalText.decode(text)
            else {
                throw JournalImportError.corrupt("\(label) has no exact decimal amount for \(component.componentID)")
            }
            // A template is something to repeat, so every component has to name a quantity. Zero and
            // negative amounts are refused rather than stored: repeating one asks the person to eat
            // nothing, or to subtract something from a meal, and neither is a template that can be shown
            // as amounts or turned into an intake.
            guard amount > 0 else {
                throw JournalImportError.corrupt(
                    "\(label) has the amount \(text) for \(component.componentID), which is not a quantity")
            }
            // The stores keep a unit symbol as text and never parse it, so an unusable symbol would be stored
            // happily and only fail later, when the person repeats the template and the amounts come back
            // empty. A template that cannot be repeated is not worth restoring.
            guard (try? MeasureUnit(symbol: component.unit)) != nil else {
                throw JournalImportError.corrupt(
                    "\(label) uses the unit \(component.unit), which this build does not know")
            }
            restoredComponents.append(
                FavoriteComponent(
                    componentID: component.componentID, name: component.name, amountText: text,
                    unitSymbol: component.unit))
        }
        if let snapshotID = template.productSnapshotID, products[snapshotID] == nil {
            throw JournalImportError.corrupt(
                "\(label) uses the product snapshot \(snapshotID), which the export does not define")
        }
        return FavoriteTemplate(
            id: template.id, displayName: template.displayName, category: template.category,
            components: restoredComponents, productSnapshotID: template.productSnapshotID, meal: template.meal)
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
                // A component amount is a measured quantity, so zero is allowed but a negative one is not. The
                // journal would store it, and every later delivery of the intake would then fail, so the file is
                // refused before anything is written.
                guard amount >= 0 else {
                    throw JournalImportError.corrupt(
                        "revision \(revision.number) of \(intakeID) has the amount \(text) for "
                            + "\(component.componentID), which is negative and not a quantity")
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
