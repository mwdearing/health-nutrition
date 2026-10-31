import SwiftUI
import UIKit
import XCTest

@testable import NutritionUI

/// The edge swipe-back is switched off on the navigation stack that hosts a form while it holds typed input, back on
/// when the input is cleared, and back on when another screen covers the form. Each test pushes a hosted gate onto a
/// real navigation stack in a key window and reads the stack's recognizer, so a gate that never reaches the stack fails.
@MainActor
final class PopGestureGateTests: XCTestCase {
    private var window: UIWindow!

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    /// A stack in a key window whose recognizer starts in `initiallyEnabled`, so a gate that does nothing is caught
    /// whichever way the test expects it to move.
    private func makeStack(initiallyEnabled: Bool) -> UINavigationController {
        let nav = UINavigationController(rootViewController: UIViewController())
        window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        nav.interactivePopGestureRecognizer?.isEnabled = initiallyEnabled
        return nav
    }

    private func settle() {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    private func push(blocked: Bool, onto nav: UINavigationController) -> UIHostingController<AnyView> {
        let host = UIHostingController(rootView: AnyView(Color.clear.blocksEdgeSwipeBack(while: blocked)))
        nav.pushViewController(host, animated: false)
        host.view.layoutIfNeeded()
        settle()
        return host
    }

    func testBlockedFormTurnsTheEdgePopOff() {
        let nav = makeStack(initiallyEnabled: true)
        _ = push(blocked: true, onto: nav)
        XCTAssertEqual(nav.interactivePopGestureRecognizer?.isEnabled, false, "a form with typed input still allows the edge pop")
    }

    func testCleanFormTurnsTheEdgePopOn() {
        let nav = makeStack(initiallyEnabled: false)
        _ = push(blocked: false, onto: nav)
        XCTAssertEqual(nav.interactivePopGestureRecognizer?.isEnabled, true, "a clean form left the edge pop off")
    }

    func testClearingTheInputTurnsTheEdgePopBackOn() {
        let nav = makeStack(initiallyEnabled: true)
        let host = push(blocked: true, onto: nav)
        XCTAssertEqual(nav.interactivePopGestureRecognizer?.isEnabled, false, "a form with typed input still allows the edge pop")
        host.rootView = AnyView(Color.clear.blocksEdgeSwipeBack(while: false))
        host.view.layoutIfNeeded()
        settle()
        XCTAssertEqual(nav.interactivePopGestureRecognizer?.isEnabled, true, "clearing the input left the edge pop off")
    }

    func testScreenPushedOverABlockedFormCanBeSwipedAwayAndTheGateReturns() {
        let nav = makeStack(initiallyEnabled: true)
        _ = push(blocked: true, onto: nav)
        nav.pushViewController(UIViewController(), animated: false)
        settle()
        XCTAssertEqual(nav.interactivePopGestureRecognizer?.isEnabled, true, "the screen over the form cannot be swiped away")
        nav.popViewController(animated: false)
        settle()
        XCTAssertEqual(nav.interactivePopGestureRecognizer?.isEnabled, false, "returning to the form did not turn the edge pop off again")
    }
}
