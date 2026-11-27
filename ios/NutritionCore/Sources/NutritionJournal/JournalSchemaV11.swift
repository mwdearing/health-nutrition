import Foundation
import SwiftData

/// V11 adds one standalone entity: a favorite that was starred from an entry kept out of Library. A row exists
/// only for such a favorite; no row means the favorite repeats into Library as it always did. The favorite
/// itself is never changed, so every favorite an earlier build wrote reads the same after the migration (#414).
enum JournalSchemaV11: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(11, 0, 0) }
    static var models: [any PersistentModel.Type] {
        JournalSchemaV10.models + [ExcludedFavoriteRecord.self]
    }

    @Model final class ExcludedFavoriteRecord {
        var favoriteID: String
        init(favoriteID: String) {
            self.favoriteID = favoriteID
        }
    }
}
