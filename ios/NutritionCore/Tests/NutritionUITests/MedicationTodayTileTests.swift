import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The Medications tile on Today: shown only while the Medication log is on, one line per active medication with its
/// schedule standing or days since the last dose, at most three lines and a count of the rest. Plain facts only; the
/// site and the note are never shown.
@MainActor
final class MedicationTodayTileTests: XCTestCase {
    /// 2026-04-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_776_254_400)
    private let day: TimeInterval = 86_400
    private let utc = TimeZone(identifier: "UTC")!

    private func makeModel(_ store: MedicationStore, on: Bool = true) -> MedicationLogViewModel {
        let preferences = InMemoryDisplayPreferences()
        let fixed = now
        let zone = utc
        let model = MedicationLogViewModel(store: store, preferences: preferences, now: { fixed }, timeZone: { zone })
        model.isOn = on
        model.load()
        return model
    }

    private func dose(of medication: Medication, daysAgo: Double, site: String? = nil, note: String? = nil)
        -> MedicationDose
    {
        MedicationDose(
            medicationID: medication.id, takenAt: now.addingTimeInterval(-daysAgo * day), timeZoneIdentifier: "UTC",
            amount: 2.5, unit: medication.unit, site: site, note: note)
    }

    func testTheTileIsHiddenWhileTheLogIsOff() {
        let medication = Medication(name: "Example vial", unit: .mL)
        let model = makeModel(
            InMemoryMedicationStore(medications: [medication], doses: [dose(of: medication, daysAgo: 1)]), on: false)
        XCTAssertNil(MedicationTodayTileContent.make(from: model))
    }

    func testWithNoMedicationTheTileOffersToAddOne() {
        let content = MedicationTodayTileContent.make(from: makeModel(InMemoryMedicationStore()))
        XCTAssertEqual(content?.lines, ["Add a medication"])
    }

    func testAReadFailureSaysTheLogCannotBeRead() {
        let model = makeModel(InMemoryMedicationStore(
            medications: [Medication(name: "Example vial", unit: .mL)], failReads: true))
        XCTAssertEqual(MedicationTodayTileContent.make(from: model)?.lines, ["Could not read the medication log."])
    }

    func testEachLineShowsTheStandingOrElseTheDaysSince() {
        let weekly = Medication(name: "Example weekly injection", unit: .mg, scheduleDays: 7)
        let due = Medication(name: "Example due", unit: .mg, scheduleDays: 7)
        let late = Medication(name: "Example late", unit: .mg, scheduleDays: 7)
        let vial = Medication(name: "Example vial", unit: .mL)
        let cream = Medication(name: "Example cream", unit: .units)
        let store = InMemoryMedicationStore(
            medications: [weekly, due, late, vial, cream],
            doses: [
                dose(of: weekly, daysAgo: 1), dose(of: due, daysAgo: 7), dose(of: late, daysAgo: 8),
                dose(of: vial, daysAgo: 0.1),
            ])
        let lines = MedicationTodayTileContent.lines(for: makeModel(store).rows)
        XCTAssertEqual(lines, [
            "Example cream: No dose logged yet",
            "Example due: Due today",
            "Example late: Overdue by 1 day",
            "Example vial: Today",
            "Example weekly injection: Next by your schedule: Apr 21, 2026",
        ])
    }

    func testAtMostThreeLinesAndACountOfTheRest() {
        let names = ["Example a", "Example b", "Example c", "Example d", "Example e"]
        let store = InMemoryMedicationStore(medications: names.map { Medication(name: $0, unit: .mg) })
        let content = MedicationTodayTileContent.make(from: makeModel(store))
        XCTAssertEqual(MedicationTodayTileContent.lineLimit, 3)
        XCTAssertEqual(content?.lines, [
            "Example a: No dose logged yet", "Example b: No dose logged yet", "Example c: No dose logged yet",
            "2 more",
        ])
    }

    func testExactlyThreeMedicationsShowNoCount() {
        let names = ["Example a", "Example b", "Example c"]
        let store = InMemoryMedicationStore(medications: names.map { Medication(name: $0, unit: .mg) })
        XCTAssertEqual(MedicationTodayTileContent.make(from: makeModel(store))?.lines.count, 3)
    }

    func testOneMoreIsCountedToo() {
        let names = ["Example a", "Example b", "Example c", "Example d"]
        let store = InMemoryMedicationStore(medications: names.map { Medication(name: $0, unit: .mg) })
        XCTAssertEqual(MedicationTodayTileContent.make(from: makeModel(store))?.lines.last, "1 more")
    }

    func testArchivedMedicationsAreLeftOut() {
        let active = Medication(name: "Example active", unit: .mg)
        let archived = Medication(name: "Example archived", unit: .mg, isArchived: true)
        let store = InMemoryMedicationStore(medications: [active, archived], doses: [dose(of: archived, daysAgo: 2)])
        XCTAssertEqual(MedicationTodayTileContent.make(from: makeModel(store))?.lines, [
            "Example active: No dose logged yet",
        ])
    }

    func testOnlyArchivedMedicationsStillOfferToAddOne() {
        let archived = Medication(name: "Example archived", unit: .mg, isArchived: true)
        let content = MedicationTodayTileContent.make(from: makeModel(InMemoryMedicationStore(medications: [archived])))
        XCTAssertEqual(content?.lines, ["Add a medication"])
    }

    func testTheSiteAndTheNoteAreNeverShown() {
        let medication = Medication(name: "Example vial", unit: .mL)
        let store = InMemoryMedicationStore(
            medications: [medication],
            doses: [dose(of: medication, daysAgo: 1, site: "Example site", note: "Example note")])
        let content = MedicationTodayTileContent.make(from: makeModel(store))
        let text = (content?.lines ?? []).joined(separator: " ") + " " + (content?.accessibilityText ?? "")
        XCTAssertFalse(text.contains("Example site"))
        XCTAssertFalse(text.contains("Example note"))
        XCTAssertEqual(content?.lines, ["Example vial: 1 day since"])
    }

    func testTheSpokenTextNamesTheTileAndReadsEveryLine() {
        let medication = Medication(name: "Example vial", unit: .mL)
        let store = InMemoryMedicationStore(medications: [medication], doses: [dose(of: medication, daysAgo: 0.1)])
        XCTAssertEqual(
            MedicationTodayTileContent.make(from: makeModel(store))?.accessibilityText,
            "Medications, Example vial: Today")
    }

    func testTheTileFollowsTheSwitch() {
        let medication = Medication(name: "Example vial", unit: .mL)
        let model = makeModel(InMemoryMedicationStore(medications: [medication]), on: false)
        XCTAssertNil(MedicationTodayTileContent.make(from: model))
        model.isOn = true
        XCTAssertEqual(MedicationTodayTileContent.make(from: model)?.lines, ["Example vial: No dose logged yet"])
        model.isOn = false
        XCTAssertNil(MedicationTodayTileContent.make(from: model))
    }

    func testTheTitleAndHintAreFixed() {
        XCTAssertEqual(MedicationTodayTileContent.title, "Medications")
        XCTAssertEqual(MedicationTodayTileContent.accessibilityHint, "Opens your medication log")
    }
}
