// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NutritionCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "NutritionCore", targets: ["NutritionCore"]),
        .library(name: "NutritionDomain", targets: ["NutritionDomain"]),
        .library(name: "NutritionProviders", targets: ["NutritionProviders"]),
        .library(name: "NutritionJournal", targets: ["NutritionJournal"]),
        .library(name: "NutritionUI", targets: ["NutritionUI"]),
    ],
    targets: [
        .target(name: "NutritionCore"),
        .testTarget(name: "NutritionCoreTests", dependencies: ["NutritionCore"]),
        .target(name: "NutritionDomain", path: "Sources/NutritionDomain"),
        .testTarget(name: "NutritionDomainTests", dependencies: ["NutritionDomain"]),
        .target(name: "NutritionProviders", dependencies: ["NutritionDomain"]),
        .testTarget(name: "NutritionProvidersTests", dependencies: ["NutritionProviders"], resources: [.copy("Fixtures")]),
        .target(name: "JournalStoreSpike", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "JournalStoreSpikeTests", dependencies: ["JournalStoreSpike"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "NutritionJournal", dependencies: ["NutritionDomain"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NutritionJournalTests", dependencies: ["NutritionJournal"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NutritionJournalExportTests", dependencies: ["NutritionJournal", "NutritionDomain"], resources: [.copy("Contracts")], swiftSettings: [.swiftLanguageMode(.v5)]),
        // The label capture screen parses a captured panel with NutritionFactsParser, so the UI module
        // links the providers. It links nothing else from there: no camera, no networking.
        .target(name: "NutritionUI", dependencies: ["NutritionCore", "NutritionDomain", "NutritionJournal", "NutritionProviders"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NutritionUITests", dependencies: ["NutritionUI", "NutritionJournal", "NutritionProviders"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ConnectionsPrivacyTests", dependencies: ["NutritionUI", "NutritionJournal", "NutritionDomain"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
