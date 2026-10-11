import SwiftUI
import UIKit
import XCTest
@testable import HealthNutrition

@MainActor
final class PrivacyShieldTests: XCTestCase {
    func testInactiveShieldIsOpaqueModalAndDoesNotBecomeKeyWindow() throws {
        let appWindow = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { !$0.isHidden && $0.isKeyWindow })
        let appAccessibilityWasHidden = appWindow.accessibilityElementsHidden
        let manager = PrivacyShieldController()
        manager.attach(to: appWindow, phase: .active)
        XCTAssertNil(manager.shieldWindow)

        manager.update(phase: .inactive)
        let shield = try XCTUnwrap(manager.shieldWindow)
        XCTAssertFalse(shield.isHidden)
        XCTAssertGreaterThan(shield.windowLevel.rawValue, appWindow.windowLevel.rawValue)
        XCTAssertFalse(shield.isKeyWindow)
        XCTAssertTrue(appWindow.isKeyWindow, "the app key window remains unchanged")
        XCTAssertTrue(appWindow.accessibilityElementsHidden)
        XCTAssertTrue(shield.rootViewController?.view.isOpaque == true)
        XCTAssertTrue(shield.rootViewController?.view.accessibilityViewIsModal == true)

        manager.update(phase: .background)
        XCTAssertFalse(shield.isHidden, "background keeps the shield installed")

        manager.update(phase: .active)
        XCTAssertTrue(shield.isHidden)
        XCTAssertNil(manager.shieldWindow)
        XCTAssertEqual(appWindow.accessibilityElementsHidden, appAccessibilityWasHidden)
    }

    func testSceneShieldSitsAboveModalWindowAndBlocksItsHitTesting() throws {
        let appWindow = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { !$0.isHidden && $0.isKeyWindow })
        let scene = try XCTUnwrap(appWindow.windowScene)
        let appAccessibilityWasHidden = appWindow.accessibilityElementsHidden
        let modalWindow = UIWindow(windowScene: scene)
        modalWindow.windowLevel = .normal
        modalWindow.rootViewController = UIViewController()
        modalWindow.isHidden = false
        defer { modalWindow.isHidden = true }

        let manager = PrivacyShieldController()
        manager.attach(to: appWindow, phase: .active)
        manager.update(phase: .inactive)

        let shield = try XCTUnwrap(manager.shieldWindow)
        XCTAssertGreaterThan(shield.windowLevel.rawValue, modalWindow.windowLevel.rawValue)
        XCTAssertTrue(appWindow.accessibilityElementsHidden)
        XCTAssertTrue(shield.accessibilityViewIsModal)
        let point = CGPoint(x: shield.bounds.midX, y: shield.bounds.midY)
        let shieldHit = shield.hitTest(point, with: nil)
        XCTAssertNotNil(shieldHit)
        XCTAssertTrue(
            shieldHit === shield.rootViewController?.view
                || shieldHit?.isDescendant(of: shield.rootViewController?.view ?? UIView()) == true)
        manager.update(phase: .active)
        XCTAssertEqual(appWindow.accessibilityElementsHidden, appAccessibilityWasHidden)
    }
}
