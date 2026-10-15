import Foundation
import NutritionDomain
import NutritionJournal
import NutritionUI
import XCTest

@testable import HealthNutrition

/// The "Log supplement taken" shortcut against the supplement list as the app wires it: one Taken is one
/// ordinary entry, written through the list's own call. Synthetic names only.
@MainActor
final class LogSupplementWiringTests: XCTestCase {
    private let favorite = FavoriteTemplate(
        id: "fav-synthetic-capsule", displayName: "Synthetic capsule", category: "supplement",
        components: [
            FavoriteComponent(
                componentID: "synthetic-capsule", name: "Synthetic capsule", amountText: "1", unitSymbol: "capsule"),
        ])

    private func makeServicesWithOneItem() throws -> AppServices {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        // Display settings live in a throwaway suite, so an erase here never touches the host app's settings.
        let suiteName = "synthetic.supplement.shortcut.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            UserDefaults.standard.removeObject(forKey: UserDefaultsSupplementStackStore.key)
            UserDefaults.standard.removeObject(forKey: UserDefaultsSupplementStackStore.takenKey)
        }
        let services = try AppServices.make(
            directory: directory, displayPreferences: UserDefaultsDisplayPreferences(defaults: suite),
            reminderScheduler: RecordingReminderScheduler())
        try services.favoritesStore.add(favorite)
        let stack = services.supplementStack
        stack.appeared(UUID(), now: Date())
        let candidate = try XCTUnwrap(stack.candidates.first)
        XCTAssertTrue(stack.add(candidate, schedule: .standard, now: Date()))
        return services
    }

    func testTheShortcutWritesOneEntryThroughTheListAndSaysSo() throws {
        let services = try makeServicesWithOneItem()
        let stack = services.supplementStack
        // The defaults domain is the host app's, so count the change rather than assume an empty day.
        let before = try XCTUnwrap(stack.rows.first).loggedToday

        let outcome = SupplementShortcut.log(favoriteID: favorite.id, now: Date(), stack: stack)

        XCTAssertEqual(outcome, .init(logged: true, message: "Logged Synthetic capsule"))
        XCTAssertEqual(stack.rows.first?.loggedToday, before + 1)
        XCTAssertNotNil(stack.undoToken)
    }

    func testAnItemNotOnTheListWritesNothing() throws {
        let services = try makeServicesWithOneItem()
        let stack = services.supplementStack

        let before = try XCTUnwrap(stack.rows.first).loggedToday

        let outcome = SupplementShortcut.log(favoriteID: "fav-missing", now: Date(), stack: stack)

        XCTAssertEqual(outcome, .init(logged: false, message: SupplementShortcut.notOnListMessage))
        XCTAssertEqual(stack.rows.first?.loggedToday, before)
    }
}
