// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NutritionCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v13),
    ],
    products: [
        .library(name: "NutritionCore", targets: ["NutritionCore"]),
    ],
    targets: [
        .target(name: "NutritionCore"),
        .testTarget(name: "NutritionCoreTests", dependencies: ["NutritionCore"]),
    ]
)
