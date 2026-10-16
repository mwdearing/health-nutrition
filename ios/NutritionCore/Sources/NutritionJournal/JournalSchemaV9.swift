import Foundation
import SwiftData

/// V9 adds one standalone entity: the entries logged with "Save to Library" off, so their product stays out of
/// Library > Products. A row exists only for such an entry. No row means the entry is saved as before, so every
/// entry an earlier build wrote keeps its Library item after the migration. The export does not carry the rows,
/// so the export schema is unchanged.
enum JournalSchemaV9: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(9, 0, 0) }
    static var models: [any PersistentModel.Type] {
        JournalSchemaV8.models + [LibraryExclusionRecord.self]
    }

    @Model final class LibraryExclusionRecord {
        var intakeID: String
        init(intakeID: String) { self.intakeID = intakeID }
    }
}
