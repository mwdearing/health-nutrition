import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// An instant from its ISO 8601 text, outside the main actor so the clock closures below can call it.
private func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

/// One medication's history: its doses newest first, each read in the zone it was logged in, with its amount and
/// note. A dose's site is never shown. The person can correct a dose's amount, time or note, or delete it after a
/// confirmation; nothing here offers a view on a dose.
@MainActor
final class MedicationHistoryTests: XCTestCase {
    private let vial = Medication(name: "Example vial", unit: .mg, scheduleDays: 7)
    private let pen = Medication(name: "Example pen", unit: .units, isArchived: true)

    private func dose(
        _ medication: Medication, _ at: String, zone: String = "UTC", amount: Decimal, site: String? = nil,
        note: String? = nil
    ) -> MedicationDose {
        MedicationDose(
            medicationID: medication.id, takenAt: instant(at), timeZoneIdentifier: zone, amount: amount,
            unit: medication.unit, site: site, note: note)
    }

    private func model(_ store: MedicationStore, _ medication: Medication) -> MedicationHistoryViewModel {
        let model = MedicationHistoryViewModel(
            store: store, medicationID: medication.id, now: { instant("2026-04-15T12:00:00Z") },
            timeZone: { TimeZone(identifier: "UTC")! })
        model.load()
        return model
    }

    // MARK: - Reading

    func testRowsAreTheMedicationsDosesNewestFirstInTheirOwnZone() {
        let older = dose(vial, "2026-04-03T18:00:00Z", amount: 2.5, note: "After lunch")
        let newer = dose(vial, "2026-04-11T03:00:00Z", zone: "America/Chicago", amount: 5)
        let other = dose(pen, "2026-04-12T08:00:00Z", amount: 1000)
        let store = InMemoryMedicationStore(medications: [vial, pen], doses: [older, newer, other])

        let history = model(store, vial)

        XCTAssertEqual(history.title, "Example vial")
        XCTAssertNil(history.errorMessage)
        XCTAssertEqual(history.rows.map(\.id), [newer.id, older.id])
        XCTAssertEqual(history.rows[0].dayText, "Apr 10, 2026", "read in the zone the dose was logged in")
        XCTAssertEqual(history.rows[0].timeText, "10:00 PM")
        XCTAssertEqual(history.rows[0].amountText, "5 mg")
        XCTAssertNil(history.rows[0].noteText)
        XCTAssertEqual(history.rows[1].dayText, "Apr 3, 2026")
        XCTAssertEqual(history.rows[1].timeText, "6:00 PM")
        XCTAssertEqual(history.rows[1].amountText, "2.5 mg")
        XCTAssertEqual(history.rows[1].noteText, "After lunch")
    }

    func testAnArchivedMedicationKeepsItsHistory() {
        let large = dose(pen, "2026-04-12T08:00:00Z", amount: 1000)
        let history = model(InMemoryMedicationStore(medications: [vial, pen], doses: [large]), pen)

        XCTAssertEqual(history.title, "Example pen")
        XCTAssertEqual(history.rows.map(\.amountText), ["1,000 units"])
    }

    func testASiteIsNeverShown() {
        let withSite = dose(vial, "2026-04-10T18:00:00Z", amount: 2.5, site: "Left side", note: "Fine")
        let history = model(InMemoryMedicationStore(medications: [vial], doses: [withSite]), vial)

        let row = history.rows[0]
        for text in [row.dayText, row.timeText, row.amountText, row.noteText ?? ""] {
            XCTAssertFalse(text.contains("Left"), text)
        }
    }

    func testANoDoseHistoryIsEmptyWithoutAMessage() {
        let history = model(InMemoryMedicationStore(medications: [vial]), vial)
        XCTAssertEqual(history.rows, [])
        XCTAssertNil(history.errorMessage)
    }

    func testAFailedReadShowsAMessageAndNoRows() {
        let history = model(InMemoryMedicationStore(medications: [vial], failReads: true), vial)
        XCTAssertEqual(history.rows, [])
        XCTAssertEqual(history.errorMessage, "Could not read the medication log.")
    }

    func testAMedicationThatIsGoneShowsAMessage() {
        let history = model(InMemoryMedicationStore(medications: [pen]), vial)
        XCTAssertEqual(history.rows, [])
        XCTAssertEqual(history.errorMessage, "This medication is no longer in the list.")
    }

    // MARK: - Editing

    func testTheDraftHoldsTheStoredAmountTimeAndNote() throws {
        let stored = dose(vial, "2026-04-10T18:00:00Z", amount: 2.5, note: "After lunch")
        let history = model(InMemoryMedicationStore(medications: [vial], doses: [stored]), vial)

        let draft = try XCTUnwrap(history.draft(for: stored.id))
        XCTAssertEqual(draft.amountText, "2.5")
        XCTAssertEqual(draft.takenAt, stored.takenAt)
        XCTAssertEqual(draft.noteText, "After lunch")
        XCTAssertNil(history.draft(for: UUID()))
    }

    func testAnEditKeepsTheDoseItsUnitSiteAndZoneWhenTheTimeIsUnchanged() throws {
        let stored = dose(vial, "2026-04-11T03:00:00Z", zone: "America/Chicago", amount: 2.5, site: "Left side")
        let store = InMemoryMedicationStore(medications: [vial], doses: [stored])
        let history = model(store, vial)

        XCTAssertNil(history.saveEdit(doseID: stored.id, amountText: "3.75", takenAt: stored.takenAt, noteText: " Late "))

        let saved = try XCTUnwrap(try store.doses(of: vial.id).first)
        XCTAssertEqual(try store.doses(of: vial.id).count, 1)
        XCTAssertEqual(saved.id, stored.id)
        XCTAssertEqual(saved.amount, Decimal(string: "3.75"))
        XCTAssertEqual(saved.unit, .mg)
        XCTAssertEqual(saved.site, "Left side", "an edit never drops the site it does not show")
        XCTAssertEqual(saved.note, "Late")
        XCTAssertEqual(saved.timeZoneIdentifier, "America/Chicago")
        XCTAssertTrue(history.didChange)
        XCTAssertEqual(history.rows.map(\.amountText), ["3.75 mg"])
    }

    func testAChangedTimeTakesTheDevicesZone() throws {
        let stored = dose(vial, "2026-04-11T03:00:00Z", zone: "America/Chicago", amount: 2.5)
        let store = InMemoryMedicationStore(medications: [vial], doses: [stored])
        let history = model(store, vial)

        XCTAssertNil(history.saveEdit(
            doseID: stored.id, amountText: "2.5", takenAt: instant("2026-04-10T09:30:00Z"), noteText: ""))

        let saved = try XCTUnwrap(try store.doses(of: vial.id).first)
        XCTAssertEqual(saved.takenAt, instant("2026-04-10T09:30:00Z"))
        XCTAssertEqual(saved.timeZoneIdentifier, TimeZone(identifier: "UTC")!.identifier, "the device's zone, as it names itself")
        XCTAssertNil(saved.note)
        XCTAssertEqual(history.rows.first?.timeText, "9:30 AM")
    }

    func testAnEditThatBreaksARuleSavesNothing() throws {
        let stored = dose(vial, "2026-04-10T18:00:00Z", amount: 2.5)
        let store = InMemoryMedicationStore(medications: [vial], doses: [stored])
        let history = model(store, vial)

        XCTAssertEqual(history.saveEdit(doseID: stored.id, amountText: "0", takenAt: stored.takenAt, noteText: ""),
                       "Enter an amount above 0.")
        XCTAssertEqual(history.saveEdit(doseID: stored.id, amountText: "", takenAt: stored.takenAt, noteText: ""),
                       "Enter an amount above 0.")
        XCTAssertEqual(history.saveEdit(doseID: stored.id, amountText: "1001", takenAt: stored.takenAt, noteText: ""),
                       "Enter 1000 or less.")
        XCTAssertEqual(history.saveEdit(doseID: stored.id, amountText: "1.2345", takenAt: stored.takenAt, noteText: ""),
                       "Use up to 3 decimal places.")
        XCTAssertEqual(try store.doses(of: vial.id), [stored])
        XCTAssertFalse(history.didChange)
    }

    func testAnEditOfADoseThatIsGoneSavesNothing() throws {
        let store = InMemoryMedicationStore(medications: [vial])
        let history = model(store, vial)

        XCTAssertEqual(history.saveEdit(doseID: UUID(), amountText: "2.5", takenAt: Date(), noteText: ""),
                       "This dose is no longer in the log.")
        XCTAssertEqual(try store.allDoses(), [])
    }

    func testAnEditTheStoreRefusesShowsAMessage() {
        let stored = dose(vial, "2026-04-10T18:00:00Z", amount: 2.5)
        let store = InMemoryMedicationStore(medications: [vial], doses: [stored], refusesWrites: true)
        let history = model(store, vial)

        XCTAssertEqual(history.saveEdit(doseID: stored.id, amountText: "3", takenAt: stored.takenAt, noteText: ""),
                       "Could not save the dose.")
        XCTAssertFalse(history.didChange)
    }

    // MARK: - Deleting

    func testDeletingRemovesOnlyThatDose() throws {
        let first = dose(vial, "2026-04-03T18:00:00Z", amount: 2.5)
        let second = dose(vial, "2026-04-10T18:00:00Z", amount: 5)
        let store = InMemoryMedicationStore(medications: [vial], doses: [first, second])
        let history = model(store, vial)

        history.deleteDose(id: second.id)

        XCTAssertEqual(try store.doses(of: vial.id), [first])
        XCTAssertEqual(history.rows.map(\.id), [first.id])
        XCTAssertNil(history.errorMessage)
        XCTAssertTrue(history.didChange)
    }

    func testADeleteTheStoreRefusesKeepsTheDoseAndShowsAMessage() throws {
        let stored = dose(vial, "2026-04-10T18:00:00Z", amount: 2.5)
        let store = InMemoryMedicationStore(medications: [vial], doses: [stored], refusesWrites: true)
        let history = model(store, vial)

        history.deleteDose(id: stored.id)

        XCTAssertEqual(try store.doses(of: vial.id), [stored])
        XCTAssertEqual(history.rows.map(\.id), [stored.id])
        XCTAssertEqual(history.errorMessage, "Could not delete the dose.")
        XCTAssertFalse(history.didChange)
    }

    // MARK: - Back on the list

    func testAChangedHistoryWithdrawsTheListsUndoAndReadsAgain() throws {
        let store = InMemoryMedicationStore(medications: [vial])
        let list = MedicationLogViewModel(
            store: store, preferences: InMemoryDisplayPreferences(), now: { instant("2026-04-15T12:00:00Z") },
            timeZone: { TimeZone(identifier: "UTC")! })
        list.load()
        XCTAssertNil(list.logDose(
            medicationID: vial.id, amountText: "2.5", takenAt: instant("2026-04-15T08:00:00Z"), siteText: "",
            noteText: ""))
        XCTAssertNotNil(list.undoText)
        let logged = try XCTUnwrap(try store.allDoses().first)

        let history = model(store, vial)
        history.deleteDose(id: logged.id)
        list.historyChanged()

        XCTAssertNil(list.undoText, "Undo never names a dose the history changed")
        XCTAssertEqual(list.rows.first?.lastDoseText, "No dose logged yet")
    }
}
