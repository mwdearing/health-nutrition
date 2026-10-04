/// The two rules of `scripts/lint_swift_sources.py` that this spike reimplements
/// on a SwiftSyntax tree: `unlabeled-image` and `fixed-font-size`.
///
/// The meanings are the Python script's, read from its docstring and from
/// `docs/swift-lint.md`; nothing here changes what that script enforces. The
/// spike exists to find out whether a syntax tree makes the same rules simpler
/// and more correct, and the corpus test measures the difference.
import Foundation
import SwiftParser
import SwiftSyntax

/// One reported problem, in the same shape the Python lint prints.
public struct Finding: Equatable, Sendable {
    public let path: String
    public let line: Int
    public let rule: String
    public let message: String

    public init(path: String, line: Int, rule: String, message: String) {
        self.path = path
        self.line = line
        self.rule = rule
        self.message = message
    }

    /// The `path:line: rule: message` line the Python lint would print.
    public var formatted: String {
        "\(path):\(line): \(rule): \(message)"
    }
}

/// A rule and the message it reports, so the two implementations can be held to
/// the same wording.
public struct Rule: Sendable {
    public let name: String
    public let message: String

    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }
}

public enum Rules {
    public static let unlabeledImage = Rule(
        name: "unlabeled-image",
        message: """
            image without an accessibility label; add .accessibilityLabel(...) \
            or mark it decorative with .accessibilityHidden(true)
            """
    )

    public static let fixedFontSize = Rule(
        name: "fixed-font-size",
        message: """
            literal point size, which Dynamic Type cannot scale; use a text style, \
            or Font.custom(_:size:), which scales with the body style
            """
    )

    public static let all: [Rule] = [unlabeledImage, fixedFontSize]
}

/// The layer a path belongs to, which decides whether the view rules apply.
public enum Scope {
    /// The package module keeps its views under `Sources/NutritionUI/`; its other
    /// modules are domain and provider code that never import SwiftUI, so they
    /// are out of scope even though they sit under `Sources/` too.
    case package
    /// The app target keeps its views directly under its own `Sources/`, which
    /// makes every file there a view surface.
    case app
    /// Anything else, where neither view rule applies.
    case other

    public init(rootName: String, relativePath: String) {
        let path = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
        if rootName == Lint.appRootName {
            self = path.hasPrefix("Sources/") ? .app : .other
        } else {
            self = path.hasPrefix("Sources/NutritionUI/") ? .package : .other
        }
    }

    public var lintsViews: Bool {
        self != .other
    }
}

public enum Lint {
    /// The app target, which a run over the package root also has to cover.
    public static let appRootName = "HealthNutrition"
    public static let packageRootName = "NutritionCore"
    /// Directories never walked, matching the Python script.
    public static let skippedDirectories: Set<String> = [
        ".build", ".git", "DerivedData", "node_modules",
    ]

    /// The findings for one source file, given the root it was found under.
    ///
    /// - Parameters:
    ///   - source: the whole file.
    ///   - path: the path the findings are reported under.
    ///   - relativePath: the path relative to the root, which picks the scope.
    ///   - rootName: the last component of the root directory.
    public static func findings(
        in source: String,
        path: String,
        relativePath: String,
        rootName: String
    ) -> [Finding] {
        let scope = Scope(rootName: rootName, relativePath: relativePath)
        guard scope.lintsViews else { return [] }
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let context = FileContext(
            tree: tree,
            converter: converter,
            allows: Allowances(tree: tree, converter: converter)
        )
        var found: [Finding] = []
        for line in UnlabeledImageRule.findingLines(context) {
            found.append(
                Finding(
                    path: path,
                    line: line,
                    rule: Rules.unlabeledImage.name,
                    message: Rules.unlabeledImage.message
                )
            )
        }
        for line in FixedFontSizeRule.findingLines(context) {
            found.append(
                Finding(
                    path: path,
                    line: line,
                    rule: Rules.fixedFontSize.name,
                    message: Rules.fixedFontSize.message
                )
            )
        }
        return found.sorted { left, right in
            left.rule == right.rule ? left.line < right.line : left.rule < right.rule
        }
    }

    /// The findings for one file on disk.
    ///
    /// `relativeTo` is the root the file was found under, which is what decides
    /// the scope: the path relative to it says whether the file is a SwiftUI view
    /// surface at all.
    public static func findings(atFile file: URL, relativeTo root: URL) -> [Finding] {
        guard let source = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        let relative = filePath.hasPrefix(rootPath + "/")
            ? String(filePath.dropFirst(rootPath.count + 1))
            : file.lastPathComponent
        return findings(
            in: source,
            path: filePath,
            relativePath: relative,
            rootName: root.lastPathComponent
        )
    }

    /// The findings over a directory of Swift sources.
    ///
    /// A run over the package root also lints the app target beside it, which is
    /// what the CI invocation that names only the package root relies on.
    public static func findings(overRoots roots: [URL]) -> [Finding] {
        var found: [Finding] = []
        for root in roots {
            for file in swiftFiles(in: root) {
                found.append(contentsOf: findings(atFile: file, relativeTo: root))
            }
        }
        return found
    }

    /// The roots one run covers: the one given, and the app target beside it.
    public static func rootsToLint(root: URL) -> [URL] {
        var roots = [root]
        guard root.lastPathComponent != appRootName else { return roots }
        let sibling = root.deletingLastPathComponent().appendingPathComponent(appRootName)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: sibling.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            roots.append(sibling)
        }
        return roots
    }

    /// Every Swift file under a root, in a stable order, skipping build output.
    public static func swiftFiles(in root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let file as URL in walker {
            if skippedDirectories.contains(file.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard file.pathExtension == "swift" else { continue }
            files.append(file)
        }
        return files.sorted { $0.path < $1.path }
    }
}

/// Everything a rule needs about the file it is reading: the tree, a way to turn
/// a node into a line, and the `lint-allow` directives.
struct FileContext {
    let tree: SourceFileSyntax
    let converter: SourceLocationConverter
    let allows: Allowances

    func line(of node: some SyntaxProtocol) -> Int {
        converter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }
}

/// The `lint-allow` directives in a file, read from real comments only.
///
/// A line whose trailing comment is `// lint-allow: <rule>` is skipped for that
/// rule, which is how a single line with a good reason to break a rule is
/// exempted. The same text inside a string literal grants nothing, so the
/// directives are read from the tree's trivia rather than from the raw text.
struct Allowances {
    private var byLine: [Int: Set<String>] = [:]

    init(tree: SourceFileSyntax, converter: SourceLocationConverter) {
        for token in tree.tokens(viewMode: .sourceAccurate) {
            let line = converter.location(for: token.positionAfterSkippingLeadingTrivia).line
            for piece in token.leadingTrivia + token.trailingTrivia {
                // Only a developer comment is a directive; the documentation
                // forms are prose and are not consulted.
                guard case .lineComment(let text) = piece else { continue }
                guard let rules = Allowances.rules(in: text) else { continue }
                byLine[line, default: []].formUnion(rules)
            }
        }
    }

    /// The rule names a comment allows, or `nil` when it is not a directive.
    static func rules(in comment: String) -> Set<String>? {
        // A documentation comment is prose, not a directive. The parser hands
        // those over as their own trivia pieces, but the text is checked too so
        // that a `///` written where a comment was expected stays inert.
        guard comment.hasPrefix("//"), !comment.hasPrefix("///") else { return nil }
        guard let marker = comment.range(of: "lint-allow:") else { return nil }
        let names = comment[marker.upperBound...].trimmingCharacters(in: .whitespaces)
        let allowed = names
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
            .map { String($0).replacingOccurrences(of: "_", with: "-") }
            .filter { !$0.isEmpty }
        return allowed.isEmpty ? nil : Set(allowed)
    }

    /// Whether the rule is allowed on a line.
    func allows(_ rule: String, onLine line: Int) -> Bool {
        byLine[line]?.contains(rule) ?? false
    }
}
