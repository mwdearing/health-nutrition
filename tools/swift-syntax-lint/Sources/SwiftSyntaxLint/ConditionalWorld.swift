/// The conditional-compilation blocks of a file, read from `IfConfigDeclSyntax`.
///
/// A block's configuration is one of its arms, so a name written inside only
/// some of them names the view only in some builds. That is the whole reason
/// this rule wants a syntax tree: the tree already says which clause a node was
/// written in, so the check becomes arithmetic over arms rather than a scan of
/// `#if` lines and a guess about nesting.
import SwiftSyntax

/// Collects the conditional-compilation blocks of a file, outermost first.
final class ConditionalBlockVisitor: SyntaxVisitor {
    private(set) var blocks: [IfConfigDeclSyntax] = []

    override init(viewMode: SyntaxTreeViewMode) {
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        blocks.append(node)
        return .visitChildren
    }
}

/// The clauses of every `#if` block in a file, in source order.
struct ConditionalWorld {
    /// One arm of one block: the source range its statements occupy.
    struct Clause {
        let start: AbsolutePosition
        let end: AbsolutePosition
    }

    /// One `#if` block: its arms, and how many configurations it admits.
    struct Block {
        let clauses: [Clause]
        /// A block with an `#else` compiles one arm in every configuration; one
        /// without also has the configuration that compiles none of its arms,
        /// which is what a debug-only name is absent from in a release build.
        let totalConfigurations: Int
    }

    let blocks: [Block]

    /// Beyond this many combinations of arms an exemption cannot be checked
    /// exactly, so the rule keeps its conservative answer instead of guessing.
    static let configurationLimit = 256

    init(tree: SourceFileSyntax) {
        let visitor = ConditionalBlockVisitor(viewMode: .sourceAccurate)
        visitor.walk(tree)
        var found: [Block] = []
        for declaration in visitor.blocks {
            var clauses: [Clause] = []
            var exhaustive = false
            for clause in declaration.clauses {
                if clause.poundElseifOrElse?.text == "#else" {
                    exhaustive = true
                }
                guard let elements = clause.elements else { continue }
                clauses.append(
                    Clause(
                        start: elements.position,
                        end: elements.endPositionBeforeTrailingTrivia
                    )
                )
            }
            guard !clauses.isEmpty else { continue }
            found.append(
                Block(
                    clauses: clauses,
                    totalConfigurations: exhaustive ? clauses.count : clauses.count + 1
                )
            )
        }
        blocks = found
    }

    /// The arm of a block that compiles a position, or `nil` when no arm of that
    /// block contains it, which leaves the position compiled in every
    /// configuration of the block.
    func branch(of position: AbsolutePosition, in block: Block) -> Int? {
        for (index, clause) in block.clauses.enumerated() {
            if position >= clause.start && position < clause.end {
                return index
            }
        }
        return nil
    }

    /// One way of naming a view: where the name is written, and the modifiers
    /// that would hide it again.
    struct Alternative {
        let spoken: [AbsolutePosition]
        let suppressors: [AbsolutePosition]
    }

    /// Whether one of the alternatives names the view in every configuration
    /// that compiles it.
    ///
    /// Alternatives are alternatives to each other: a configuration in which
    /// none of them is compiled leaves the view unnamed, so it still has to be
    /// reported. A block that touches none of the positions involved is left out
    /// entirely, since every configuration of it compiles all of them.
    func holdsInEveryBuild(
        image: AbsolutePosition,
        alternatives: [Alternative]
    ) -> Bool {
        let usable = alternatives.filter { !$0.spoken.isEmpty }
        guard !usable.isEmpty else { return false }
        let positions = usable.flatMap { $0.spoken + $0.suppressors } + [image]
        let relevant = blocks.enumerated().compactMap { index, block in
            block.clauses.contains { clause in
                positions.contains { $0 >= clause.start && $0 < clause.end }
            } ? index : nil
        }
        var total = 1
        for index in relevant {
            total *= blocks[index].totalConfigurations
            if total > ConditionalWorld.configurationLimit { return false }
        }
        var chosen = [Int](repeating: 0, count: relevant.count)
        while true {
            let selection = Dictionary(
                uniqueKeysWithValues: zip(relevant, chosen)
            )
            if compiles(image, in: selection, relevant: relevant),
               usable.contains(where: { speaks($0, in: selection, relevant: relevant) }) {
                return true
            }
            guard advance(&chosen, over: relevant, in: blocks) else { return false }
        }
    }

    /// Step to the next configuration, least significant block first.
    private func advance(
        _ chosen: inout [Int],
        over relevant: [Int],
        in blocks: [Block]
    ) -> Bool {
        var position = 0
        while position < relevant.count {
            let next = chosen[position] + 1
            chosen[position] = 0
            if next < blocks[relevant[position]].totalConfigurations {
                chosen[position] = next
                return true
            }
            position += 1
        }
        return false
    }

    /// Whether a configuration compiles the view at all.
    private func compiles(
        _ image: AbsolutePosition,
        in selection: [Int: Int],
        relevant: [Int]
    ) -> Bool {
        relevant.allSatisfy { index in
            guard let arm = branch(of: image, in: blocks[index]) else { return true }
            return arm == selection[index]
        }
    }

    /// Whether an alternative is spoken in a configuration and not suppressed.
    private func speaks(
        _ alternative: Alternative,
        in selection: [Int: Int],
        relevant: [Int]
    ) -> Bool {
        func compiled(_ position: AbsolutePosition) -> Bool? {
            for index in relevant {
                guard let arm = branch(of: position, in: blocks[index]) else { continue }
                if arm != selection[index] { return false }
            }
            return true
        }
        guard alternative.spoken.allSatisfy({ compiled($0) == true }) else { return false }
        // A modifier that hides the view from VoiceOver stops the name being
        // read, so an alternative suppressed in a configuration does not speak.
        return alternative.suppressors.allSatisfy { compiled($0) == false }
    }
}
