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

    /// Skips every capture before its fixtures are built when the screenshots workflow has not set
    /// `SCREENSHOT_DIR`, so the normal test run does no store work for these.
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["SCREENSHOT_DIR"]?.isEmpty == false else {
            throw XCTSkip("SCREENSHOT_DIR is not set; screenshots are captured by the screenshots workflow.")
        }
    }

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
        let services = try AppServices.make(directory: directory, reminderScheduler: RecordingReminderScheduler())
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
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        // Averaged down, so thin text still moves some of the 256 samples away from the background.
        for offset in stride(from: 4, to: pixels.count, by: 4) {
            for channel in 0..<3 where abs(Int(pixels[offset + channel]) - Int(pixels[channel])) > 1 {
                return false
            }
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
            let png = try XCTUnwrap(image.pngData())
            try png.write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
            XCTAssertFalse(isUniform(image), "\(name)-\(suffix) rendered as one flat colour")
        }
    }

    func testRootView() throws {
        _ = try outputDirectory()
        let services = try makeSeededServices()
        try capture("RootView") { RootView(services: services) }
    }

    func testTodayView() throws {
        let services = try makeSeededServices()
        try capture("TodayView") {
            NavigationStack {
                TodayView(
                    model: services.today, onAddIntake: {}, onEditGoals: {}, onSelect: { _ in })
            }
        }
    }

    func testJournalView() throws {
        let services = try makeSeededServices()
        try capture("JournalView") {
            NavigationStack { JournalView(model: services.journal, onSelect: { _ in }) }
        }
    }

    func testLibraryView() throws {
        let services = try makeSeededServices()
        try capture("LibraryView") {
            NavigationStack {
                LibraryView(model: services.library, onAdded: {}, onOpenRecipes: {})
                    .navigationTitle("Library")
            }
        }
    }

    func testAppSettingsView() throws {
        let services = try makeSeededServices()
        // AppSettingsView installs its own Done item, as it does in RootView, so the capture adds none.
        try capture("AppSettingsView") {
            NavigationStack {
                AppSettingsView(goals: services.goals, connections: services.connections)
            }
        }
    }

    func testEntryDetailView() throws {
        let services = try makeSeededServices()
        try capture("EntryDetailView") {
            NavigationStack {
                EntryDetailView(
                    model: EntryDetailViewModel(
                        store: services.journalStore, intakeID: intakeIDs[0],
                        preferences: services.displayPreferences),
                    now: { Date() }, onFinished: {})
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Close") {} }
                    }
            }
        }
    }

    private func sampleRecipe() -> RecipeVersion {
        RecipeVersion(
            recipeID: "recipe-oat-bake", number: 1, title: "Oat bake",
            ingredients: [
                RecipeIngredient(
                    id: "oat-flour", name: "Oat flour",
                    quantity: Quantity(value: Decimal(string: "200")!, unit: .g),
                    perUnit: ["energy": .known(Decimal(string: "3.6")!, .kcal)]),
                RecipeIngredient(
                    id: "yoghurt", name: "Plain yoghurt",
                    quantity: Quantity(value: Decimal(string: "150")!, unit: .g),
                    perUnit: ["energy": .known(Decimal(string: "0.6")!, .kcal)]),
            ],
            yield: .servings(4), createdAt: Date())
    }

    func testAddIntakeView() throws {
        let services = try makeSeededServices()
        try capture("AddIntakeView") {
            NavigationStack {
                AddIntakeView(
                    model: AddIntakeViewModel(
                        store: services.journalStore, now: Date(), lookup: services.barcodeLookup,
                        preferences: services.displayPreferences),
                    onSaved: {}, onScanLabel: {})
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") {} }
                    }
            }
        }
    }

    func testGoalsView() throws {
        let services = try makeSeededServices()
        services.goals.load()
        try capture("GoalsView") { NavigationStack { GoalsView(model: services.goals) } }
    }

    func testConnectionsPrivacyView() throws {
        let services = try makeSeededServices()
        try capture("ConnectionsPrivacyView") {
            NavigationStack { ConnectionsPrivacyView(model: services.connections) }
        }
    }

    func testRecipeListView() throws {
        let services = try makeSeededServices()
        try services.recipeStore.saveNewVersion(sampleRecipe())
        let model = RecipeListViewModel(store: services.recipeStore)
        model.load()
        try capture("RecipeListView") {
            NavigationStack { RecipeListView(model: model, onNew: {}, onOpen: { _ in }) }
        }
    }

    // The add flow's first screen and the library picker, as RootView presents them, with the Cancel item.
    func testAddHomeView() throws {
        let services = try makeSeededServices()
        let home = AddHomeViewModel(store: services.journalStore, meal: .lunch,
                                    lookup: services.barcodeLookup, preferences: services.displayPreferences)
        try capture("AddHomeView") {
            NavigationStack {
                AddHomeView(model: home, onBarcode: {}, onLabel: {}, onLibrary: {}, onType: {}, onChanged: {})
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") {} }
                    }
            }
        }
    }

    func testAddLibraryPicker() throws {
        let services = try makeSeededServices()
        try services.recipeStore.saveNewVersion(sampleRecipe())
        let recipes = RecipeListViewModel(store: services.recipeStore)
        recipes.load()
        try capture("AddLibraryPicker") {
            NavigationStack {
                AddLibraryPicker(library: services.library, recipes: recipes, onPick: { _ in }, onRecipe: { _ in })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") {} }
                    }
            }
        }
    }

    func testRecipeDetailView() throws {
        let services = try makeSeededServices()
        let version = sampleRecipe()
        try services.recipeStore.saveNewVersion(version)
        try capture("RecipeDetailView") {
            NavigationStack {
                RecipeDetailView(
                    model: RecipeDetailViewModel(version: version, journal: services.journalStore),
                    onEdit: {}, onLogged: {})
            }
        }
    }

    func testRecipeEditorView() throws {
        let services = try makeSeededServices()
        let version = sampleRecipe()
        try services.recipeStore.saveNewVersion(version)
        try capture("RecipeEditorView") {
            NavigationStack {
                RecipeEditorView(
                    model: RecipeEditorViewModel(store: services.recipeStore, editing: version), onSaved: {})
            }
        }
    }

    /// An invented Nutrition Facts panel, read the way recognised camera text arrives: one string per line.
    func testLabelCaptureView() throws {
        let model = LabelCaptureViewModel()
        model.load(lines: [
            "Nutrition Facts", "Serving size 40 g", "Calories 150", "Total Fat 3 g", "Sodium 5 mg",
            "Total Carbohydrate 27 g", "Dietary Fiber 4 g", "Total Sugars 1 g", "Protein 5 g",
        ])
        try capture("LabelCaptureView") {
            // Mirrors LabelCaptureSheet, which wraps the view in its own stack, title and Cancel.
            NavigationStack {
                LabelCaptureView(model: model, onUse: { _ in })
                    .navigationTitle(model.isReviewing ? "Check the label" : "Scan the label")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") {} }
                    }
            }
        }
    }

    func testWelcomeView() throws {
        try capture("WelcomeView") { WelcomeView(onStart: {}, onRestore: {}) }
    }

    /// The first-day checklist on an empty store, as a first launch shows it.
    func testFirstDayChecklistView() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthNutritionScreenshots", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
        let model = FirstDayChecklistModel(
            store: store, goals: nil, preferences: InMemoryDisplayPreferences())
        model.load()
        try capture("FirstDayChecklistView") {
            ScrollView {
                FirstDayChecklistView(model: model, onLog: {}, onGoals: {}, onUnits: {})
                    .padding()
            }
        }
    }

    func testStartupFailureView() throws {
        try capture("StartupFailureView") {
            StartupFailureView(message: "The journal store file could not be opened.")
        }
    }
}
