import Foundation
import XCTest
@testable import NutritionDomain

/// The medication log's rules: what a medication and a dose must hold to be saved, which day a dose
/// belongs to, and what the schedule says about the next dose.
///
/// The person names each medication and types every dose field, so nothing here knows a drug, a dose
/// range or a titration step. The checks cover the shape of what was typed; the schedule wording reports
/// days and never advises.
final class MedicationLogTests: XCTestCase {
    private let medicationID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!

    private func amount(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    }

    private func medication(
        _ name: String = "Example weekly injection", unit: MedicationUnit = .mg, scheduleDays: Int? = nil
    ) -> Medication {
        Medication(id: medicationID, name: name, unit: unit, scheduleDays: scheduleDays)
    }

    private func dose(
        _ text: String = "2.5", unit: MedicationUnit = .mg, at seconds: TimeInterval = 1_790_000_000,
        zone: String = "America/Chicago", site: String? = nil, note: String? = nil, id: UUID = UUID()
    ) -> MedicationDose {
        MedicationDose(
            id: id, medicationID: medicationID, takenAt: Date(timeIntervalSince1970: seconds),
            timeZoneIdentifier: zone, amount: amount(text), unit: unit, site: site, note: note)
    }

    /// The error `validate()` throws, or nil when it passes.
    private func thrownError(_ check: () throws -> Void) -> MedicationError? {
        do {
            try check()
            return nil
        } catch {
            return error as? MedicationError
        }
    }

    private func day(_ iso: String) -> CalendarDay {
        CalendarDay(iso: iso)!
    }

    // MARK: Units

    func testTheUnitsAreMilligramsMicrogramsMillilitersAndUnits() {
        XCTAssertEqual(MedicationUnit.allCases, [.mg, .mcg, .mL, .units])
        XCTAssertEqual(MedicationUnit.mg.rawValue, "mg")
        XCTAssertEqual(MedicationUnit.mcg.rawValue, "mcg")
        XCTAssertEqual(MedicationUnit.mL.rawValue, "mL")
        XCTAssertEqual(MedicationUnit.units.rawValue, "units")
        XCTAssertNil(MedicationUnit(rawValue: "ml"))
        XCTAssertNil(MedicationUnit(rawValue: "MG"))
        XCTAssertNil(MedicationUnit(rawValue: "Units"))
        XCTAssertNil(MedicationUnit(rawValue: "IU"))
    }

    // MARK: Medication

    func testAMedicationTheTypedNameDescribesIsValid() {
        XCTAssertNil(thrownError { try medication().validate() })
        XCTAssertNil(thrownError { try medication("Example pen", unit: .mcg, scheduleDays: 7).validate() })
    }

    func testAMedicationStartsActiveAndUnscheduled() {
        let made = Medication(name: "Example pen", unit: .mg)
        XCTAssertFalse(made.isArchived)
        XCTAssertNil(made.scheduleDays)
        XCTAssertNotEqual(made.id, Medication(name: "Example pen", unit: .mg).id)
    }

    func testAnEmptyOrBlankNameIsRefused() {
        XCTAssertEqual(thrownError { try medication("").validate() }, .nameEmpty)
        XCTAssertEqual(thrownError { try medication("   ").validate() }, .nameEmpty)
        XCTAssertEqual(thrownError { try medication("\n\t").validate() }, .nameEmpty)
    }

    func testANameWithSpaceAtEitherEndIsRefused() {
        XCTAssertEqual(thrownError { try medication(" Example pen").validate() }, .nameNotTrimmed)
        XCTAssertEqual(thrownError { try medication("Example pen ").validate() }, .nameNotTrimmed)
    }

    func testANameWithALineBreakInsideIsRefused() {
        XCTAssertEqual(thrownError { try medication("Example\npen").validate() }, .nameHasLineBreak)
        XCTAssertEqual(thrownError { try medication("Example\r\npen").validate() }, .nameHasLineBreak)
    }

    func testANameIsAtMostSixtyCharacters() {
        XCTAssertEqual(Medication.maximumNameLength, 60)
        XCTAssertNil(thrownError { try medication(String(repeating: "a", count: 60)).validate() })
        XCTAssertEqual(thrownError { try medication(String(repeating: "a", count: 61)).validate() }, .nameTooLong)
        // Characters, not bytes: sixty accented letters are still sixty.
        XCTAssertNil(thrownError { try medication(String(repeating: "é", count: 60)).validate() })
    }

    func testTheScheduleIsOneToTwentyEightDays() {
        XCTAssertEqual(Medication.scheduleDayRange, 1...28)
        XCTAssertNil(thrownError { try medication(scheduleDays: 1).validate() })
        XCTAssertNil(thrownError { try medication(scheduleDays: 28).validate() })
        XCTAssertEqual(thrownError { try medication(scheduleDays: 0).validate() }, .scheduleOutOfRange)
        XCTAssertEqual(thrownError { try medication(scheduleDays: 29).validate() }, .scheduleOutOfRange)
        XCTAssertEqual(thrownError { try medication(scheduleDays: -7).validate() }, .scheduleOutOfRange)
    }

    func testTheNameIsCheckedBeforeTheSchedule() {
        XCTAssertEqual(thrownError { try medication("", scheduleDays: 0).validate() }, .nameEmpty)
    }

    // MARK: Dose

    func testADoseAsTypedIsValid() {
        XCTAssertNil(thrownError { try dose().validate() })
        XCTAssertNil(thrownError { try dose("250", unit: .mcg, note: "Left the pen out overnight").validate() })
        XCTAssertNil(thrownError { try dose("0.25", unit: .mL).validate() })
        XCTAssertNil(thrownError { try dose("12", unit: .units, site: "Left thigh").validate() })
    }

    func testADoseMustBeMoreThanZero() {
        XCTAssertEqual(thrownError { try dose("0").validate() }, .amountNotPositive)
        XCTAssertEqual(thrownError { try dose("-1").validate() }, .amountNotPositive)
        let notANumber = MedicationDose(
            medicationID: medicationID, takenAt: Date(timeIntervalSince1970: 1_790_000_000),
            timeZoneIdentifier: "UTC", amount: .nan, unit: .mg)
        XCTAssertEqual(thrownError { try notANumber.validate() }, .amountNotPositive)
    }

    func testADoseIsAtMostOneThousand() {
        XCTAssertEqual(MedicationDose.maximumAmount, 1000)
        XCTAssertNil(thrownError { try dose("1000").validate() })
        XCTAssertEqual(thrownError { try dose("1000.001").validate() }, .amountTooLarge)
    }

    func testADoseHasAtMostThreeDecimals() {
        XCTAssertEqual(MedicationDose.maximumFractionDigits, 3)
        XCTAssertNil(thrownError { try dose("0.125").validate() })
        XCTAssertNil(thrownError { try dose("2.500").validate() })
        XCTAssertEqual(thrownError { try dose("0.0625").validate() }, .amountTooPrecise)
    }

    func testADoseNeedsATimeZoneThisDeviceKnows() {
        XCTAssertEqual(thrownError { try dose(zone: "Not/AZone").validate() }, .timeZoneUnknown)
        XCTAssertEqual(thrownError { try dose(zone: "").validate() }, .timeZoneUnknown)
    }

    func testANoteIsOptionalButNeverBlankAndAtMostTwoHundredCharacters() {
        XCTAssertEqual(MedicationDose.maximumNoteLength, 200)
        XCTAssertNil(thrownError { try dose(note: nil).validate() })
        XCTAssertNil(thrownError { try dose(note: String(repeating: "n", count: 200)).validate() })
        XCTAssertEqual(thrownError { try dose(note: "  ").validate() }, .noteEmpty)
        XCTAssertEqual(thrownError { try dose(note: String(repeating: "n", count: 201)).validate() }, .noteTooLong)
    }

    func testASiteIsOptionalTypedTextOnOneLineOfAtMostFortyCharacters() {
        XCTAssertEqual(MedicationDose.maximumSiteLength, 40)
        XCTAssertNil(dose().site)
        XCTAssertNil(thrownError { try dose(site: nil).validate() })
        XCTAssertNil(thrownError { try dose(site: "Abdomen, right of navel").validate() })
        XCTAssertNil(thrownError { try dose(site: String(repeating: "s", count: 40)).validate() })
        XCTAssertEqual(thrownError { try dose(site: "").validate() }, .siteEmpty)
        XCTAssertEqual(thrownError { try dose(site: " \t").validate() }, .siteEmpty)
        XCTAssertEqual(thrownError { try dose(site: " Left arm").validate() }, .siteNotTrimmed)
        XCTAssertEqual(thrownError { try dose(site: "Left arm\n").validate() }, .siteNotTrimmed)
        XCTAssertEqual(thrownError { try dose(site: "Left\narm").validate() }, .siteHasLineBreak)
        XCTAssertEqual(thrownError { try dose(site: String(repeating: "s", count: 41)).validate() }, .siteTooLong)
    }

    func testTheAmountIsCheckedBeforeTheTimeZoneThenTheSiteThenTheNote() {
        XCTAssertEqual(
            thrownError { try dose("0", zone: "Not/AZone", site: " ", note: " ").validate() }, .amountNotPositive)
        XCTAssertEqual(thrownError { try dose(zone: "Not/AZone", site: " ", note: " ").validate() }, .timeZoneUnknown)
        XCTAssertEqual(thrownError { try dose(site: " ", note: " ").validate() }, .siteEmpty)
    }

    func testTheSiteChangesNothingTheLogReports() {
        // The site is kept with the dose only. The day, the last dose and the schedule read the same with or without it.
        let weekly = medication(scheduleDays: 7)
        let plain = dose(at: 1_789_961_400)
        let withSite = dose(at: 1_789_961_400, site: "Right thigh", id: plain.id)
        XCTAssertEqual(withSite.day, plain.day)
        XCTAssertEqual(MedicationLog.lastDose(of: medicationID, in: [withSite])?.id, plain.id)
        XCTAssertEqual(
            MedicationLog.status(of: weekly, lastDose: withSite, today: day("2026-09-27")),
            MedicationLog.status(of: weekly, lastDose: plain, today: day("2026-09-27")))
    }

    // MARK: Day of a dose

    func testADoseBelongsToTheLocalDayOfItsOwnTimeZone() {
        // 2026-09-21 03:30 UTC is the evening of 2026-09-20 in Chicago and the same morning in Tokyo.
        let instant: TimeInterval = 1_789_961_400
        XCTAssertEqual(dose(at: instant, zone: "UTC").day, day("2026-09-21"))
        XCTAssertEqual(dose(at: instant, zone: "America/Chicago").day, day("2026-09-20"))
        XCTAssertEqual(dose(at: instant, zone: "Asia/Tokyo").day, day("2026-09-21"))
        XCTAssertNil(dose(at: instant, zone: "Not/AZone").day)
    }

    func testDaysSinceCountsWholeLocalDays() {
        let taken = dose(at: 1_789_961_400, zone: "America/Chicago")
        XCTAssertEqual(MedicationLog.daysSince(taken, today: day("2026-09-20")), 0)
        XCTAssertEqual(MedicationLog.daysSince(taken, today: day("2026-09-21")), 1)
        XCTAssertEqual(MedicationLog.daysSince(taken, today: day("2026-09-27")), 7)
        XCTAssertNil(MedicationLog.daysSince(dose(zone: "Not/AZone"), today: day("2026-09-27")))
    }

    // MARK: Last dose

    func testTheLastDoseIsTheLatestOfThatMedicationOnly() {
        let other = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let early = dose(at: 1_790_000_000)
        let late = dose(at: 1_790_600_000)
        let otherLater = MedicationDose(
            medicationID: other, takenAt: Date(timeIntervalSince1970: 1_791_000_000),
            timeZoneIdentifier: "UTC", amount: amount("1"), unit: .mg)
        XCTAssertEqual(MedicationLog.lastDose(of: medicationID, in: [late, otherLater, early]), late)
        XCTAssertEqual(MedicationLog.lastDose(of: other, in: [late, otherLater, early]), otherLater)
        XCTAssertNil(MedicationLog.lastDose(of: UUID(), in: [late, otherLater, early]))
        XCTAssertNil(MedicationLog.lastDose(of: medicationID, in: []))
    }

    func testTwoDosesAtTheSameInstantPickTheOneWhoseIDSortsLast() {
        let first = dose(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let second = dose(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        XCTAssertEqual(MedicationLog.lastDose(of: medicationID, in: [second, first]), second)
        XCTAssertEqual(MedicationLog.lastDose(of: medicationID, in: [first, second]), second)
    }

    // MARK: Schedule

    func testTheNextDayByScheduleIsTheLastDoseDayPlusTheInterval() {
        let taken = dose(at: 1_789_961_400, zone: "America/Chicago")
        XCTAssertEqual(MedicationLog.nextByScheduleDay(medication(scheduleDays: 7), lastDose: taken), day("2026-09-27"))
        XCTAssertEqual(MedicationLog.nextByScheduleDay(medication(scheduleDays: 1), lastDose: taken), day("2026-09-21"))
        XCTAssertNil(MedicationLog.nextByScheduleDay(medication(), lastDose: taken))
    }

    func testAMedicationWithNoScheduleHasNoStatusEvenWithDoses() {
        let taken = dose(at: 1_789_961_400, zone: "America/Chicago")
        XCTAssertEqual(MedicationLog.status(of: medication(), lastDose: taken, today: day("2026-10-30")), .notScheduled)
        XCTAssertEqual(MedicationLog.status(of: medication(), lastDose: nil, today: day("2026-10-30")), .notScheduled)
    }

    func testAnArchivedMedicationHasNoStatusWhateverItsScheduleAndDoses() {
        let archived = Medication(
            id: medicationID, name: "Example weekly injection", unit: .mg, scheduleDays: 7, isArchived: true)
        let taken = dose(at: 1_789_961_400, zone: "America/Chicago")
        XCTAssertEqual(MedicationLog.status(of: archived, lastDose: taken, today: day("2026-09-20")), .notScheduled)
        XCTAssertEqual(MedicationLog.status(of: archived, lastDose: taken, today: day("2026-10-07")), .notScheduled)
        XCTAssertEqual(MedicationLog.status(of: archived, lastDose: nil, today: day("2026-09-20")), .notScheduled)
    }

    func testAScheduledMedicationWithNoDoseYetSaysSo() {
        XCTAssertEqual(
            MedicationLog.status(of: medication(scheduleDays: 7), lastDose: nil, today: day("2026-09-20")), .noDoseYet)
    }

    func testTheStatusIsUpcomingThenDueTodayThenOverdueByWholeDays() {
        let weekly = medication(scheduleDays: 7)
        let taken = dose(at: 1_789_961_400, zone: "America/Chicago")
        XCTAssertEqual(
            MedicationLog.status(of: weekly, lastDose: taken, today: day("2026-09-20")), .upcoming(day("2026-09-27")))
        XCTAssertEqual(
            MedicationLog.status(of: weekly, lastDose: taken, today: day("2026-09-26")), .upcoming(day("2026-09-27")))
        XCTAssertEqual(MedicationLog.status(of: weekly, lastDose: taken, today: day("2026-09-27")), .dueToday)
        XCTAssertEqual(MedicationLog.status(of: weekly, lastDose: taken, today: day("2026-09-28")), .overdue(days: 1))
        XCTAssertEqual(MedicationLog.status(of: weekly, lastDose: taken, today: day("2026-10-07")), .overdue(days: 10))
    }

    func testTheScheduleCountsCalendarDaysAcrossAClockChange() {
        // US clocks fall back on 2026-11-01. A dose on the evening of 2026-10-29 in Chicago is next due on
        // 2026-11-05, seven calendar days later, whatever the hours in between add up to.
        let taken = dose(at: 1_793_318_400, zone: "America/Chicago")
        XCTAssertEqual(taken.day, day("2026-10-29"))
        XCTAssertEqual(
            MedicationLog.status(of: medication(scheduleDays: 7), lastDose: taken, today: day("2026-11-05")), .dueToday)
    }
}
