import SwiftUI
import UIKit
import XCTest

@testable import NutritionUI

/// The edge swipe-back is switched off on the navigation controller that hosts a form while it holds typed input,
/// and switched back on when it does not. The test pushes a hosted gate onto a real navigation stack and reads the
/// recognizer's state, so a gate that never reaches the controller fails here.
@MainActor
final class PopGestureGateTests: XCTestCase {
    private func recognizerEnabled(blocked: Bool) -> Bool? {
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        let host = UIHostingController(rootView: Color.clear.blocksEdgeSwipeBack(while: blocked))
        nav.pushViewController(host, animated: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return nav.interactivePopGestureRecognizer?.isEnabled
    }

    /// Diagnostic: finds the gate's own controller in the hosted tree and reports whether it reaches the navigation stack.
    func testDiagnoseTheGateController() {
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        let host = UIHostingController(rootView: Color.clear.blocksEdgeSwipeBack(while: true))
        nav.pushViewController(host, animated: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        var found: [String] = []
        func walk(_ vc: UIViewController, depth: Int) {
            found.append("\(String(repeating: " ", count: depth))\(type(of: vc)) nav=\(vc.navigationController != nil)")
            for child in vc.children { walk(child, depth: depth + 1) }
        }
        walk(host, depth: 0)
        XCTFail("gate diagnosis:\n" + found.joined(separator: "\n"))
    }

    func testBlockedFormDisablesTheEdgePop() {
        XCTAssertEqual(recognizerEnabled(blocked: true), false, "a form with typed input still allows the edge pop")
    }

    func testCleanFormLeavesTheEdgePopOn() {
        XCTAssertEqual(recognizerEnabled(blocked: false), true, "a clean form does not allow the edge pop")
    }
}
