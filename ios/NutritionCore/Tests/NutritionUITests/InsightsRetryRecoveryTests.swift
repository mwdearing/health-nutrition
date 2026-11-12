import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The Insights failure state offers Try again, which reads the journal once more. A read that fails and is then
/// retried must leave the failure behind and show the week, and a retry that fails again must keep the failure.
@MainActor
final class InsightsRetryRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeJournal() throws -> SnapshotReadFailingStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SnapshotReadFailingStore(inner: try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store")))
    }

    private func state(_ model: JournalViewModel) -> InsightsLoadState {
        InsightsLoadState.resolve(
            errorMessage: model.errorMessage, loadCount: model.loadCount, skippedCount: model.skippedCount,
            entries: [], now: now, zone: TimeZone(identifier: "UTC")!)
    }

    func testARetryAfterAFailedReadLeavesTheFailureAndShowsTheWeek() throws {
        let journal = try makeJournal()
        let model = JournalViewModel(store: journal, timeZoneIdentifier: "UTC", locale: Locale(identifier: "en_US"))

        journal.failsActiveIntakes = true
        model.load(now: now)
        guard case .failed = state(model) else { return XCTFail("a failed read was not reported as a failure") }

        journal.failsActiveIntakes = false
        model.load(now: now)
        XCTAssertNil(model.errorMessage, "the retry kept the earlier failure")
        guard case .ready = state(model) else { return XCTFail("the retry did not show the week") }
    }

    func testARetryThatFailsAgainKeepsTheFailure() throws {
        let journal = try makeJournal()
        let model = JournalViewModel(store: journal, timeZoneIdentifier: "UTC", locale: Locale(identifier: "en_US"))

        journal.failsActiveIntakes = true
        model.load(now: now)
        model.load(now: now)

        guard case .failed = state(model) else { return XCTFail("a second failed read was shown as a week") }
    }
}
