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
    ],
    targets: [
        .target(name: "NutritionCore"),
        .testTarget(name: "NutritionCoreTests", dependencies: ["NutritionCore"]),
        .target(name: "NutritionDomain", path: "Sources/NutritionDomain"),
        .testTarget(name: "NutritionDomainTests", dependencies: ["NutritionDomain"]),
        .target(name: "JournalStoreSpike", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "JournalStoreSpikeTests", dependencies: ["JournalStoreSpike"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
