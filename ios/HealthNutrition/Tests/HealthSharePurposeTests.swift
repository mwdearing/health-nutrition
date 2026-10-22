import XCTest

/// The Health read purpose string is the text Apple shows the person. It names only what the app reads, with no
/// debug-only clause, in Debug and Release alike (#113).
final class HealthSharePurposeTests: XCTestCase {
    func testHealthReadPurposeStringNamesOnlyWhatTheAppReads() {
        let purpose = Bundle.main.object(forInfoDictionaryKey: "NSHealthShareUsageDescription") as? String
        XCTAssertEqual(
            purpose,
            "If you tap Show steps, activity and weight on Today, HealthNutrition reads your steps, active energy and weight to show them there. When you connect Apple Health, it also reads the nutrients and water other apps logged to Health, so your totals match Health. Nothing else is read except the nutrient samples other apps logged and the samples it wrote, which it looks up to update or remove them when you edit or delete an entry."
        )
    }
}
