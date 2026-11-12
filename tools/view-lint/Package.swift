// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ViewLint",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0")
    ],
    targets: [
        .executableTarget(
            name: "ViewLint",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ]
        )
    ]
)
