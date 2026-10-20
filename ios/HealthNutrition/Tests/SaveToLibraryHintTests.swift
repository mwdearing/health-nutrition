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

    /// Every UISwitch under `root`: SwiftUI exposes the Save to Library toggle as a switch with no label of its own,
    /// so the switch is found by class, not by label (#527).
    private func switches(under root: UIView) -> [UISwitch] {
        var found: [UISwitch] = (root as? UISwitch).map { [$0] } ?? []
        for subview in root.subviews { found += switches(under: subview) }
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

        let toggles = switches(under: host.view)
        XCTAssertEqual(toggles.count, 1, "the Add form shows the Save to Library switch")
        XCTAssertTrue((toggles.first?.accessibilityHint ?? "").isEmpty, "the Save to Library switch has no stale hint")
    }
}
