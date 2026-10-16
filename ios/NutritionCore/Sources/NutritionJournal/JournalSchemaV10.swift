import Foundation
import SwiftData

/// V10 adds one standalone entity: the unit a volume was logged in. Spoons and cups are typed input only, so an
/// entry logged as "4 tsp" is stored as milliliters, and without this row it can only read back as milliliters or
/// fluid ounces. A row exists only for an entry logged in such a unit; no row means the entry reads as it always
/// did, so every entry an earlier build wrote is unchanged by the migration. The amount itself is never touched.
enum JournalSchemaV10: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(10, 0, 0) }
    static var models: [any PersistentModel.Type] {
        JournalSchemaV9.models + [LoggedUnitRecord.self]
    }

    @Model final class LoggedUnitRecord {
        var intakeID: String
        var componentID: String
        var unitSymbol: String
        init(intakeID: String, componentID: String, unitSymbol: String) {
            self.intakeID = intakeID
            self.componentID = componentID
            self.unitSymbol = unitSymbol
        }
    }
}
