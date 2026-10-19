import XCTest
@testable import NutritionUI

@MainActor
final class LibrarySearchEmptyTests: XCTestCase {
    /// A typed search with no match is a search empty state, not the segment's "No favorites yet".
    func testSearchWithNoMatchIsASearchEmptyState() {
        XCTAssertTrue(LibraryViewModel.isSearchEmpty(visibleCount: 0, searchText: "oatz"))
    }

    /// With no search text, an empty segment keeps its own empty state.
    func testEmptySegmentWithoutSearchKeepsItsOwnEmptyState() {
        XCTAssertFalse(LibraryViewModel.isSearchEmpty(visibleCount: 0, searchText: ""))
    }

    /// A search that matches shows its rows, never the empty state.
    func testSearchWithAMatchIsNotEmpty() {
        XCTAssertFalse(LibraryViewModel.isSearchEmpty(visibleCount: 2, searchText: "oat"))
    }
}
