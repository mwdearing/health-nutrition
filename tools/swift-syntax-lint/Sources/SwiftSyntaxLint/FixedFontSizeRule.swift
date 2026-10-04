/// `fixed-font-size`: no font pinned to a literal point size.
///
/// A literal point size does not move when the reader changes their Dynamic Type
/// setting, while a text style does. The Python rule finds these with regular
/// expressions over the masked source and then re-derives which call each match
/// belongs to; the tree answers that directly, because `.custom(` here *is* a
/// member access whose base says whether it builds a font.
import SwiftSyntax

enum FixedFontSizeRule {
    /// The font calls a literal point size can be written in.
    static let fontCallNames: Set<String> = ["system", "custom", "pointSize"]

    /// The finding lines of one file, with `lint-allow` exemptions applied.
    static func findingLines(_ context: FileContext) -> [Int] {
        let visitor = FontVisitor(viewMode: .sourceAccurate)
        visitor.walk(context.tree)
        var lines: [Int] = []
        for call in visitor.fonts where pinsASize(call) {
            let line = context.line(of: call)
            if context.allows.allows(Rules.fixedFontSize.name, onLine: line) { continue }
            lines.append(line)
        }
        return lines.sorted()
    }

    /// Whether a font call names a literal point size that Dynamic Type cannot
    /// move.
    ///
    /// `.system(.body, design: .rounded)` names a text style and stays silent, as
    /// does `.custom("Inter", size: 14)`, which SwiftUI scales with the body text
    /// style, and a size read from a `@ScaledMetric` property, which already
    /// tracks the reader's settings. A `relativeTo:` argument of the font call
    /// itself is the documented way to relate a literal size to a text style.
    static func pinsASize(_ call: FunctionCallExprSyntax) -> Bool {
        // The argument list of the call is the tree's own, so a `relativeTo:`
        // written inside a nested call belongs to that call and not to this one.
        if call.arguments.contains(where: { $0.label?.text == "relativeTo" }) {
            return false
        }
        let size: ExprSyntax?
        switch call.fontName {
        case "system":
            size = call.arguments.first { $0.label?.text == "size" }?.expression
        case "custom":
            // Only the custom-font factory counts, so a `.custom(` on another type
            // is that type's own and never reaches here.
            size = call.arguments.first { $0.label?.text == "fixedSize" }?.expression
        case "pointSize":
            size = call.arguments.first?.expression
        default:
            return false
        }
        guard let size else { return false }
        return isLiteral(size)
    }

    /// The name of the font call, or `nil` for a call that builds no font.
    ///
    /// A call spelled on `Font` is that type's own, as in `Font.custom(` or
    /// `Font.title.pointSize(`, and a call written inside a `.font(` argument list
    /// is handed to that modifier as a font. `custom` and `pointSize` are names
    /// other types answer to as well, as in `Widget.custom(name:size:)`, so
    /// without that context they stay silent.
    static func fontName(of call: FunctionCallExprSyntax) -> String? {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return nil }
        let name = member.declName.baseName.text
        guard fontCallNames.contains(name) else { return nil }
        // `system` is only a font factory when it names a size, so it is read the
        // same way as the other two.
        guard spelledOnFont(call) || writtenInsideFontModifier(call) else { return nil }
        return name
    }

    /// Whether the chain the call is written on starts at the `Font` type.
    private static func spelledOnFont(_ call: FunctionCallExprSyntax) -> Bool {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return false }
        guard let base = member.base else { return false }
        return Chain.root(of: base).trimmedDescription == "Font"
    }

    /// Whether the call is an argument of a `.font(` modifier, which makes it a
    /// font whatever it is written as.
    private static func writtenInsideFontModifier(_ call: FunctionCallExprSyntax) -> Bool {
        var current = Syntax(call)
        while let parent = current.parent {
            if let outer = parent.as(FunctionCallExprSyntax.self),
               let member = outer.calledExpression.as(MemberAccessExprSyntax.self),
               member.declName.baseName.text == "font" {
                return true
            }
            current = parent
        }
        return false
    }

    /// Whether a size expression is a numeric literal rather than something read
    /// from a property.
    ///
    /// Underscores group digits, as in `1_000`, and a fractional size is written
    /// with a decimal point; anything else is a value whose size the reader's
    /// settings already reach.
    static func isLiteral(_ expression: ExprSyntax) -> Bool {
        let text = expression.trimmedDescription
        guard !text.isEmpty else { return false }
        var seenDot = false
        var digits = 0
        var previousUnderscore = true
        for character in text {
            if character.isNumber {
                digits += 1
                previousUnderscore = false
                continue
            }
            if character == "_" {
                // A literal may not begin or end with a digit group separator.
                guard !previousUnderscore, digits > 0 else { return false }
                previousUnderscore = true
                continue
            }
            if character == ".", !seenDot, !previousUnderscore {
                seenDot = true
                previousUnderscore = false
                continue
            }
            return false
        }
        return digits > 0 && !previousUnderscore
    }
}

/// The font calls of a file.
final class FontVisitor: SyntaxVisitor {
    private(set) var fonts: [FunctionCallExprSyntax] = []

    override init(viewMode: SyntaxTreeViewMode) {
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if FixedFontSizeRule.fontName(of: node) != nil {
            fonts.append(node)
        }
        return .visitChildren
    }
}

extension FunctionCallExprSyntax {
    /// The name of the font call this is, or `nil` when it builds no font.
    var fontName: String? {
        FixedFontSizeRule.fontName(of: self)
    }
}
