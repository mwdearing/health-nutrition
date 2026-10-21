import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders
import XCTest

@testable import HealthNutrition

/// The intake IDs of the seeded day, so tests can find the entries they expect.
let seededIntakeIDs = [
    "6f1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
    "7a2c3d4e-5f60-4b7c-9d8e-0f1a2b3c4d5e",
    "8b3d4e5f-6071-4c8d-8e9f-1a2b3c4d5e6f",
]

/// An app on throwaway files with a day of invented entries and two goals. Shared by the screenshot and the layout tests.
func makeSeededAppServices(productService: (any CommunityProductServicing)? = nil) throws -> AppServices {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HealthNutritionScreenshots", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let services = try AppServices.make(directory: directory, reminderScheduler: RecordingReminderScheduler(), productService: productService)
    let start = Calendar.current.startOfDay(for: Date())
    let zone = TimeZone.current.identifier
    // Protein is known only when the entry carries its product's facts, so the oats carry them.
    let oats = ProductDefinition(
        snapshotID: "screenshot-oats", productID: "screenshot-oats-product", name: "Rolled oats", brand: nil,
        barcode: nil, labelBasis: "per100g", catalogOrigin: "sample", catalogVersion: "1",
        nutrients: ["protein": .known(Decimal(13), .g)])
    let entries: [(String, String, String?, [IntakeComponent])] = [
        (seededIntakeIDs[0], "food", "breakfast",
         [IntakeComponent(componentID: "oats", name: "Rolled oats", amount: 40, unit: .g),
          IntakeComponent(componentID: "milk", name: "Whole milk", amount: 150, unit: .mL)]),
        (seededIntakeIDs[1], "water", nil,
         [IntakeComponent(componentID: "water", name: "Water", amount: 250, unit: .mL)]),
        (seededIntakeIDs[2], "food", "lunch",
         [IntakeComponent(componentID: "lentils", name: "Lentil soup", amount: 300, unit: .g)]),
    ]
    for (index, entry) in entries.enumerated() {
        let intake = Intake(
            id: entry.0, category: entry.1, occurredAt: start.addingTimeInterval(Double(60 * (index + 1))),
            timeZoneIdentifier: zone, meal: entry.2)
        try services.journalStore.create(intake, components: entry.3, product: index == 0 ? oats : nil, now: Date())
    }
    try services.goalStore.setGoal(NutrientGoal(nutrient: "protein", target: 90, unit: .g))
    try services.goalStore.setGoal(NutrientGoal(nutrient: "water", target: 2000, unit: .mL))
    return services
}
