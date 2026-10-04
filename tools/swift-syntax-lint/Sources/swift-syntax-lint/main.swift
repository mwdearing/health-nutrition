/// `swift-syntax-lint`: the spike's command line.
///
/// Usage:
///     swift run swift-syntax-lint [ROOT]
///
/// ROOT defaults to `ios/NutritionCore`. Every finding is printed as
/// `path:line: rule: message`, and the exit code is 0 for a clean tree, 1 when
/// there is at least one finding and 2 on a usage error, which is the contract
/// `scripts/lint_swift_sources.py` already has.
import Foundation
import SwiftSyntaxLint

let arguments = CommandLine.arguments
let root = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "ios/NutritionCore")

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
else {
    FileHandle.standardError.write(Data("error: not a directory: \(root.path)\n".utf8))
    exit(2)
}

let findings = Lint.findings(overRoots: Lint.rootsToLint(root: root))
for finding in findings {
    print(finding.formatted)
}
if !findings.isEmpty {
    let summary = "\(findings.count) finding(s).\n"
    FileHandle.standardError.write(Data(summary.utf8))
    exit(1)
}
