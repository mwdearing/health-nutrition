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
        .target(name: "NutritionUI", dependencies: ["NutritionCore", "NutritionDomain", "NutritionJournal"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NutritionUITests", dependencies: ["NutritionUI", "NutritionJournal"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
