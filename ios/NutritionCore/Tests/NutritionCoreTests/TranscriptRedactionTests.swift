import XCTest
@testable import NutritionCore

final class TranscriptRedactionTests: XCTestCase {
    private let bundle = "dev.example.Spike"

    func testBundleIdentifierIsReplacedWhateverItsCase() {
        let text = "source=dev.example.Spike other=DEV.EXAMPLE.SPIKE lower=dev.example.spike"
        XCTAssertEqual(
            TranscriptRedaction.redact(text, bundleIdentifier: bundle, deviceName: nil),
            "source=<bundle-id> other=<bundle-id> lower=<bundle-id>"
        )
    }

    func testDeviceNameIsReplacedWhateverItsCase() {
        let text = "running on Test Phone, aka TEST PHONE"
        XCTAssertEqual(
            TranscriptRedaction.redact(text, bundleIdentifier: nil, deviceName: "Test Phone"),
            "running on <device>, aka <device>"
        )
    }

    func testBothAreReplacedInOneLine() {
        let text = "Test Phone wrote dev.example.spike"
        XCTAssertEqual(
            TranscriptRedaction.redact(text, bundleIdentifier: bundle, deviceName: "test phone"),
            "<device> wrote <bundle-id>"
        )
    }

    func testMissingOrEmptyValuesLeaveTheTextUnchanged() {
        let text = "nothing private here"
        XCTAssertEqual(TranscriptRedaction.redact(text, bundleIdentifier: nil, deviceName: nil), text)
        XCTAssertEqual(TranscriptRedaction.redact(text, bundleIdentifier: "", deviceName: ""), text)
    }
}
