import Foundation
import NutritionDomain
import XCTest
@testable import NutritionUI

/// Which medication reminders are pending: one request on the day a medication's schedule next asks for a dose,
/// at the time the person picked, only while the Medication log is on, only for an active medication with a
/// schedule and a logged dose, and never for a time already past. The text names no medication and no dose.
final class MedicationReminderPlanTests: XCTestCase {
    /// 2026-04-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_776_254_400)
    private let day: TimeInterval = 86_400
    private let utc = TimeZone(identifier: "UTC")!

    private func weekly(_ id: UUID = UUID(), name: String = "Example weekly injection", archived: Bool = false) -> Medication {
        Medication(id: id, name: name, unit: .mg, scheduleDays: 7, isArchived: archived)
    }

    private func dose(_ medication: Medication, daysAgo: Double, zone: String = "UTC") -> MedicationDose {
        MedicationDose(
            medicationID: medication.id, takenAt: now.addingTimeInterval(-daysAgo * day), timeZoneIdentifier: zone,
            amount: 2.5, unit: medication.unit)
    }

    private func plan(
        _ medications: [Medication], _ doses: [MedicationDose], _ settings: [MedicationReminderSetting],
        logIsOn: Bool = true
    ) -> [MedicationReminderRequest] {
        MedicationReminderPlan.requests(
            medications: medications, doses: doses, settings: settings, logIsOn: logIsOn, now: now, timeZone: utc)
    }

    func testOneRequestOnTheNextScheduledDayAtThePickedTime() {
        let med = weekly()
        let requests = plan([med], [dose(med, daysAgo: 5)], [MedicationReminderSetting(medicationID: med.id, time: ReminderTime(hour: 8, minute: 30))])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.medicationID, med.id)
        XCTAssertEqual(requests.first?.day, CalendarDay(year: 2026, month: 4, day: 17))
        XCTAssertEqual(requests.first?.time, ReminderTime(hour: 8, minute: 30))
        XCTAssertEqual(requests.first?.identifier, "medication-reminder-" + med.id.uuidString)
        XCTAssertEqual(MedicationReminderPlan.identifierPrefix, "medication-reminder-")
    }

    func testNothingWhileTheMedicationLogIsOff() {
        let med = weekly()
        let setting = MedicationReminderSetting(medicationID: med.id, time: ReminderTime(hour: 8, minute: 0))
        XCTAssertEqual(plan([med], [dose(med, daysAgo: 5)], [setting], logIsOn: false), [])
    }

    func testNothingWithoutASettingAScheduleADoseOrForAnArchivedMedication() {
        let med = weekly()
        let time = ReminderTime(hour: 8, minute: 0)
        XCTAssertEqual(plan([med], [dose(med, daysAgo: 5)], []), [], "no setting")
        XCTAssertEqual(plan([med], [], [MedicationReminderSetting(medicationID: med.id, time: time)]), [], "no dose yet")
        let archived = weekly(med.id, archived: true)
        XCTAssertEqual(
            plan([archived], [dose(archived, daysAgo: 5)], [MedicationReminderSetting(medicationID: med.id, time: time)]), [],
            "archived")
        let unscheduled = Medication(id: UUID(), name: "Example tablet", unit: .mg)
        XCTAssertEqual(
            plan([unscheduled], [dose(unscheduled, daysAgo: 5)], [MedicationReminderSetting(medicationID: unscheduled.id, time: time)]),
            [], "no schedule")
        XCTAssertEqual(
            plan([], [dose(med, daysAgo: 5)], [MedicationReminderSetting(medicationID: med.id, time: time)]), [],
            "medication no longer stored")
    }

    func testDueTodayOnlyWhileThePickedTimeIsStillAhead() {
        let med = weekly()
        let lastWeek = dose(med, daysAgo: 7)
        XCTAssertEqual(plan([med], [lastWeek], [MedicationReminderSetting(medicationID: med.id, time: ReminderTime(hour: 8, minute: 0))]), [])
        let evening = plan([med], [lastWeek], [MedicationReminderSetting(medicationID: med.id, time: ReminderTime(hour: 20, minute: 0))])
        XCTAssertEqual(evening.map(\.day), [CalendarDay(year: 2026, month: 4, day: 15)])
    }

    func testNothingOnceTheScheduledDayHasPassed() {
        let med = weekly()
        let setting = MedicationReminderSetting(medicationID: med.id, time: ReminderTime(hour: 20, minute: 0))
        XCTAssertEqual(plan([med], [dose(med, daysAgo: 14)], [setting]), [])
    }

    func testTheLatestDoseDecidesTheDay() {
        let med = weekly()
        let setting = MedicationReminderSetting(medicationID: med.id, time: ReminderTime(hour: 9, minute: 0))
        let requests = plan([med], [dose(med, daysAgo: 12), dose(med, daysAgo: 2)], [setting])
        XCTAssertEqual(requests.map(\.day), [CalendarDay(year: 2026, month: 4, day: 20)])
    }

    func testADoseWhoseDayCannotBeReadSchedulesNothing() {
        let med = weekly()
        let setting = MedicationReminderSetting(medicationID: med.id, time: ReminderTime(hour: 9, minute: 0))
        XCTAssertEqual(plan([med], [dose(med, daysAgo: 5, zone: "Not/AZone")], [setting]), [])
    }

    func testPendingRequestsAreCappedAndOrderedByDayTimeThenIdentifier() {
        var medications: [Medication] = []
        var doses: [MedicationDose] = []
        var settings: [MedicationReminderSetting] = []
        for index in 0..<(MedicationReminderPlan.maximumPending + 5) {
            let med = weekly(name: "Example medication \(index)")
            medications.append(med)
            doses.append(dose(med, daysAgo: Double(index % 6)))
            settings.append(MedicationReminderSetting(medicationID: med.id, time: ReminderTime(hour: 7 + index % 3, minute: 0)))
        }
        let requests = plan(medications, doses, settings)
        XCTAssertEqual(MedicationReminderPlan.maximumPending, 20)
        XCTAssertEqual(requests.count, MedicationReminderPlan.maximumPending)
        let keys = requests.map { ($0.day, $0.time.hour, $0.time.minute, $0.medicationID.uuidString) }
        for (lhs, rhs) in zip(keys, keys.dropFirst()) {
            XCTAssertTrue(
                lhs.0 < rhs.0 || (lhs.0 == rhs.0 && (lhs.1, lhs.2, lhs.3) <= (rhs.1, rhs.2, rhs.3)),
                "requests out of order")
        }
    }

    func testTheTextNamesNoMedicationNoDoseAndGivesNoAdvice() {
        XCTAssertEqual(MedicationReminderPlan.notificationTitle, "Medication log")
        XCTAssertEqual(MedicationReminderPlan.notificationBody, "A dose in your medication log is due today.")
        let text = (MedicationReminderPlan.notificationTitle + " " + MedicationReminderPlan.notificationBody).lowercased()
        for word in ["missed", "late", "should", "take your", "mg", "example", "overdue"] {
            XCTAssertFalse(text.contains(word), word)
        }
    }
}
