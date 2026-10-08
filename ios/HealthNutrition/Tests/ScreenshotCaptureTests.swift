import NutritionDomain
import NutritionJournal
import NutritionUI
import SwiftUI
import UIKit
import XCTest

@testable import HealthNutrition

/// Writes a PNG of each screen, in light and dark, for the design system.
///
/// The screens are the real views on a throwaway store filled with invented entries. The test only
/// runs when the `SCREENSHOT_DIR` environment variable names a directory (the screenshots workflow
/// passes it as `TEST_RUNNER_SCREENSHOT_DIR`), so the normal test run skips it. Each file is named
/// `<ViewName>-light.png` or `<ViewName>-dark.png`, the names `scripts/build_design_system.py` matches.
@MainActor
final class ScreenshotCaptureTests: XCTestCase {
    private let size = CGSize(width: 393, height: 852)
    private let intakeIDs = [
        "6f1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
        "7a2c3d4e-5f60-4b7c-9d8e-0f1a2b3c4d5e",
        "8b3d4e5f-6071-4c8d-8e9f-1a2b3c4d5e6f",
    ]

    private func outputDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("SCREENSHOT_DIR is not set; screenshots are captured by the screenshots workflow.")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An app on throwaway files with a day of invented entries and two goals.
    private func makeSeededServices() throws -> AppServices {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionScreenshots", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let services = try AppServices.make(directory: directory)
        let start = Calendar.current.startOfDay(for: Date())
        let zone = TimeZone.current.identifier
        let entries: [(String, String, String?, [IntakeComponent])] = [
            (intakeIDs[0], "food", "breakfast",
             [IntakeComponent(componentID: "oats", name: "Rolled oats", amount: 40, unit: .g),
              IntakeComponent(componentID: "milk", name: "Whole milk", amount: 150, unit: .mL)]),
            (intakeIDs[1], "water", nil,
             [IntakeComponent(componentID: "water", name: "Water", amount: 250, unit: .mL)]),
            (intakeIDs[2], "food", "lunch",
             [IntakeComponent(componentID: "lentils", name: "Lentil soup", amount: 300, unit: .g)]),
        ]
        for (index, entry) in entries.enumerated() {
            let intake = Intake(
                id: entry.0, category: entry.1, occurredAt: start.addingTimeInterval(Double(60 * (index + 1))),
                timeZoneIdentifier: zone, meal: entry.2)
            try services.journalStore.create(intake, components: entry.3, product: nil, now: Date())
        }
        try services.goalStore.setGoal(NutrientGoal(nutrient: "protein", target: 90, unit: .g))
        try services.goalStore.setGoal(NutrientGoal(nutrient: "water", target: 2000, unit: .mL))
        return services
    }

    /// True when every sampled pixel is the same colour, which is what a screen that failed to draw
    /// looks like.
    private func isUniform(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return true }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return true }
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        let first = Array(pixels[0..<4])
        for offset in stride(from: 4, to: pixels.count, by: 4) where Array(pixels[offset..<offset + 4]) != first {
            return false
        }
        return true
    }

    /// Hosts `content` in a visible window at iPhone size and writes one PNG per appearance.
    private func capture<Content: View>(_ name: String, @ViewBuilder _ content: () -> Content) throws {
        let directory = try outputDirectory()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        for (suffix, style) in [("light", UIUserInterfaceStyle.light), ("dark", UIUserInterfaceStyle.dark)] {
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
            window.frame = CGRect(origin: .zero, size: size)
            window.overrideUserInterfaceStyle = style
            window.rootViewController = UIHostingController(rootView: content())
            window.makeKeyAndVisible()
            // Lets onAppear loads run and the List lay out before the picture is taken.
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            XCTAssertFalse(isUniform(image), "\(name)-\(suffix) rendered as one flat colour")
            let png = try XCTUnwrap(image.pngData())
            try png.write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }

    func testRootView() throws {
        _ = try outputDirectory()
        let services = try makeSeededServices()
        try capture("RootView") { RootView(services: services) }
    }

    func testStartupFailureView() throws {
        try capture("StartupFailureView") {
            StartupFailureView(message: "The journal store file could not be opened.")
        }
    }
}
