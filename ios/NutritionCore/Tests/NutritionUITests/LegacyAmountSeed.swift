import Foundation
import SwiftData
import XCTest
@testable import NutritionJournal

/// Rewrites a stored intake's current-revision amounts the way an older build could have stored them. It skips
/// the store's write validation on purpose, so a test can read back a row the current store would refuse to
/// write. It lives in the test target so Release test builds compile the negative-value tests that use it (#521
/// item 3); the store no longer carries a DEBUG-only seam.
enum LegacyAmountSeed {
    static func seed(storeAt url: URL, intakeID: String, amountsByComponent: [String: String]) throws {
        let schema = Schema(versionedSchema: JournalSchemaV10.self)
        let container = try ModelContainer(
            for: schema, migrationPlan: JournalMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<IntakeRecord>(
            predicate: #Predicate<IntakeRecord> { $0.intakeID == intakeID })).first
        else { throw JournalError.unknownIntake(intakeID) }
        let current = record.currentRevision
        let revisions = try context.fetch(FetchDescriptor<RevisionRecord>(
            predicate: #Predicate<RevisionRecord> { $0.intakeID == intakeID && $0.number == current }))
        guard let revision = revisions.first else { throw JournalError.unknownIntake(intakeID) }
        guard var components = try JSONSerialization.jsonObject(
            with: Data(revision.componentsJSON.utf8)) as? [[String: Any]]
        else { throw JournalError.corruptRecord("revision") }
        for index in components.indices {
            if let id = components[index]["componentID"] as? String, let text = amountsByComponent[id] {
                components[index]["amountText"] = text
            }
        }
        revision.componentsJSON = String(decoding: try JSONSerialization.data(withJSONObject: components), as: UTF8.self)
        try context.save()
    }
}
