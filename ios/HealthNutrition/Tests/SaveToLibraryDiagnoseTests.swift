import NutritionDomain
import NutritionJournal
import NutritionUI
import SwiftUI
import UIKit
import XCTest
@testable import HealthNutrition

/// Diagnostic only: print every accessibility label the hosted Add view exposes (#527).
@MainActor
final class SaveToLibraryDiagnoseTests: XCTestCase {
    private func dump(_ object: NSObject, depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        print("DIAG \(pad)\(type(of: object)) label=\(object.accessibilityLabel ?? "nil") hint=\(object.accessibilityHint ?? "nil") traits=\(object.accessibilityTraits.rawValue)")
        for child in object.accessibilityElements ?? [] {
            if let c = child as? NSObject { dump(c, depth: depth + 1) }
        }
        if let view = object as? UIView {
            for sub in view.subviews { dump(sub, depth: depth + 1) }
        }
    }

    func testDiagnoseAddViewLabels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let model = AddIntakeViewModel(store: store, now: Date(timeIntervalSince1970: 1_700_000_000))
        model.applyLabelProduct(
            ProductDefinition(
                snapshotID: "example-label", productID: "example-label", name: "Example bar",
                labelBasis: "per serving", catalogOrigin: ProductOrigin.label_capture, catalogVersion: "1",
                nutrients: ["protein": .known(10, .g)]),
            fromLabelCapture: true)
        print("DIAG canChooseLibrary=\(model.canChooseLibrary)")
        let host = UIHostingController(rootView: AddIntakeView(model: model, onSaved: {}))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 2000))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        host.view.layoutIfNeeded()
        dump(host.view, depth: 0)
        print("DIAG end")
    }
}
