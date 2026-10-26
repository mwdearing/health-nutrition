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

        let nodes = Self.accessibilityNodes(under: host.view)
        guard let element = nodes.first(where: { $0.accessibilityLabel == SaveToLibraryAccessibility.label }) else {
            XCTFail("No accessibility element labelled \(SaveToLibraryAccessibility.label); found \(nodes.count) nodes")
            return
        }
        XCTAssertNil(element.accessibilityHint)
    }

    /// Walks subviews and accessibility elements, since SwiftUI exposes its nodes through either.
    private static func accessibilityNodes(under object: NSObject) -> [NSObject] {
        var nodes: [NSObject] = [object]
        if let view = object as? UIView {
            for subview in view.subviews { nodes += accessibilityNodes(under: subview) }
        }
        for child in object.accessibilityElements ?? [] {
            if let node = child as? NSObject { nodes += accessibilityNodes(under: node) }
        }
        return nodes
    }
}
