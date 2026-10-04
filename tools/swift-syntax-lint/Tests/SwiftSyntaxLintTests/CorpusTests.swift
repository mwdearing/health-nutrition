/// Runs every case of the shared corpus through the spike's own rules.
///
/// The corpus is written by `scripts/export_lint_corpus.py` from the cases in
/// `scripts/tests/test_lint_swift_sources.py`, and it carries what the Python
/// lint reports for each snippet. Running the same snippets here and comparing
/// is the measurement the spike exists to make: the README records the outcome,
/// and this test prints the same table on every run.
import Foundation
import XCTest

@testable import SwiftSyntaxLint

/// One case as the corpus records it.
private struct Corpus: Decodable {
    struct File: Decodable {
        let path: String
        let source: String
    }

    struct Finding: Decodable, Hashable, CustomStringConvertible {
        let path: String
        let line: Int
        let rule: String

        var description: String {
            "\(path):\(line): \(rule)"
        }
    }

    struct Case: Decodable {
        let name: String
        let lintRoot: String
        let files: [File]
        let expected: [Finding]
    }

    let rules: [String]
    let cases: [Case]
}

/// One case, with what the Python rules expect of it and what the spike's rules
/// report for it.
private struct Outcome {
    let entry: Corpus.Case
    let expected: [Corpus.Finding]
    let actual: [Corpus.Finding]
}

/// How much of the corpus has to agree for the run to count as a measurement.
///
/// The floor is here to catch a reimplementation that is simply broken, not to
/// encode which cases are expected to agree: a disagreement is a result, and the
/// spike reports it rather than failing on it.
private let minimumAgreement = 0.75

final class CorpusTests: XCTestCase {
    /// Every case, and the findings the spike's rules report for it.
    private func agreement() throws -> [Outcome] {
        let corpus = try loadCorpus()
        return try corpus.cases.map { entry in
            Outcome(entry: entry, expected: entry.expected, actual: try findings(for: entry))
        }
    }

    func test_the_corpus_covers_both_rules() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.rules, ["unlabeled-image", "fixed-font-size"])
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 20)
        let reported = Set(corpus.cases.flatMap { $0.expected.map(\.rule) })
        XCTAssertEqual(reported, Set(corpus.rules))
        // A corpus of only reported cases would not show where the two rules
        // differ in the other direction, so the clean cases matter too.
        XCTAssertGreaterThanOrEqual(corpus.cases.filter { $0.expected.isEmpty }.count, 5)
    }

    func test_the_corpus_cases_agree() throws {
        let results = try agreement()
        var agreed = 0
        var lines: [String] = []
        for result in results {
            if Set(result.expected) == Set(result.actual) {
                agreed += 1
            } else {
                lines.append(
                    "\(result.entry.name): expected \(describe(result.expected)), "
                        + "got \(describe(result.actual))"
                )
            }
        }
        let share = Double(agreed) / Double(results.count)
        let report = """
            swift-syntax-lint agrees with the Python lint on \(agreed) of \
            \(results.count) corpus cases (\(Int(share * 100))%).
            \(lines.isEmpty ? "No case disagrees." : "Disagreements:\n  \(lines.joined(separator: "\n  "))")

            """
        print(report)
        XCTAssertGreaterThanOrEqual(
            share,
            minimumAgreement,
            "the spike disagrees with the Python lint on too much of the corpus:\n"
                + lines.joined(separator: "\n")
        )
    }

    /// Both rules have to keep quiet on a clean tree and speak on a bad one, so a
    /// rule that silently stopped working cannot pass as agreement.
    func test_the_rules_report_nothing_on_a_clean_tree() throws {
        let clean = """
            import SwiftUI

            struct Clean: View {
                var body: some View {
                    Button {
                        add()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add water")
                    Text("Water").font(.headline)
                }

                private func add() {}
            }

            """
        let found = Lint.findings(
            in: clean,
            path: "Clean.swift",
            relativePath: "Sources/Clean.swift",
            rootName: "NutritionCore"
        )
        XCTAssertEqual(found, [])
    }

    func test_lint_allow_exempts_the_line_it_is_written_on() throws {
        let source = """
            import SwiftUI

            let allowed = Image(systemName: "dot") // lint-allow: unlabeled-image
            let pinned = Font.custom("Inter", fixedSize: 11) // lint-allow: fixed-font-size
            let reported = Image(systemName: "dot")
            let alsoReported = Font.custom("Inter", fixedSize: 11)

            """
        let found = Lint.findings(
            in: source,
            path: "Allowed.swift",
            relativePath: "Sources/NutritionUI/Allowed.swift",
            rootName: "NutritionCore"
        )
        XCTAssertEqual(found.map { "\($0.line): \($0.rule)" }, ["5: unlabeled-image", "6: fixed-font-size"])
    }

    func test_the_same_text_inside_a_string_allows_nothing() throws {
        let source = """
            import SwiftUI

            let sample = "// lint-allow: unlabeled-image"
            let reported = Image(systemName: "dot")

            """
        let found = Lint.findings(
            in: source,
            path: "Prose.swift",
            relativePath: "Sources/NutritionUI/Prose.swift",
            rootName: "NutritionCore"
        )
        // The directive is on line 3, inside a string literal, so it grants
        // nothing and the image on line 4 is still reported.
        XCTAssertEqual(found.map(\.line), [4])
    }

    func test_a_finding_is_printed_in_the_python_format() {
        let finding = Finding(
            path: "ios/NutritionCore/Sources/NutritionUI/Row.swift",
            line: 5,
            rule: Rules.unlabeledImage.name,
            message: Rules.unlabeledImage.message
        )
        XCTAssertTrue(finding.formatted.hasPrefix("ios/NutritionCore/Sources/NutritionUI/Row.swift:5: unlabeled-image: "))
    }

    // MARK: - Running a case

    private func loadCorpus() throws -> Corpus {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "corpus", withExtension: "json"),
            "corpus.json is missing from the test bundle"
        )
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    /// Write a case out as a tree and run the rules over it, the way the Python
    /// lint is run over the same tree.
    private func findings(for entry: Corpus.Case) throws -> [Corpus.Finding] {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-syntax-lint-corpus-\(UUID().uuidString)")
            .appendingPathComponent("ios")
        defer { try? FileManager.default.removeItem(at: container.deletingLastPathComponent()) }
        for file in entry.files {
            let path = container.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.source.write(to: path, atomically: true, encoding: .utf8)
        }
        let root = container.appendingPathComponent(entry.lintRoot)
        let found = Lint.findings(overRoots: [root])
        // The findings carry the path they were read from, so they are rewritten
        // back into the corpus's own paths before being compared.
        let prefix = container.standardizedFileURL.path + "/"
        return found.map { finding in
            Corpus.Finding(
                path: finding.path.hasPrefix(prefix)
                    ? String(finding.path.dropFirst(prefix.count))
                    : finding.path,
                line: finding.line,
                rule: finding.rule
            )
        }
    }

    private func describe(_ findings: [Corpus.Finding]) -> String {
        findings.isEmpty
            ? "nothing"
            : findings.map(\.description).sorted().joined(separator: ", ")
    }
}
