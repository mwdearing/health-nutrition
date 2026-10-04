/// Walking a member-access chain, and the `#if` blocks that continue one.
///
/// The Python lint recovers this structure by scanning brackets and `#if` lines.
/// A syntax tree hands it over instead: a modifier is a node whose base is the
/// expression it modifies, and a conditional arm is a clause of an
/// `IfConfigDeclSyntax`. The traversal below is what uses it.
import SwiftSyntax

/// One modifier applied to an expression by a member-access chain.
struct AppliedModifier {
    /// The modifier itself: the call, or the bare member access.
    let node: Syntax
    /// The name it is written with, as in `accessibilityLabel`.
    let name: String
    /// Whether its argument is the literal `true`.
    let hidesFromAccessibility: Bool
}

enum Chain {
    /// The modifiers applied to `expression` by the chain it is the base of,
    /// innermost first, and the outermost node of that chain.
    static func modifiers(above expression: some SyntaxProtocol) -> ([AppliedModifier], Syntax) {
        var found: [AppliedModifier] = []
        var current = Syntax(expression)
        while let step = step(from: current) {
            found.append(step.modifier)
            current = step.node
        }
        return (found, current)
    }

    /// The modifiers applied to `expression`, following the `#if` blocks written
    /// directly after the expression they continue.
    ///
    /// Only the arms that hold modifiers count, as in the Python rule: an arm
    /// holding a sibling view ends the chain rather than extending it, and an arm
    /// that begins with another `#if` is descended into, since its nested arms say
    /// what the expression is modified by in that configuration. The result is the
    /// union over arms, because which arm is compiled is settled afterwards by
    /// `ConditionalWorld` rather than here.
    static func modifiersFollowingConditionals(
        above expression: some SyntaxProtocol
    ) -> [AppliedModifier] {
        var found: [AppliedModifier] = []
        var current = Syntax(expression)
        // The chain continues once: a modifier written after the closing `#endif`
        // is a difference from the Python rule, and is listed in the README.
        if let block = conditionalBlock(after: current) {
            found += continuations(through: block)
        }
        let (own, _) = modifiers(above: expression)
        return own + found
    }

    /// One step of a chain: the modifier applied to `node`, and the node that
    /// takes its place.
    private static func step(from node: Syntax) -> (modifier: AppliedModifier, node: Syntax)? {
        guard let parent = node.parent else { return nil }
        // A modifier written as a call is one step, member access and argument
        // list together, so the call is recognised before the bare member access.
        if let call = parent.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.base?.id == node.id {
            return (
                AppliedModifier(
                    node: Syntax(call),
                    name: member.declName.baseName.text,
                    hidesFromAccessibility: passesTrue(call)
                ),
                Syntax(call)
            )
        }
        if let member = parent.as(MemberAccessExprSyntax.self), member.base?.id == node.id {
            return (
                AppliedModifier(
                    node: Syntax(member),
                    name: member.declName.baseName.text,
                    hidesFromAccessibility: false
                ),
                Syntax(member)
            )
        }
        return nil
    }

    /// Whether a call is written with the single argument `true`, which is what
    /// `accessibilityHidden(true)` needs and `accessibilityHidden(false)` is not.
    static func passesTrue(_ call: FunctionCallExprSyntax) -> Bool {
        guard call.arguments.count == 1, let argument = call.arguments.first else { return false }
        return argument.expression.as(BooleanLiteralExprSyntax.self)?.literal.text == "true"
    }

    // MARK: - Conditional continuation

    /// The `#if` block written directly after `node` in the same statement list.
    static func conditionalBlock(after node: Syntax) -> IfConfigDeclSyntax? {
        var current = node
        while let parent = current.parent {
            if let list = parent.as(CodeBlockItemListSyntax.self) {
                guard let index = list.index(where: { $0.id == current.id }) else { return nil }
                let next = list.index(after: index)
                guard next < list.endIndex else { return nil }
                return list[next].item.as(IfConfigDeclSyntax.self)
            }
            current = parent
        }
        return nil
    }

    /// The modifiers that continue a chain through `block`, over every arm.
    static func continuations(through block: IfConfigDeclSyntax) -> [AppliedModifier] {
        var found: [AppliedModifier] = []
        for chain in chains(through: block) {
            found += chain
        }
        return found
    }

    /// One chain per combination of arms, so that each combination is a complete
    /// reading of what the expression is modified by.
    static func chains(through block: IfConfigDeclSyntax) -> [[AppliedModifier]] {
        var combinations: [[AppliedModifier]] = [[]]
        for clause in block.clauses {
            combinations = combine(combinations, chains(in: items(of: clause)))
        }
        return combinations
    }

    /// The statements of one arm, which is where a modifier continuing the chain
    /// is written.
    static func items(of clause: IfConfigClauseSyntax) -> [CodeBlockItemSyntax] {
        guard let list = clause.elements?.as(CodeBlockItemListSyntax.self) else { return [] }
        return Array(list)
    }

    /// The chain the statements of an arm offer: a leading run of modifiers
    /// extends it, a nested `#if` is descended into, and anything else ends it.
    static func chains(in items: [CodeBlockItemSyntax]) -> [[AppliedModifier]] {
        guard let first = items.first else { return [[]] }
        let rest = Array(items.dropFirst())
        if let nested = first.item.as(IfConfigDeclSyntax.self) {
            return combine(chains(through: nested), chains(in: rest))
        }
        guard let expression = first.item.as(ExprSyntax.self),
              let leading = postfixChain(of: expression)
        else {
            // A sibling view ends the chain rather than extending it.
            return [[]]
        }
        return combine([[leading]], chains(in: rest))
    }

    /// Every combination of pairs of chains.
    private static func combine(
        _ left: [[AppliedModifier]],
        _ right: [[AppliedModifier]]
    ) -> [[AppliedModifier]] {
        left.flatMap { one in right.map { one + $0 } }
    }

    /// The modifiers of an expression written with no base of its own, which is
    /// how a member access continuing the previous expression is spelled. An
    /// expression that does have a base was already followed by `modifiers`.
    static func postfixChain(of expression: ExprSyntax) -> [AppliedModifier]? {
        guard let member = root(of: expression).as(MemberAccessExprSyntax.self),
              member.base == nil
        else {
            return nil
        }
        let (found, _) = modifiers(above: member)
        return found
    }

    /// The expression at the bottom of a chain of calls and member accesses.
    static func root(of expression: ExprSyntax) -> ExprSyntax {
        var current = expression
        while true {
            if let call = current.as(FunctionCallExprSyntax.self) {
                current = call.calledExpression
            } else if let member = current.as(MemberAccessExprSyntax.self), let base = member.base {
                current = base
            } else {
                return current
            }
        }
    }

    // MARK: - Names

    /// The dotted name an expression is written with, so `SwiftUI.Button` and
    /// `Button` can be told from `Custom.Button`, which names a type of its own.
    static func writtenName(of expression: ExprSyntax) -> String? {
        if let declaration = expression.as(DeclReferenceExprSyntax.self) {
            return declaration.baseName.text
        }
        guard let member = expression.as(MemberAccessExprSyntax.self) else { return nil }
        let last = member.declName.baseName.text
        guard let base = member.base else { return last }
        if let module = base.as(DeclReferenceExprSyntax.self)?.baseName.text,
           module == "SwiftUI" {
            return last
        }
        guard let qualifier = writtenName(of: base) else { return last }
        return "\(qualifier).\(last)"
    }
}
