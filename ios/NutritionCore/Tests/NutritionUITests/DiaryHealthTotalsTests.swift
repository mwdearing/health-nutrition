import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The Diary's day header adds what other apps logged to Apple Health that day, as Today does, so the header reads
/// the whole day wherever an entry was logged (Mike, 2026-10-30).
@MainActor
final class DiaryHealthTotalsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeJournal() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// A day whose only entry is a glass of water, so the journal itself states no energy and no protein.
    private func waterOnlyDay(goals: GoalStore? = nil) throws -> (JournalViewModel, String) {
        let journal = try makeJournal()
        try journal.create(
            Intake(id: UUID().uuidString.lowercased(), category: "water", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "water", name: "Example water", amount: 250, unit: .mL)],
            product: nil, now: now)
        let model = JournalViewModel(
            store: journal, goals: goals, timeZoneIdentifier: "UTC", locale: Locale(identifier: "en_US"))
        let key = JournalViewModel.dayKey(now, zone: TimeZone(identifier: "UTC")!)
        return (model, key)
    }

    /// Energy another app logged that day shows in the day header.
    func testTheDayHeaderEnergyIncludesHealthEnergyFromOtherApps() throws {
        let (model, key) = try waterOnlyDay()
        model.load(now: now)
        XCTAssertNil(model.sections.first { $0.id == key }?.energyText, "journal-only, the day states no energy")

        model.outsideIntakeByDay[key] = .read(values: ["energy": 620], readKeys: ["energy"])
        model.load(now: now)
        XCTAssertEqual(model.sections.first { $0.id == key }?.energyText, "620 Calories")
    }

    /// A goal bar in the day header counts what another app logged to Health that day.
    func testTheDayHeaderGoalBarIncludesHealthAmountsFromOtherApps() throws {
        let goals = InMemoryGoalStore()
        try goals.setGoal(NutrientGoal(nutrient: "protein", target: 60, unit: .g))
        let (model, key) = try waterOnlyDay(goals: goals)
        model.outsideIntakeByDay[key] = .read(values: ["protein": 30], readKeys: ["protein"])
        model.load(now: now)

        let bar = try XCTUnwrap(model.sections.first { $0.id == key }?.headerBars.first { $0.id == "protein" })
        XCTAssertEqual(bar.state, .progress)
        XCTAssertEqual(bar.fraction, Decimal(string: "0.5"))
    }

    /// Health read for one day never changes another day's header.
    func testHealthForOneDayLeavesOtherDaysJournalOnly() throws {
        let (model, key) = try waterOnlyDay()
        model.outsideIntakeByDay["1999-01-01"] = .read(values: ["energy": 620], readKeys: ["energy"])
        model.load(now: now)
        XCTAssertNil(model.sections.first { $0.id == key }?.energyText)
    }
}
