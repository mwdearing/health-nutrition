import Foundation
import XCTest
@testable import NutritionDomain

/// The days the weight chart marks because a dose was logged on them. A day is the dose's own local day, in
/// the time zone it was logged in, as the Medication log reads it. Each marker lists that day's doses with
/// the medication's name, the amount and the unit the dose was logged in. Nothing here reads a site, and
/// nothing relates a dose to a weight.
final class DoseDayMarkersTests: XCTestCase {
    private let vialID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let penID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }

    private func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func dose(
        _ suffix: String, medication: UUID, at text: String, zone: String = "UTC", amount: String,
        unit: MedicationUnit = .mg, site: String? = nil
    ) -> MedicationDose {
        MedicationDose(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(suffix)")!, medicationID: medication,
            takenAt: instant(text), timeZoneIdentifier: zone, amount: Decimal(string: amount)!, unit: unit,
            site: site)
    }

    private var medications: [Medication] {
        [
            Medication(id: vialID, name: "Example vial", unit: .mg),
            Medication(id: penID, name: "Example pen", unit: .units),
        ]
    }

    func testDosesAreGroupedByDayInDayOrderWithEachDaysDosesInTimeOrder() {
        let doses = [
            dose("C1", medication: penID, at: "2026-04-10T18:00:00Z", amount: "1000", unit: .units),
            dose("C2", medication: vialID, at: "2026-04-10T08:00:00Z", amount: "2.5"),
            dose("C3", medication: vialID, at: "2026-04-03T08:00:00Z", amount: "2.5"),
        ]

        let markers = DoseDayMarkers.markers(
            medications: medications, doses: doses, from: day("2026-03-19"), through: day("2026-04-15"))

        XCTAssertEqual(markers, [
            DoseDayMarker(day: day("2026-04-03"), entries: [
                DoseDayMarker.Entry(name: "Example vial", amount: Decimal(string: "2.5")!, unit: .mg),
            ]),
            DoseDayMarker(day: day("2026-04-10"), entries: [
                DoseDayMarker.Entry(name: "Example vial", amount: Decimal(string: "2.5")!, unit: .mg),
                DoseDayMarker.Entry(name: "Example pen", amount: 1000, unit: .units),
            ]),
        ])
    }

    func testADoseCountsOnItsOwnLocalDay() {
        // 03:00 UTC on April 10 is 22:00 on April 9 in Chicago (daylight time, five hours behind).
        let doses = [dose("C4", medication: vialID, at: "2026-04-10T03:00:00Z", zone: "America/Chicago", amount: "2")]

        let markers = DoseDayMarkers.markers(
            medications: medications, doses: doses, from: day("2026-03-19"), through: day("2026-04-15"))

        XCTAssertEqual(markers.map(\.day), [day("2026-04-09")])
    }

    func testOnlyDaysInsideTheRangeAreMarkedAndBothEndsCount() {
        let doses = [
            dose("D1", medication: vialID, at: "2026-03-18T12:00:00Z", amount: "1"),
            dose("D2", medication: vialID, at: "2026-03-19T12:00:00Z", amount: "1"),
            dose("D3", medication: vialID, at: "2026-04-15T12:00:00Z", amount: "1"),
            dose("D4", medication: vialID, at: "2026-04-16T12:00:00Z", amount: "1"),
        ]

        let markers = DoseDayMarkers.markers(
            medications: medications, doses: doses, from: day("2026-03-19"), through: day("2026-04-15"))

        XCTAssertEqual(markers.map(\.day), [day("2026-03-19"), day("2026-04-15")])
    }

    func testArchivedMedicationsCountAndUnknownOnesOrUnreadableDaysAreLeftOut() {
        let archived = [
            Medication(id: vialID, name: "Example vial", unit: .mg, isArchived: true),
        ]
        let doses = [
            dose("E1", medication: vialID, at: "2026-04-05T12:00:00Z", amount: "3"),
            dose("E2", medication: penID, at: "2026-04-06T12:00:00Z", amount: "4", unit: .units),
            dose("E3", medication: vialID, at: "2026-04-07T12:00:00Z", zone: "Not/AZone", amount: "5"),
        ]

        let markers = DoseDayMarkers.markers(
            medications: archived, doses: doses, from: day("2026-03-19"), through: day("2026-04-15"))

        XCTAssertEqual(markers, [
            DoseDayMarker(day: day("2026-04-05"), entries: [
                DoseDayMarker.Entry(name: "Example vial", amount: 3, unit: .mg),
            ]),
        ])
    }

    func testAnEntryKeepsTheUnitTheDoseWasLoggedIn() {
        // The medication is measured in mcg now; the dose was logged in mg before the change.
        let changed = [Medication(id: vialID, name: "Example vial", unit: .mcg)]
        let doses = [dose("F1", medication: vialID, at: "2026-04-08T12:00:00Z", amount: "0.25", unit: .mg)]

        let markers = DoseDayMarkers.markers(
            medications: changed, doses: doses, from: day("2026-03-19"), through: day("2026-04-15"))

        XCTAssertEqual(markers.first?.entries.first?.unit, .mg)
    }

    func testNoDosesGiveNoMarkers() {
        XCTAssertEqual(
            DoseDayMarkers.markers(medications: medications, doses: [], from: day("2026-03-19"), through: day("2026-04-15")),
            [])
    }
}
