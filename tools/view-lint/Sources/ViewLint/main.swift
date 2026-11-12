import Foundation
import SwiftParser
import SwiftSyntax

// A SwiftSyntax version of two rules of scripts/lint_swift_sources.py, `unlabeled-image` and `fixed-font-size`.
// Usage: view-lint <file-or-directory>...   Prints `path:line: rule: message`, exits 1 on a finding.

let controlNames: Set<String> = [
    "Button", "Menu", "Toggle", "Label", "Link", "NavigationLink", "Picker",
    "Stepper", "Slider", "DisclosureGroup", "ControlGroup", "EditButton",
]
let contentControls: Set<String> = ["Menu", "Picker", "ControlGroup"]
let labelClosureNames: Set<String> = ["label", "title", "icon", "badge"]

/// A call's name with a `SwiftUI.` qualifier removed. Any other qualifier names a type of its own.
func callName(_ call: FunctionCallExprSyntax) -> String? {
    if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) { return reference.baseName.text }
    if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
       let base = member.base?.as(DeclReferenceExprSyntax.self), base.baseName.text == "SwiftUI" {
        return member.declName.baseName.text
    }
    return nil
}

func isTrueLiteral(_ expression: ExprSyntax) -> Bool {
    expression.as(BooleanLiteralExprSyntax.self)?.literal.text == "true"
}

/// Whether a modifier named `name` called with `call` is a name or a hiding for VoiceOver.
func namesOrHides(_ name: String, _ call: FunctionCallExprSyntax?) -> Bool {
    if name == "accessibilityLabel" { return call != nil }
    if name == "accessibilityHidden", let first = call?.arguments.first { return isTrueLiteral(first.expression) }
    return false
}

/// Whether the postfix expression `expression` (the body of one `#if` arm, such as `.accessibilityLabel("x")`)
/// carries a naming modifier, descending into nested postfix conditionals that hold in every build.
func armNames(_ expression: ExprSyntax, _ predicate: (String, FunctionCallExprSyntax?) -> Bool) -> Bool {
    var current: ExprSyntax? = expression
    while let node = current {
        if let call = node.as(FunctionCallExprSyntax.self) {
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                if predicate(member.declName.baseName.text, call) { return true }
                current = member.base
            } else {
                current = call.calledExpression
            }
        } else if let member = node.as(MemberAccessExprSyntax.self) {
            if predicate(member.declName.baseName.text, nil) { return true }
            current = member.base
        } else if let postfix = node.as(PostfixIfConfigExprSyntax.self) {
            if conditionalHolds(postfix.config, predicate) { return true }
            current = postfix.base
        } else {
            return false
        }
    }
    return false
}

/// A `#if` after an expression holds when every arm names it and an `#else` makes the arms exhaustive.
func conditionalHolds(_ config: IfConfigDeclSyntax, _ predicate: (String, FunctionCallExprSyntax?) -> Bool) -> Bool {
    var hasElse = false
    for clause in config.clauses {
        if clause.condition == nil { hasElse = true }
        guard case .postfixExpression(let expression)? = clause.elements else { return false }
        if !armNames(expression, predicate) { return false }
    }
    return hasElse
}

/// Whether the modifier chain written after `node` satisfies `predicate` in every build.
func chainHolds(after node: Syntax, _ predicate: (String, FunctionCallExprSyntax?) -> Bool) -> Bool {
    var current = node
    while let parent = current.parent {
        if let member = parent.as(MemberAccessExprSyntax.self), member.base.map({ Syntax($0).id }) == current.id {
            if let call = member.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == member.id {
                if predicate(member.declName.baseName.text, call) { return true }
                current = Syntax(call)
            } else {
                if predicate(member.declName.baseName.text, nil) { return true }
                current = Syntax(member)
            }
        } else if let postfix = parent.as(PostfixIfConfigExprSyntax.self), postfix.base.map({ Syntax($0).id }) == current.id {
            if conditionalHolds(postfix.config, predicate) { return true }
            current = Syntax(postfix)
        } else {
            return false
        }
    }
    return false
}

/// The closure's role in a call: the call, and the argument label it is written with (empty for the first trailing closure).
func closureRole(_ closure: ClosureExprSyntax) -> (FunctionCallExprSyntax, String)? {
    var parent = closure.parent
    // A trailing closure.
    if let call = parent?.as(FunctionCallExprSyntax.self), call.trailingClosure?.id == closure.id { return (call, "") }
    // An additional trailing closure: `label: { ... }`.
    if let element = parent?.as(MultipleTrailingClosureElementSyntax.self),
       let call = element.parent?.parent?.as(FunctionCallExprSyntax.self) {
        return (call, element.label.text)
    }
    // An argument: `label: { ... }` inside the argument list.
    if let argument = parent?.as(LabeledExprSyntax.self) {
        parent = argument.parent?.parent
        if let call = parent?.as(FunctionCallExprSyntax.self) { return (call, argument.label?.text ?? "") }
    }
    return nil
}

/// Whether a `content:` argument was passed to the control call itself.
func hasContentArgument(_ call: FunctionCallExprSyntax) -> Bool {
    call.arguments.contains { $0.label?.text == "content" }
}

final class Linter: SyntaxVisitor {
    let converter: SourceLocationConverter
    let path: String
    var findings: [(Int, String, String)] = []
    private var fontArgumentDepth = 0

    init(path: String, tree: SourceFileSyntax) {
        self.path = path
        converter = SourceLocationConverter(fileName: path, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    func line(_ node: SyntaxProtocol) -> Int { converter.location(for: node.positionAfterSkippingLeadingTrivia).line }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let name = callName(node) {
            if name == "Image" { checkImage(node) }
        }
        checkFont(node)
        return .visitChildren
    }

    // MARK: unlabeled-image

    func checkImage(_ image: FunctionCallExprSyntax) {
        if image.arguments.first?.label?.text == "decorative" { return }
        let imageNode = Syntax(image)
        if chainHolds(after: imageNode, { namesOrHides($0, $1) }) { return }
        if let (control, closure) = labelControl(of: imageNode) {
            if chainHolds(after: Syntax(control), { namesOrHides($0, $1) }) { return }
            for scope in labelScopes(control, closure) where visibleText(in: scope) { return }
        }
        findings.append((line(image), "unlabeled-image", "image without an accessibility label"))
    }

    /// The control an image is the label of, and the label closure it sits in. Plain layouts are climbed through.
    func labelControl(of node: Syntax) -> (FunctionCallExprSyntax, ClosureExprSyntax)? {
        var current: Syntax? = node.parent
        while let candidate = current {
            if let closure = candidate.as(ClosureExprSyntax.self), let (call, label) = closureRole(closure),
               let name = callName(call), controlNames.contains(name) {
                if contentControls.contains(name), label.isEmpty || !labelClosureNames.contains(label),
                   !(label.isEmpty && hasContentArgument(call)) {
                    // The closure holds the options of the control, not its label.
                    current = candidate.parent
                    continue
                }
                return (call, closure)
            }
            current = candidate.parent
        }
        return nil
    }

    func labelScopes(_ control: FunctionCallExprSyntax, _ closure: ClosureExprSyntax) -> [Syntax] {
        var scopes = [Syntax(closure)]
        if callName(control) == "Label" {
            for other in closures(of: control) where other.id != closure.id { scopes.append(Syntax(other)) }
        }
        return scopes
    }

    func closures(of call: FunctionCallExprSyntax) -> [ClosureExprSyntax] {
        var found: [ClosureExprSyntax] = []
        if let trailing = call.trailingClosure { found.append(trailing) }
        for element in call.additionalTrailingClosures { found.append(element.closure) }
        for argument in call.arguments { if let closure = argument.expression.as(ClosureExprSyntax.self) { found.append(closure) } }
        return found
    }

    /// Whether `scope` holds a `Text` that VoiceOver reads in every build. A text hidden with
    /// `.accessibilityHidden(true)` in any build, including one `#if` arm alone, names nothing there.
    func visibleText(in scope: Syntax) -> Bool {
        let collector = TextCollector(viewMode: .sourceAccurate)
        collector.walk(scope)
        return collector.texts.contains { !mayBeHidden(Syntax($0)) }
    }

    /// Whether the chain written after `node` hides it in some build.
    func mayBeHidden(_ node: Syntax) -> Bool {
        var current = node
        while let parent = current.parent {
            if let member = parent.as(MemberAccessExprSyntax.self), member.base.map({ Syntax($0).id }) == current.id {
                if let call = member.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == member.id {
                    if hides(member.declName.baseName.text, call) { return true }
                    current = Syntax(call)
                } else {
                    current = Syntax(member)
                }
            } else if let postfix = parent.as(PostfixIfConfigExprSyntax.self), postfix.base.map({ Syntax($0).id }) == current.id {
                for clause in postfix.config.clauses {
                    if case .postfixExpression(let expression)? = clause.elements, armHides(expression) { return true }
                }
                current = Syntax(postfix)
            } else {
                return false
            }
        }
        return false
    }

    func hides(_ name: String, _ call: FunctionCallExprSyntax?) -> Bool {
        name == "accessibilityHidden" && (call?.arguments.first.map { isTrueLiteral($0.expression) } ?? false)
    }

    func armHides(_ expression: ExprSyntax) -> Bool {
        var current: ExprSyntax? = expression
        while let node = current {
            if let call = node.as(FunctionCallExprSyntax.self), let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                if hides(member.declName.baseName.text, call) { return true }
                current = member.base
            } else if let call = node.as(FunctionCallExprSyntax.self) {
                current = call.calledExpression
            } else if let member = node.as(MemberAccessExprSyntax.self) {
                current = member.base
            } else if let postfix = node.as(PostfixIfConfigExprSyntax.self) {
                for clause in postfix.config.clauses {
                    if case .postfixExpression(let inner)? = clause.elements, armHides(inner) { return true }
                }
                current = postfix.base
            } else {
                return false
            }
        }
        return false
    }

    // MARK: fixed-font-size

    func checkFont(_ call: FunctionCallExprSyntax) {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return }
        let name = member.declName.baseName.text
        guard ["system", "custom", "pointSize"].contains(name) else { return }
        if call.arguments.contains(where: { $0.label?.text == "relativeTo" }) { return }
        guard buildsAFont(call, member, name) else { return }
        let literal: Bool
        switch name {
        case "system": literal = call.arguments.contains { $0.label?.text == "size" && isNumericLiteral($0.expression) }
        case "custom": literal = call.arguments.contains { $0.label?.text == "fixedSize" && isNumericLiteral($0.expression) }
        default: literal = call.arguments.first.map { $0.label == nil && isNumericLiteral($0.expression) } ?? false
        }
        if literal { findings.append((line(call), "fixed-font-size", "literal point size")) }
    }

    func isNumericLiteral(_ expression: ExprSyntax) -> Bool {
        expression.is(IntegerLiteralExprSyntax.self) || expression.is(FloatLiteralExprSyntax.self)
    }

    /// `.system` is always a font factory; `.custom` and `.pointSize` only on `Font` or inside a `.font(...)` call.
    func buildsAFont(_ call: FunctionCallExprSyntax, _ member: MemberAccessExprSyntax, _ name: String) -> Bool {
        if name == "system" { return true }
        if rootIsFont(member.base) { return true }
        var current: Syntax? = Syntax(call).parent
        while let node = current {
            if let outer = node.as(FunctionCallExprSyntax.self),
               let outerMember = outer.calledExpression.as(MemberAccessExprSyntax.self),
               outerMember.declName.baseName.text == "font" { return true }
            current = node.parent
        }
        return false
    }

    func rootIsFont(_ expression: ExprSyntax?) -> Bool {
        var current = expression
        while let node = current {
            if let reference = node.as(DeclReferenceExprSyntax.self) { return reference.baseName.text == "Font" }
            if let member = node.as(MemberAccessExprSyntax.self) { current = member.base; continue }
            if let call = node.as(FunctionCallExprSyntax.self) { current = call.calledExpression; continue }
            return false
        }
        return false
    }
}

final class TextCollector: SyntaxVisitor {
    var texts: [FunctionCallExprSyntax] = []
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if callName(node) == "Text" { texts.append(node) }
        return .visitChildren
    }
}

func swiftFiles(_ path: String) -> [String] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return [] }
    if !isDirectory.boolValue { return [path] }
    let skipped: Set<String> = [".build", ".git", "DerivedData", "node_modules"]
    var files: [String] = []
    if let walker = FileManager.default.enumerator(atPath: path) {
        for case let relative as String in walker {
            let parts = relative.split(separator: "/").map(String.init)
            if parts.contains(where: skipped.contains) { continue }
            if relative.hasSuffix(".swift") { files.append((path as NSString).appendingPathComponent(relative)) }
        }
    }
    return files.sorted()
}

var failed = false
for argument in CommandLine.arguments.dropFirst() {
    for file in swiftFiles(argument) {
        guard let source = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
        let tree = Parser.parse(source: source)
        if ProcessInfo.processInfo.environment["VIEW_LINT_DUMP"] != nil { print(tree.debugDescription) }
        let linter = Linter(path: file, tree: tree)
        linter.walk(tree)
        for (line, rule, message) in linter.findings.sorted(by: { $0.0 < $1.0 }) {
            print("\(file):\(line): \(rule): \(message)")
            failed = true
        }
    }
}
exit(failed ? 1 : 0)
