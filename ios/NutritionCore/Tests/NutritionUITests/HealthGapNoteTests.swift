import NutritionJournal
import Foundation
import XCTest

@testable import NutritionUI

/// The partial-line note: the Health note only when the journal side is complete and only Health is short.
final class HealthGapNoteTests: XCTestCase {
    func testTheHealthNoteNamesTheDataSourceForAHealthGap() {
        XCTAssertEqual(
            MissingValueWording.partialNote(name: "energy", healthGap: true, count: 0),
            "Some Health readings are missing for energy")
    }

    func testAJournalGapKeepsTheEntryNotes() {
        XCTAssertEqual(MissingValueWording.partialNote(name: "energy", healthGap: false, count: 0), "Some entries can't be added up for energy")
        XCTAssertEqual(MissingValueWording.partialNote(name: "energy", healthGap: false, count: 2), "2 entries have no energy value")
    }

    func testACompleteJournalWithAShortHealthSideIsAHealthGap() {
        let energy = HealthKitWritePlanner.mapping(for: "energy")!.unit
        let journal = NutrientProgressLine(nutrient: "energy", amount: .known(500, energy), goal: nil)
        let combined = HealthIntakeTotals.combine([journal], outside: .read(values: [:], readKeys: []))
        XCTAssertEqual(combined.first?.isPartial, true)
        XCTAssertEqual(combined.first?.healthGap, true)
    }

    func testAPartialJournalIsNotAHealthGap() {
        let energy = HealthKitWritePlanner.mapping(for: "energy")!.unit
        let partial = NutrientProgressLine(
            nutrient: "energy", amount: .unknown, goal: nil, isPartial: true, knownSum: .known(300, energy), missingCount: 1)
        let combined = HealthIntakeTotals.combine([partial], outside: .read(values: [:], readKeys: []))
        XCTAssertEqual(combined.first?.healthGap, false)
    }
}
