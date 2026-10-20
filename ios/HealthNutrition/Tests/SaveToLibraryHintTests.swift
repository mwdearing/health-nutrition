import NutritionDomain
import NutritionJournal
import NutritionUI
import SwiftUI
import UIKit
import XCTest
@testable import HealthNutrition

/// The "Save to Library" toggle carries no stale accessibility hint: its label says what it does (#527).
@MainActor
final class SaveToLibraryHintTests: XCTestCase {
    private func makeStore() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// The first accessibility element, anywhere under `root`, whose label is `label`.
    private func element(labelled label: String, under root: NSObject) -> NSObject? {
        if root.accessibilityLabel == label { return root }
        for child in root.accessibilityElements ?? [] {
            if let object = child as? NSObject, let found = element(labelled: label, under: object) { return found }
        }
        if let view = root as? UIView {
            for subview in view.subviews {
                if let found = element(labelled: label, under: subview) { return found }
            }
        }
        return nil
    }

    func testSaveToLibraryToggleHasNoAccessibilityHint() throws {
        let store = try makeStore()
        let model = AddIntakeViewModel(store: store, now: Date(timeIntervalSince1970: 1_700_000_000))
        model.applyLabelProduct(
            ProductDefinition(
                snapshotID: "example-label", productID: "example-label", name: "Example bar",
                labelBasis: "per serving", catalogOrigin: ProductOrigin.label_capture, catalogVersion: "1",
                nutrients: ["protein": .known(10, .g)]),
            fromLabelCapture: true)
        let host = UIHostingController(rootView: AddIntakeView(model: model, onSaved: {}))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let toggle = try XCTUnwrap(element(labelled: "Save to Library", under: host.view), "the toggle is on screen")
        XCTAssertTrue((toggle.accessibilityHint ?? "").isEmpty, "the toggle has no stale hint")
    }
}
