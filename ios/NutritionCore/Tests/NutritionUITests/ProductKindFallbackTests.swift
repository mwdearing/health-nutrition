import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// A product whose kind cannot be read falls back to the entry's own category, so a supplement stays a
/// supplement rather than reading as food (#775, Mike's pick on the fallback card).
@MainActor
final class ProductKindFallbackTests: XCTestCase {
    func testAnUnreadableSnapshotKindFallsBackToTheCategory() {
        XCTAssertEqual(
            ProductKindResolution.kind(snapshotID: "s-1", snapshotKind: { _ in nil }, category: "supplement"), .supplement)
        XCTAssertEqual(
            ProductKindResolution.kind(snapshotID: "s-1", snapshotKind: { _ in nil }, category: "food"), .food)
    }

    func testAReadableSnapshotKindStillWins() {
        XCTAssertEqual(
            ProductKindResolution.kind(snapshotID: "s-1", snapshotKind: { _ in .food }, category: "supplement"), .food)
        XCTAssertEqual(
            ProductKindResolution.kind(snapshotID: "s-1", snapshotKind: { _ in .supplement }, category: "food"), .supplement)
    }

    func testNoSnapshotStillUsesTheCategory() {
        XCTAssertEqual(ProductKindResolution.kind(snapshotID: nil, snapshotKind: { _ in nil }, category: "supplement"), .supplement)
        XCTAssertEqual(ProductKindResolution.kind(snapshotID: nil, snapshotKind: { _ in nil }, category: "food"), .food)
    }

    /// Totals keep their own rule: an entry without a readable kind still counts as food there (#364, #416).
    func testTotalsKindIsUnchanged() {
        XCTAssertEqual(ProductKindResolution.totalsKind(snapshotKind: nil), .food)
    }
}
