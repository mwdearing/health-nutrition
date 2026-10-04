// swift-tools-version: 6.0
//
// A spike: the two accessibility lint rules of scripts/lint_swift_sources.py,
// implemented on a SwiftSyntax tree instead of with regular expressions.
//
// The package is deliberately separate from the app: nothing here is built into
// the shipping targets, and nothing here blocks a pull request. See README.md.
import PackageDescription

let package = Package(
    name: "swift-syntax-lint",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "swift-syntax-lint", targets: ["swift-syntax-lint"]),
        .library(name: "SwiftSyntaxLint", targets: ["SwiftSyntaxLint"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax", exact: "600.0.0"),
    ],
    targets: [
        // The rules, split out from the command line so the corpus test can run
        // them without going through a process.
        .target(
            name: "SwiftSyntaxLint",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "swift-syntax-lint",
            dependencies: ["SwiftSyntaxLint"]
        ),
        .testTarget(
            name: "SwiftSyntaxLintTests",
            dependencies: [
                "SwiftSyntaxLint",
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            // The corpus sits beside the test target rather than inside it, so
            // that `scripts/export_lint_corpus.py` has one obvious place to write.
            path: "Tests",
            resources: [.copy("corpus.json")]
        ),
    ]
)
