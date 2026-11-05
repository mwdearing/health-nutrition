import Foundation
import XCTest

@testable import HealthNutrition

/// A failed launch shows what to do next, and Try again opens the services once the cause has passed.
@MainActor
final class AppStartupTests: XCTestCase {
    func testAFailedLaunchKeepsTheErrorAndTheScreenAlwaysCarriesGuidance() throws {
        let startup = AppStartup(open: {
            throw AppServices.StoreStartupError.journal(CocoaError(.fileLocking))
        })
        XCTAssertNil(startup.services)
        let failure = try XCTUnwrap(startup.failure)
        XCTAssertTrue(failure.hasPrefix("The journal store file could not be opened"))
        XCTAssertTrue(StartupFailureView.guidance.contains("Try again"))
        XCTAssertTrue(StartupFailureView.guidance.contains("reinstall"))
    }

    func testTryAgainOpensTheServicesWhenTheSecondAttemptSucceeds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var attempts = 0
        let startup = AppStartup(open: {
            attempts += 1
            if attempts == 1 { throw AppServices.StoreStartupError.journal(CocoaError(.fileLocking)) }
            return try AppServices.make(directory: directory, reminderScheduler: RecordingReminderScheduler())
        })
        XCTAssertNil(startup.services)
        XCTAssertNotNil(startup.failure)

        startup.attempt()
        XCTAssertNotNil(startup.services)
        XCTAssertNil(startup.failure)
        XCTAssertEqual(attempts, 2)
        startup.attempt()
        XCTAssertEqual(attempts, 2, "a started app is not opened again")
    }
}
