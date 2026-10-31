import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// Probe: an entry logged in another zone, on Today, is it also under the Diary's today?
@MainActor
final class TodayDiaryZoneProbeTests: XCTestCase {
    func testAnEntryOnTodayIsUnderTheDiarysToday() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        // 2023-11-14 22:13 UTC is 2023-11-15 07:13 in Tokyo.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try store.create(
            Intake(id: UUID().uuidString.lowercased(), category: "water", occurredAt: now,
                   timeZoneIdentifier: "Asia/Tokyo"),
            components: [IntakeComponent(componentID: "water", name: "Example water", amount: 250, unit: .mL)],
            product: nil, now: now)
        let today = TodayViewModel(store: store, timeZoneIdentifier: "UTC")
        today.load(now: now)
        let diary = JournalViewModel(store: store, timeZoneIdentifier: "UTC", locale: Locale(identifier: "en_US"))
        diary.load(now: now)
        let todayKey = JournalViewModel.dayKey(now, zone: TimeZone(identifier: "UTC")!)
        let onToday = today.waterTotalMilliliters > 0
        let underDiaryToday = !(diary.sections.first { $0.id == todayKey }?.rows.isEmpty ?? true)
        XCTAssertEqual(onToday, underDiaryToday,
            "Today shows it: \(onToday); Diary's today (\(todayKey)) has it: \(underDiaryToday); sections: \(diary.sections.map(\.id))")
    }
}
