import Foundation
import XCTest
@testable import NutritionJournal

/// Import bounds are deliberately injected in tests so their inclusive edges do not depend on fixture size.
final class JournalImportLimitsTests: JournalImportTestCase {
    func testExactByteAndAggregateBoundariesAreAccepted() throws {
        let data = try exportData()
        // 2 intakes + 3 revisions + 3 revision components + 1 tombstone + 2 favorites
        // + 2 favorite components + 1 product = 14 raw collection elements.
        let limits = JournalImportLimits(maxImportBytes: data.count, maxAggregateElements: 14)
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)

        let summary = try JournalImporter.importExport(
            data, into: journal, favorites: favoritesStore, limits: limits)

        XCTAssertEqual(summary.intakes, 2)
        XCTAssertEqual(summary.favorites, 2)
        XCTAssertEqual(try journal.activeIntakes().count, 2)
        XCTAssertEqual(try journal.deletedIntakes().count, 1)
        XCTAssertEqual(try favoritesStore.list().count, 2)
    }

    func testOneElementOverAggregateLimitIsRefusedBeforeEitherStoreChanges() throws {
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)

        XCTAssertThrowsError(
            try JournalImporter.importExport(
                data, into: journal, favorites: favoritesStore,
                limits: JournalImportLimits(maxImportBytes: data.count, maxAggregateElements: 13))
        ) { error in
            XCTAssertEqual(error as? JournalImportError, .tooLarge)
        }

        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try journal.deletedIntakes().isEmpty)
        XCTAssertTrue(try journal.pendingOutbox().isEmpty)
        XCTAssertNil(try journal.product(snapshotID: "snap-oats-1"))
        XCTAssertTrue(try favoritesStore.list().isEmpty)
    }

    func testOneByteOverLimitIsRefusedBeforeParsingAndLeavesStoresUnchanged() throws {
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        let invalidJSON = Data(repeating: 0x7B, count: 9)

        XCTAssertThrowsError(
            try JournalImporter.importExport(
                invalidJSON, into: journal, favorites: favoritesStore,
                limits: JournalImportLimits(maxImportBytes: 8, maxAggregateElements: 100))
        ) { error in
            // If JSONSerialization ran first this would be malformed, so this also pins check ordering.
            XCTAssertEqual(error as? JournalImportError, .tooLarge)
        }

        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try journal.deletedIntakes().isEmpty)
        XCTAssertTrue(try journal.pendingOutbox().isEmpty)
        XCTAssertNil(try journal.product(snapshotID: "snap-oats-1"))
        XCTAssertTrue(try favoritesStore.list().isEmpty)
    }

    func testByteBoundaryIsInclusiveAndOneByteOverIsRefused() throws {
        let data = try exportData()
        let target = try directory()
        let journal = try store(target)
        let favoritesStore = try favorites(target)
        let limits = JournalImportLimits(maxImportBytes: data.count - 1, maxAggregateElements: 100)

        XCTAssertThrowsError(
            try JournalImporter.importExport(data, into: journal, favorites: favoritesStore, limits: limits)
        ) { error in
            XCTAssertEqual(error as? JournalImportError, .tooLarge)
        }

        XCTAssertTrue(try journal.activeIntakes().isEmpty)
        XCTAssertTrue(try favoritesStore.list().isEmpty)
    }
}
