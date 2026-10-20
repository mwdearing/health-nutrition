import XCTest

@testable import NutritionUI

/// The activity card's "From other apps" line after a read: values that were read stay visible through a partial
/// failure, and the failure line appears only when nothing was read.
@MainActor
final class OutsideCardTextTests: XCTestCase {
    @MainActor
    private final class FixedReader: BodyActivityReading {
        var hasAskedForReadAccess = true
        let readings: BodyActivityReadings

        init(readings: BodyActivityReadings) {
            self.readings = readings
        }

        func requestReadAccess() async {}

        func read(now: Date) async -> BodyActivityReadings {
            readings
        }
    }

    private func outsideText(for readings: BodyActivityReadings) async -> String? {
        let model = BodyActivityViewModel(reader: FixedReader(readings: readings), unitSystem: { .metric })
        await model.load(now: Date(timeIntervalSince1970: 1_700_000_000))
        return model.outsideText
    }

    func testPartialFailureShowsTheValuesThatWereRead() async {
        let text = await outsideText(for: BodyActivityReadings(
            outsideNutrients: ["energy": 620], outsideReadFailed: true, outsideRead: true,
            outsideReadKeys: ["energy"]))
        XCTAssertEqual(text, "From other apps: 620 Calories")
        XCTAssertFalse(text?.contains("could not be read") ?? true)
    }

    func testSuccessfulQueriesWithNoSamplesDoNotShowTheFailureLine() async {
        let text = await outsideText(for: BodyActivityReadings(
            outsideReadFailed: true, outsideRead: true, outsideReadKeys: ["energy", "protein"]))
        XCTAssertNil(text)
    }

    func testNothingReadShowsTheFailureLine() async {
        let text = await outsideText(for: BodyActivityReadings(outsideReadFailed: true, outsideRead: true))
        XCTAssertEqual(text, "From other apps: could not be read")
    }
}
