import Foundation
import NutritionDomain
import NutritionJournal
import NutritionUI
import XCTest

@testable import HealthNutrition

/// The supplement list as the app wires it: an open list follows the journal without being reloaded by
/// hand, both when an entry is logged elsewhere and when Erase all data runs.
///
/// Synthetic names only.
@MainActor
final class SupplementStackWiringTests: XCTestCase {
    private let favorite = FavoriteTemplate(
        id: "fav-synthetic-capsule", displayName: "Synthetic capsule", category: "supplement",
        components: [
            FavoriteComponent(
                componentID: "synthetic-capsule", name: "Synthetic capsule", amountText: "1", unitSymbol: "capsule"),
        ])

    /// A whole app on throwaway files, with the synthetic favorite on its supplement list.
    private func makeServicesWithOneItem() throws -> AppServices {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removeObject(forKey: UserDefaultsSupplementStackStore.key)
            UserDefaults.standard.removeObject(forKey: UserDefaultsSupplementStackStore.takenKey)
        }
        let services = try AppServices.make(directory: directory, reminderScheduler: RecordingReminderScheduler())
        try services.favoritesStore.add(favorite)
        let stack = services.supplementStack
        // As the screen does when it opens, so the list follows the app's reloads.
        stack.appeared(UUID(), now: Date())
        let candidate = try XCTUnwrap(stack.candidates.first)
        XCTAssertTrue(stack.add(candidate, schedule: .standard, now: Date()))
        XCTAssertEqual(stack.rows.map(\.title), ["Synthetic capsule"])
        return services
    }

    func testAnEntryLoggedElsewhereShowsOnTheOpenList() throws {
        let services = try makeServicesWithOneItem()
        XCTAssertEqual(services.supplementStack.rows.first?.loggedToday, 0)

        // Logged from another screen or window, then the app reloads its screens as it does after any write.
        _ = try services.journalStore.create(
            Intake(
                id: UUID().uuidString.lowercased(), category: "supplement", occurredAt: Date(),
                timeZoneIdentifier: TimeZone.current.identifier),
            components: [IntakeComponent(componentID: "synthetic-capsule", name: "Synthetic capsule", amount: 1, unit: .capsule)],
            product: nil, now: Date())
        services.library.load()

        XCTAssertEqual(services.supplementStack.rows.first?.loggedToday, 1)
    }

    func testEraseEmptiesAnOpenSupplementList() async throws {
        let services = try makeServicesWithOneItem()
        let stack = services.supplementStack
        let row = try XCTUnwrap(stack.rows.first)
        XCTAssertTrue(stack.markTaken(row, at: try XCTUnwrap(row.schedule.times.first), now: Date()))
        XCTAssertNotNil(stack.undoToken)
        XCTAssertFalse(UserDefaultsSupplementStackStore().takenMarks().isEmpty)

        let erased = await services.connections.eraseAllData()
        XCTAssertTrue(erased)
        XCTAssertTrue(stack.rows.isEmpty)
        XCTAssertTrue(stack.candidates.isEmpty)
        XCTAssertNil(stack.undoToken)
        XCTAssertTrue(UserDefaultsSupplementStackStore().schedules().isEmpty)
        XCTAssertTrue(UserDefaultsSupplementStackStore().takenMarks().isEmpty)
    }
}
