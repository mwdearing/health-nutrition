import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The weight chart on Today's activity card: one point for each day with a weigh-in in the trend's window, in
/// the display unit, and, while the Medication log is on, a marker on each day of that window with a dose.
/// A marker's spoken label names the day and each dose's medication, amount and unit. It never names a site,
/// and nothing on the card relates a dose to a weight.
@MainActor
final class WeightChartDoseMarkersTests: XCTestCase {
    private final class Reader: BodyActivityReading {
        var hasAskedForReadAccess = true
        var readings = BodyActivityReadings.empty

        func requestReadAccess() async {}

        func read(now: Date) async -> BodyActivityReadings { readings }
    }

    /// 2026-04-15 12:00 UTC, read in a UTC calendar, so "today" is April 15 and the 28-day window starts March 19.
    private let now = Date(timeIntervalSince1970: 1_776_254_400)
    private let vialID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let penID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }

    private func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func rounded(_ value: Decimal, _ places: Int) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, places, .plain)
        return result
    }

    /// 90 and 91 kg on April 1, 89 kg on April 15, and one weigh-in before the window.
    private func readings() -> BodyActivityReadings {
        var readings = BodyActivityReadings(latestWeightKg: 89, latestWeightDate: now)
        readings.weightSamples = [
            WeightSample(day: day("2026-03-10"), kilograms: 95),
            WeightSample(day: day("2026-04-01"), kilograms: 90),
            WeightSample(day: day("2026-04-01"), kilograms: 91),
            WeightSample(day: day("2026-04-15"), kilograms: 89),
        ]
        return readings
    }

    private func store(failReads: Bool = false) -> InMemoryMedicationStore {
        InMemoryMedicationStore(
            medications: [
                Medication(id: vialID, name: "Example vial", unit: .mg),
                Medication(id: penID, name: "Example pen", unit: .units, isArchived: true),
            ],
            doses: [
                MedicationDose(
                    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!, medicationID: vialID,
                    takenAt: instant("2026-04-10T08:00:00Z"), timeZoneIdentifier: "UTC",
                    amount: Decimal(string: "2.5")!, unit: .mg, site: "Left side"),
                MedicationDose(
                    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!, medicationID: penID,
                    takenAt: instant("2026-04-10T18:00:00Z"), timeZoneIdentifier: "UTC", amount: 1000, unit: .units),
                MedicationDose(
                    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!, medicationID: vialID,
                    takenAt: instant("2026-03-01T08:00:00Z"), timeZoneIdentifier: "UTC", amount: 2, unit: .mg),
            ],
            failReads: failReads)
    }

    private func makeModel(
        readings: BodyActivityReadings, system: UnitSystem = .metric, medications: MedicationStore? = nil,
        logOn: Bool = true
    ) -> BodyActivityViewModel {
        let reader = Reader()
        reader.readings = readings
        let preferences = InMemoryDisplayPreferences()
        preferences.setMedicationLogOn(logOn)
        return BodyActivityViewModel(
            reader: reader, unitSystem: { system }, calendar: utc, medications: medications,
            medicationPreferences: preferences)
    }

    func testTheChartHasOnePointPerDayInTheWindowAveragedInTheDisplayUnit() async {
        let model = makeModel(readings: readings())
        await model.load(now: now)

        XCTAssertTrue(model.showsWeightChart)
        XCTAssertEqual(model.weightChartPoints.map(\.day), [day("2026-04-01"), day("2026-04-15")])
        XCTAssertEqual(model.weightChartPoints.map { rounded($0.weight, 1) }, [Decimal(string: "90.5")!, 89])

        let pounds = makeModel(readings: readings(), system: .usCustomary)
        await pounds.load(now: now)
        // 89 kg is 196.211 lb.
        XCTAssertEqual(pounds.weightChartPoints.last.map { rounded($0.weight, 1) }, Decimal(string: "196.2")!)
    }

    func testOneDayOfWeighInsShowsNoChartAndNoMarkers() async {
        var single = BodyActivityReadings(latestWeightKg: 89, latestWeightDate: now)
        single.weightSamples = [WeightSample(day: day("2026-04-15"), kilograms: 89)]
        let model = makeModel(readings: single, medications: store())
        await model.load(now: now)

        XCTAssertFalse(model.showsWeightChart)
        XCTAssertEqual(model.doseMarkers, [])
    }

    func testWhileTheLogIsOnEachDoseDayInTheWindowIsMarked() async {
        let model = makeModel(readings: readings(), medications: store())
        await model.load(now: now)

        XCTAssertEqual(model.doseMarkers.map(\.day), [day("2026-04-10")])
        XCTAssertEqual(
            model.doseMarkers.map(BodyActivityViewModel.doseMarkerLabel),
            ["Medication log, Apr 10, 2026: Example vial 2.5 mg; Example pen 1,000 units"])
    }

    func testAMarkerLabelNeverNamesTheSite() async {
        let model = makeModel(readings: readings(), medications: store())
        await model.load(now: now)

        for marker in model.doseMarkers {
            XCTAssertFalse(BodyActivityViewModel.doseMarkerLabel(marker).contains("Left side"))
        }
    }

    func testWithTheLogOffThereAreNoMarkersAndTheChartStays() async {
        let model = makeModel(readings: readings(), medications: store(), logOn: false)
        await model.load(now: now)

        XCTAssertEqual(model.doseMarkers, [])
        XCTAssertTrue(model.showsWeightChart)
    }

    func testAnUnreadableLogLeavesTheChartAndTrendAsTheyAre() async {
        let model = makeModel(readings: readings(), medications: store(failReads: true))
        await model.load(now: now)

        XCTAssertEqual(model.doseMarkers, [])
        XCTAssertTrue(model.showsWeightChart)
        XCTAssertEqual(model.weightChartPoints.count, 2)
        XCTAssertNotNil(model.weightTrendText)
    }

    func testWithoutAMedicationStoreThereAreNoMarkers() async {
        let reader = Reader()
        reader.readings = readings()
        let model = BodyActivityViewModel(reader: reader, unitSystem: { .metric }, calendar: utc)
        await model.load(now: now)

        XCTAssertEqual(model.doseMarkers, [])
        XCTAssertTrue(model.showsWeightChart)
    }

    func testTheChartHasASpokenTitle() {
        XCTAssertEqual(BodyActivityViewModel.weightChartLabel, "Weight, last 28 days")
    }
}
