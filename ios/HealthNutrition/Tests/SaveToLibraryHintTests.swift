import SwiftUI
import UIKit
import XCTest
@testable import NutritionUI

/// The Save to Library switch has no accessibility hint: its label says what it does (#527).
final class SaveToLibraryHintTests: XCTestCase {
    func testSaveToLibrarySwitchHasNoHint() {
        XCTAssertNil(SaveToLibraryAccessibility.hint)
        XCTAssertEqual(SaveToLibraryAccessibility.label, "Save to Library")
    }

    /// Hosts the same modifier chain the Add view uses and checks the element carries no hint, not an empty one (#644).
    @MainActor
    func testNilHintLeavesNoAccessibilityHintOnTheSwitch() {
        let toggle = Toggle(SaveToLibraryAccessibility.label, isOn: .constant(false))
            .accessibilityHintIfPresent(SaveToLibraryAccessibility.hint)
        let host = UIHostingController(rootView: toggle)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 80))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        guard let element = Self.findElement(labelled: SaveToLibraryAccessibility.label, in: host.view) else {
            XCTFail("No accessibility element labelled \(SaveToLibraryAccessibility.label)")
            return
        }
        XCTAssertNil(element.accessibilityHint)
    }

    private static func findElement(labelled label: String, in view: UIView) -> UIView? {
        if view.accessibilityLabel == label { return view }
        for subview in view.subviews {
            if let found = findElement(labelled: label, in: subview) { return found }
        }
        return nil
    }
}
