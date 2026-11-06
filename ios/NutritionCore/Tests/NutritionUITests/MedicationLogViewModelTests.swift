import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The Medication log screens: the list of medications with their last dose and schedule standing, adding a
/// medication, logging a dose with Undo, archiving, the Settings switch and the erase wiring. Plain facts
/// only; nothing here suggests, checks or changes a dose.
@MainActor
final class MedicationLogViewModelTests: XCTestCase {
    /// 2026-04-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_776_254_400)
    private let day: TimeInterval = 86_400
    private let utc = TimeZone(identifier: "UTC")!

    private func makeModel(
        _ store: MedicationStore, preferences: DisplayPreferences = InMemoryDisplayPreferences(),
        zone: TimeZone? = nil
    ) -> MedicationLogViewModel {
        let fixed = now
        let zone = zone ?? utc
        return MedicationLogViewModel(store: store, preferences: preferences, now: { fixed }, timeZone: { zone })
    }

    private func weekly(_ id: UUID = UUID(), archived: Bool = false) -> Medication {
        Medication(id: id, name: "Example weekly injection", unit: .mg, scheduleDays: 7, isArchived: archived)
    }

    private func dose(
        of medication: Medication, at seconds: TimeInterval, amount: String = "2.5", zone: String = "UTC"
    ) -> MedicationDose {
        MedicationDose(
            medicationID: medication.id, takenAt: Date(timeIntervalSince1970: seconds), timeZoneIdentifier: zone,
            amount: Decimal(string: amount)!, unit: medication.unit)
    }

    // MARK: - The list

    func testAMedicationWithoutDosesShowsNoDoseYetAndNoStanding() {
        let medication = Medication(name: "Example vial", unit: .mL)
        let model = makeModel(InMemoryMedicationStore(medications: [medication]))
        model.load()
        XCTAssertEqual(model.rows, [MedicationRow(
            id: medication.id, name: "Example vial", unitText: "mL", scheduleText: nil,
            lastDoseText: "No dose logged yet", daysSinceText: nil, statusText: nil, isArchived: false)])
        XCTAssertNil(model.errorMessage)
    }

    func testTheLastDoseShowsAmountDayAndTimeAndDaysSince() {
        let medication = weekly()
        // 2026-04-14 09:30 UTC.
        let model = makeModel(InMemoryMedicationStore(
            medications: [medication], doses: [dose(of: medication, at: 1_776_159_000)]))
        model.load()
        let row = model.rows.first
        XCTAssertEqual(row?.lastDoseText, "Last dose 2.5 mg on Apr 14, 2026 at 9:30 AM")
        XCTAssertEqual(row?.daysSinceText, "1 day since")
        XCTAssertEqual(row?.scheduleText, "Every 7 days")
        XCTAssertEqual(row?.statusText, "Next by your schedule: Apr 21, 2026")
    }

    func testTheNewestDoseIsTheLastDose() {
        let medication = weekly()
        let older = dose(of: medication, at: 1_775_390_400, amount: "1")
        let newer = dose(of: medication, at: 1_776_159_000, amount: "2.5")
        let model = makeModel(InMemoryMedicationStore(medications: [medication], doses: [newer, older]))
        model.load()
        XCTAssertEqual(model.rows.first?.lastDoseText, "Last dose 2.5 mg on Apr 14, 2026 at 9:30 AM")
    }

    func testADoseTakenTodayReadsToday() {
        let medication = weekly()
        // 2026-04-15 08:00 UTC.
        let model = makeModel(InMemoryMedicationStore(
            medications: [medication], doses: [dose(of: medication, at: 1_776_240_000)]))
        model.load()
        XCTAssertEqual(model.rows.first?.daysSinceText, "Today")
        XCTAssertEqual(model.rows.first?.lastDoseText, "Last dose 2.5 mg on Apr 15, 2026 at 8:00 AM")
        XCTAssertEqual(model.rows.first?.statusText, "Next by your schedule: Apr 22, 2026")
    }

    func testDueTodayOnTheScheduledDay() {
        let medication = weekly()
        // 2026-04-08 12:00 UTC, seven days before now.
        let model = makeModel(InMemoryMedicationStore(
            medications: [medication], doses: [dose(of: medication, at: now.timeIntervalSince1970 - 7 * day)]))
        model.load()
        XCTAssertEqual(model.rows.first?.statusText, "Due today")
        XCTAssertEqual(model.rows.first?.daysSinceText, "7 days since")
    }

    func testOverdueCountsWholeDaysWithOneAndMany() {
        let one = Medication(name: "Example a", unit: .mg, scheduleDays: 7)
        let three = Medication(name: "Example b", unit: .mg, scheduleDays: 7)
        let model = makeModel(InMemoryMedicationStore(
            medications: [one, three],
            doses: [
                dose(of: one, at: now.timeIntervalSince1970 - 8 * day),
                dose(of: three, at: now.timeIntervalSince1970 - 10 * day),
            ]))
        model.load()
        XCTAssertEqual(model.rows.map(\.statusText), ["Overdue by 1 day", "Overdue by 3 days"])
    }

    func testAScheduleOfOneDayReadsEveryDay() {
        let medication = Medication(name: "Example daily tablet", unit: .mcg, scheduleDays: 1)
        let model = makeModel(InMemoryMedicationStore(medications: [medication]))
        model.load()
        XCTAssertEqual(model.rows.first?.scheduleText, "Every day")
        XCTAssertEqual(model.rows.first?.unitText, "mcg")
    }

    func testAScheduledMedicationWithNoDoseHasNoStandingLine() {
        let model = makeModel(InMemoryMedicationStore(medications: [weekly()]))
        model.load()
        XCTAssertEqual(model.rows.first?.lastDoseText, "No dose logged yet")
        XCTAssertNil(model.rows.first?.statusText)
    }

    func testTheDoseTimeIsShownInTheDosesOwnZoneAndTodayInTheDevicesZone() {
        let medication = Medication(name: "Example vial", unit: .units)
        // 2026-04-15 03:00 UTC is Apr 14 10:00 PM in Chicago; now is Apr 15 7:00 AM there.
        let model = makeModel(
            InMemoryMedicationStore(
                medications: [medication],
                doses: [dose(of: medication, at: 1_776_222_000, amount: "10", zone: "America/Chicago")]),
            zone: TimeZone(identifier: "America/Chicago")!)
        model.load()
        XCTAssertEqual(model.rows.first?.lastDoseText, "Last dose 10 units on Apr 14, 2026 at 10:00 PM")
        XCTAssertEqual(model.rows.first?.daysSinceText, "1 day since")

        // The same dose read on a device set to UTC keeps the time it was taken at, where it was taken.
        let elsewhere = makeModel(InMemoryMedicationStore(
            medications: [medication],
            doses: [dose(of: medication, at: 1_776_222_000, amount: "10", zone: "America/Chicago")]))
        elsewhere.load()
        XCTAssertEqual(elsewhere.rows.first?.lastDoseText, "Last dose 10 units on Apr 14, 2026 at 10:00 PM")
    }

    func testArchivedMedicationsAreListedApartWithNoStanding() {
        let active = Medication(name: "Example b", unit: .mg)
        let archived = weekly(archived: true)
        let model = makeModel(InMemoryMedicationStore(
            medications: [active, archived], doses: [dose(of: archived, at: now.timeIntervalSince1970 - 30 * day)]))
        model.load()
        XCTAssertEqual(model.rows.map(\.name), ["Example b"])
        XCTAssertEqual(model.archivedRows.map(\.name), ["Example weekly injection"])
        XCTAssertEqual(model.archivedRows.first?.isArchived, true)
        XCTAssertNil(model.archivedRows.first?.statusText)
        XCTAssertEqual(model.archivedRows.first?.lastDoseText, "Last dose 2.5 mg on Mar 16, 2026 at 12:00 PM")
    }

    func testRowsFollowTheStoresOrder() {
        let model = makeModel(InMemoryMedicationStore(medications: [
            Medication(name: "example c", unit: .mg), Medication(name: "Example A", unit: .mg),
            Medication(name: "Example b", unit: .mg),
        ]))
        model.load()
        XCTAssertEqual(model.rows.map(\.name), ["Example A", "Example b", "example c"])
    }

    func testAReadFailureShowsAMessageAndNoRows() {
        let model = makeModel(InMemoryMedicationStore(medications: [weekly()], failReads: true))
        model.load()
        XCTAssertEqual(model.rows, [])
        XCTAssertEqual(model.archivedRows, [])
        XCTAssertEqual(model.errorMessage, "Could not read the medication log.")
    }

    func testTheSiteIsNeverShownInTheList() {
        let medication = weekly()
        let withSite = MedicationDose(
            medicationID: medication.id, takenAt: Date(timeIntervalSince1970: 1_776_159_000),
            timeZoneIdentifier: "UTC", amount: 2.5, unit: .mg, site: "Example site", note: "Example note")
        let model = makeModel(InMemoryMedicationStore(medications: [medication], doses: [withSite]))
        model.load()
        let texts = model.rows.flatMap { [$0.lastDoseText, $0.daysSinceText, $0.statusText, $0.scheduleText] }
        XCTAssertFalse(texts.contains { $0?.contains("Example site") == true })
        XCTAssertFalse(texts.contains { $0?.contains("Example note") == true })
    }

    // MARK: - Adding a medication

    func testAddingTrimsTheNameAndReadsTheSchedule() throws {
        let store = InMemoryMedicationStore()
        let model = makeModel(store)
        XCTAssertNil(model.addMedication(name: "  Example weekly injection ", unit: .mg, scheduleDaysText: " 7 "))
        let saved = try store.medications()
        XCTAssertEqual(saved.map(\.name), ["Example weekly injection"])
        XCTAssertEqual(saved.first?.scheduleDays, 7)
        XCTAssertEqual(saved.first?.unit, .mg)
        XCTAssertEqual(model.rows.map(\.name), ["Example weekly injection"])
    }

    func testAnEmptyScheduleMeansNoSchedule() throws {
        let store = InMemoryMedicationStore()
        XCTAssertNil(makeModel(store).addMedication(name: "Example vial", unit: .units, scheduleDaysText: "  "))
        XCTAssertNil(try store.medications().first?.scheduleDays)
    }

    func testAddingRefusalsNameTheProblemAndSaveNothing() throws {
        let store = InMemoryMedicationStore(medications: [weekly()])
        let model = makeModel(store)
        XCTAssertEqual(model.addMedication(name: "   ", unit: .mg, scheduleDaysText: ""), "Enter a name.")
        XCTAssertEqual(
            model.addMedication(name: "Example\nvial", unit: .mg, scheduleDaysText: ""), "Use one line for the name.")
        XCTAssertEqual(
            model.addMedication(name: String(repeating: "x", count: 61), unit: .mg, scheduleDaysText: ""),
            "Use 60 characters or fewer.")
        for text in ["0", "29", "7.5", "seven"] {
            XCTAssertEqual(
                model.addMedication(name: "Example vial", unit: .mg, scheduleDaysText: text),
                "Enter a whole number of days from 1 to 28.", text)
        }
        XCTAssertEqual(
            model.addMedication(name: "example WEEKLY injection", unit: .mcg, scheduleDaysText: ""),
            "A medication with this name is already in the list.")
        XCTAssertEqual(try store.medications().count, 1)
    }

    func testAStoreThatRefusesTheSaveSaysSo() {
        let model = makeModel(InMemoryMedicationStore(refusesWrites: true))
        XCTAssertEqual(
            model.addMedication(name: "Example vial", unit: .mg, scheduleDaysText: ""), "Could not save the medication.")
    }

    // MARK: - Logging a dose

    func testLoggingSavesTheTypedDoseInTheMedicationsUnitAndOffersUndo() throws {
        let medication = weekly()
        let store = InMemoryMedicationStore(medications: [medication])
        let model = makeModel(store)
        model.load()
        let takenAt = Date(timeIntervalSince1970: 1_776_159_000)
        XCTAssertNil(model.logDose(
            medicationID: medication.id, amountText: " 2.5 ", takenAt: takenAt, siteText: " Example site ",
            noteText: ""))
        let saved = try store.allDoses()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.amount, Decimal(string: "2.5"))
        XCTAssertEqual(saved.first?.unit, .mg)
        XCTAssertEqual(saved.first?.takenAt, takenAt)
        XCTAssertEqual(saved.first?.timeZoneIdentifier, utc.identifier)
        XCTAssertEqual(saved.first?.site, "Example site")
        XCTAssertNil(saved.first?.note)
        XCTAssertEqual(model.undoText, "Logged 2.5 mg of Example weekly injection")
        XCTAssertEqual(model.rows.first?.lastDoseText, "Last dose 2.5 mg on Apr 14, 2026 at 9:30 AM")
    }

    func testTheDoseTakesTheDevicesZone() throws {
        let medication = weekly()
        let store = InMemoryMedicationStore(medications: [medication])
        let model = makeModel(store, zone: TimeZone(identifier: "America/Chicago")!)
        XCTAssertNil(model.logDose(
            medicationID: medication.id, amountText: "1", takenAt: now, siteText: "", noteText: " Example note "))
        XCTAssertEqual(try store.allDoses().first?.timeZoneIdentifier, "America/Chicago")
        XCTAssertEqual(try store.allDoses().first?.note, "Example note")
        XCTAssertNil(try store.allDoses().first?.site)
    }

    func testUndoRemovesOnlyTheDoseJustLogged() throws {
        let medication = weekly()
        let earlier = dose(of: medication, at: 1_775_390_400, amount: "1")
        let store = InMemoryMedicationStore(medications: [medication], doses: [earlier])
        let model = makeModel(store)
        model.load()
        XCTAssertNil(model.logDose(
            medicationID: medication.id, amountText: "2.5", takenAt: now, siteText: "", noteText: ""))
        model.undoLastDose()
        XCTAssertEqual(try store.allDoses().map(\.id), [earlier.id])
        XCTAssertNil(model.undoText)
        XCTAssertEqual(model.rows.first?.lastDoseText, "Last dose 1 mg on Apr 5, 2026 at 12:00 PM")
    }

    func testDoseRefusalsNameTheProblemAndSaveNothing() throws {
        let medication = weekly()
        let store = InMemoryMedicationStore(medications: [medication])
        let model = makeModel(store)
        func log(_ amount: String, site: String = "", note: String = "") -> String? {
            model.logDose(medicationID: medication.id, amountText: amount, takenAt: now, siteText: site, noteText: note)
        }
        XCTAssertEqual(log(""), "Enter an amount above 0.")
        XCTAssertEqual(log("abc"), "Enter an amount above 0.")
        XCTAssertEqual(log("0"), "Enter an amount above 0.")
        XCTAssertEqual(log("1000.5"), "Enter 1000 or less.")
        XCTAssertEqual(log("0.1234"), "Use up to 3 decimal places.")
        XCTAssertEqual(log("1", site: "Example\nsite"), "Use one line for the site.")
        XCTAssertEqual(log("1", site: String(repeating: "s", count: 41)), "Use 40 characters or fewer for the site.")
        XCTAssertEqual(log("1", note: String(repeating: "n", count: 201)), "Use 200 characters or fewer for the note.")
        XCTAssertEqual(
            model.logDose(medicationID: UUID(), amountText: "1", takenAt: now, siteText: "", noteText: ""),
            "This medication is no longer in the list.")
        XCTAssertEqual(try store.allDoses(), [])
        XCTAssertNil(model.undoText)
    }

    func testAStoreThatRefusesTheDoseSaysSo() {
        let medication = weekly()
        let model = makeModel(InMemoryMedicationStore(medications: [medication], refusesWrites: true))
        XCTAssertEqual(
            model.logDose(medicationID: medication.id, amountText: "1", takenAt: now, siteText: "", noteText: ""),
            "Could not save the dose.")
        XCTAssertNil(model.undoText)
    }

    // MARK: - Archiving

    func testArchivingKeepsTheDosesAndUnarchivingBringsTheRowBack() throws {
        let medication = weekly()
        let kept = dose(of: medication, at: 1_776_159_000)
        let store = InMemoryMedicationStore(medications: [medication], doses: [kept])
        let model = makeModel(store)
        model.load()
        model.setArchived(medication.id, archived: true)
        XCTAssertEqual(try store.medications().first?.isArchived, true)
        XCTAssertEqual(try store.medications().first?.scheduleDays, 7)
        XCTAssertEqual(try store.allDoses().map(\.id), [kept.id])
        XCTAssertEqual(model.rows, [])
        XCTAssertEqual(model.archivedRows.map(\.id), [medication.id])
        model.setArchived(medication.id, archived: false)
        XCTAssertEqual(model.rows.map(\.id), [medication.id])
        XCTAssertEqual(model.rows.first?.statusText, "Next by your schedule: Apr 21, 2026")
    }

    // MARK: - The Settings switch

    func testTheSwitchIsOffByDefaultAndKeptInThePreferences() {
        let preferences = InMemoryDisplayPreferences()
        let model = makeModel(InMemoryMedicationStore(), preferences: preferences)
        XCTAssertFalse(model.isOn)
        model.isOn = true
        XCTAssertTrue(preferences.isMedicationLogOn)
        XCTAssertTrue(model.isOn)
        model.isOn = false
        XCTAssertFalse(preferences.isMedicationLogOn)
    }

    func testTurningTheLogOffKeepsTheData() throws {
        let preferences = InMemoryDisplayPreferences()
        let store = InMemoryMedicationStore(medications: [weekly()])
        let model = makeModel(store, preferences: preferences)
        model.isOn = true
        model.isOn = false
        XCTAssertEqual(try store.medications().count, 1)
    }

    func testEraseResetsTheSwitch() {
        let memory = InMemoryDisplayPreferences()
        memory.setMedicationLogOn(true)
        memory.resetToDefaults()
        XCTAssertFalse(memory.isMedicationLogOn)

        let suite = "medication-log-switch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = UserDefaultsDisplayPreferences(defaults: defaults)
        XCTAssertFalse(stored.isMedicationLogOn)
        stored.setMedicationLogOn(true)
        XCTAssertTrue(defaults.bool(forKey: "display.medicationLog.on"))
        XCTAssertTrue(UserDefaultsDisplayPreferences(defaults: defaults).isMedicationLogOn)
        stored.resetToDefaults()
        XCTAssertNil(defaults.object(forKey: "display.medicationLog.on"))
        XCTAssertFalse(stored.isMedicationLogOn)
    }

    func testPreferencesWithoutTheSwitchReadOffAndIgnoreChanges() {
        let model = makeModel(InMemoryMedicationStore(), preferences: PlainPreferences())
        model.isOn = true
        XCTAssertFalse(model.isOn)
    }

    // MARK: - Erase all data

    func testTheEraseOrderEndsWithTheMedicationStore() {
        let names = ["widget data", "saved meals", "supplements", "reminders", "journal", "favorites", "recipes", "goals"]
        let erasers = names.map(MedicationEraseProbe.init)
        let medications = MedicationEraseProbe("medications")
        let order = ConnectionsPrivacyViewModel.eraseOrder(ConnectionsPrivacyViewModel.EraseStores(
            widgets: erasers[0], savedMeals: erasers[1], supplements: erasers[2], reminders: [erasers[3]],
            journal: erasers[4], favorites: erasers[5], recipes: erasers[6], goals: erasers[7],
            medications: medications))
        XCTAssertEqual(order.map(\.erasureName), names + ["medications"])
        XCTAssertTrue(order.last === medications)
    }
}

/// Display preferences that keep no Medication log switch.
private final class PlainPreferences: DisplayPreferences {
    let unitSystem = UnitSystem.metric
    let quickWaterMilliliters = Decimal(250)
}

/// An eraser that only reports its name.
private final class MedicationEraseProbe: JournalErasing, @unchecked Sendable {
    let erasureName: String
    init(_ name: String) { erasureName = name }
    func eraseAll() throws {}
}

