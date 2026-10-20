import NutritionDomain
import NutritionJournal
import NutritionUI
import SwiftUI
import UIKit
import XCTest
@testable import HealthNutrition

/// Diagnostic only: print every UISwitch's hint in the hosted Add view, with the stale hint restored (#527).
@MainActor
final class SaveToLibraryDiagnoseTests: XCTestCase {
    private func dump(_ object: NSObject, depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        print("DIAG \(pad)\(type(of: object)) label=\(object.accessibilityLabel ?? "nil") hint=\(object.accessibilityHint ?? "nil")")
        for child in object.accessibilityElements ?? [] {
            if let c = child as? NSObject { dump(c, depth: depth + 1) }
        }
        if let view = object as? UIView {
            for sub in view.subviews { dump(sub, depth: depth + 1) }
        }
    }

    func testDiagnoseHintOnSwitch() throws {
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
        let host = UIHostingController(rootView: AddIntakeView(model: model, onSaved: {}))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 2000))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        host.view.layoutIfNeeded()
        var switches: [UISwitch] = []
        func collect(_ view: UIView) {
            if let s = view as? UISwitch { switches.append(s) }
            view.subviews.forEach(collect)
        }
        collect(host.view)
        print("DIAG switches=\(switches.count)")
        for s in switches {
            print("DIAG switch hint=\(s.accessibilityHint ?? "nil") label=\(s.accessibilityLabel ?? "nil")")
            s.accessibilityElements?.forEach { if let e = $0 as? NSObject { dump(e, depth: 1) } }
        }
        dump(host.view, depth: 0)
        print("DIAG end")
    }
}
