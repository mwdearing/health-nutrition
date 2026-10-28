import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// A favorite whose id, display name or category is empty is refused before anything is written (#72): the
/// schema requires all three, and the app holds a favorite it saves to the same rule (#290).
final class JournalImportFavoriteFieldsTests: JournalImportTestCase {
    func testAFavoriteWithAnEmptyRequiredFieldIsRefusedAndNothingIsWritten() throws {
        for field in ["id", "display_name", "category"] {
            var root = try object(of: try exportData())
            var listed = try XCTUnwrap(root["favorites"] as? [[String: Any]], field)
            XCTAssertFalse(listed.isEmpty, field)
            listed[0][field] = ""
            root["favorites"] = listed
            let target = try directory()
            let journal = try store(target)
            let favoritesStore = try favorites(target)

            XCTAssertThrowsError(
                try JournalImporter.importExport(
                    try JSONSerialization.data(withJSONObject: root), into: journal, favorites: favoritesStore),
                field
            ) { error in
                guard case .corrupt(let reason) = error as? JournalImportError else {
                    return XCTFail("expected a corrupt file for an empty \(field), got \(error)")
                }
                // An empty id may also trip an earlier id check; the name and category reach only this one.
                if field != "id" { XCTAssertTrue(reason.contains("empty \(field)"), reason) }
            }
            XCTAssertTrue(try journal.activeIntakes().isEmpty, field)
            XCTAssertTrue(try favoritesStore.list().isEmpty, field)
        }
    }
}
