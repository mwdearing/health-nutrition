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

    /// Every accessibility element under `root` whose label is `label`, so a container and its inner switch
    /// are both checked, not just the first one found.
    private func elements(labelled label: String, under root: NSObject) -> [NSObject] {
        var found: [NSObject] = root.accessibilityLabel == label ? [root] : []
        for child in root.accessibilityElements ?? [] {
            if let object = child as? NSObject { found += elements(labelled: label, under: object) }
        }
        if let view = root as? UIView {
            for subview in view.subviews { found += elements(labelled: label, under: subview) }
        }
        return found
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

        let toggles = elements(labelled: "Save to Library", under: host.view)
        XCTAssertFalse(toggles.isEmpty, "the Save to Library toggle is on screen")
        for toggle in toggles {
            XCTAssertTrue((toggle.accessibilityHint ?? "").isEmpty, "no element labelled Save to Library has a stale hint")
        }
    }
}
