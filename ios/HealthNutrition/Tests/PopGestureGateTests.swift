import SwiftUI
import XCTest

@testable import NutritionUI

#if canImport(UIKit)
import UIKit

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
        // Attach the window to a foreground scene; a window with no scene may never lay out its SwiftUI content.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        if let scene {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        window.rootViewController = nav
        window.makeKeyAndVisible()
        nav.interactivePopGestureRecognizer?.isEnabled = initiallyEnabled
        return nav
    }

    /// Runs the run loop until the stack's recognizer reaches `expected`, or gives up after two seconds. The
    /// assertion after it then reports the real value, so a gate that never moves still fails.
    private func settle(_ nav: UINavigationController, until expected: Bool) {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, nav.interactivePopGestureRecognizer?.isEnabled != expected {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func push(blocked: Bool, onto nav: UINavigationController) -> UIHostingController<AnyView> {
        let host = UIHostingController(rootView: AnyView(Color.clear.blocksEdgeSwipeBack(while: blocked)))
        nav.pushViewController(host, animated: false)
        host.view.layoutIfNeeded()
        settle(nav, until: !blocked)
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
        settle(nav, until: true)
        XCTAssertEqual(nav.interactivePopGestureRecognizer?.isEnabled, true, "clearing the input left the edge pop off")
    }

    func testBlockedFormCoveredByAnotherBlockedFormKeepsTheEdgePopOff() {
        let nav = makeStack(initiallyEnabled: true)
        _ = push(blocked: true, onto: nav)
        _ = push(blocked: true, onto: nav)
        XCTAssertEqual(nav.interactivePopGestureRecognizer?.isEnabled, false, "a covered blocked form re-enabled the edge pop")
        nav.popViewController(animated: false)
        settle(nav, until: false)
        XCTAssertEqual(nav.interactivePopGestureRecognizer?.isEnabled, false, "popping the top blocked form left the edge pop on over the form beneath")
    }

    func testScreenPushedOverABlockedFormCanBeSwipedAwayAndTheGateReturns() {
        let nav = makeStack(initiallyEnabled: true)
        _ = push(blocked: true, onto: nav)
        nav.pushViewController(UIViewController(), animated: false)
        settle(nav, until: true)
        XCTAssertEqual(nav.interactivePopGestureRecognizer?.isEnabled, true, "the screen over the form cannot be swiped away")
        nav.popViewController(animated: false)
        settle(nav, until: false)
        XCTAssertEqual(nav.interactivePopGestureRecognizer?.isEnabled, false, "returning to the form did not turn the edge pop off again")
    }
}
#endif
