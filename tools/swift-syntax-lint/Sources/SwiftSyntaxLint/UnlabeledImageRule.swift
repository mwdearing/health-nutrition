/// `unlabeled-image`: every image VoiceOver meets has to be named.
///
/// The rule and its exemptions are the Python script's, read from its docstring.
/// What differs is how an exemption is found: a syntax tree already says which
/// closure an image sits in, which call that closure labels, and which `#if` arm
/// wrote it, so none of that has to be recovered by scanning brackets.
import SwiftSyntax

enum UnlabeledImageRule {
    /// The controls whose label closure names whatever sits inside it.
    static let controlNames: Set<String> = [
        "Button", "Menu", "Toggle", "Label", "Link", "NavigationLink", "Picker",
        "Stepper", "Slider", "DisclosureGroup", "ControlGroup", "EditButton",
    ]

    /// Controls whose unlabelled trailing closure holds content rather than a
    /// label: the actions of a `Menu`, the options of a `Picker`, the views of a
    /// `ControlGroup`. A name on such a control names the control, not the items
    /// inside it, so an image among them is named in its own right.
    static let contentControls: Set<String> = ["Menu", "Picker", "ControlGroup"]

    /// The finding lines of one file, with `lint-allow` exemptions applied.
    static func findingLines(_ context: FileContext) -> [Int] {
        let world = ConditionalWorld(tree: context.tree)
        let visitor = ImageVisitor(viewMode: .sourceAccurate)
        visitor.walk(context.tree)
        var lines: [Int] = []
        for image in visitor.images where isUnnamed(image, world: world) {
            let line = context.line(of: image)
            if context.allows.allows(Rules.unlabeledImage.name, onLine: line) { continue }
            lines.append(line)
        }
        return lines.sorted()
    }

    /// Whether an image has to be named in its own right.
    static func isUnnamed(_ image: FunctionCallExprSyntax, world: ConditionalWorld) -> Bool {
        // `Image(decorative:)` declares its own emptiness, so it needs no name.
        if image.arguments.contains(where: { $0.label?.text == "decorative" }) {
            return false
        }
        let position = image.positionAfterSkippingLeadingTrivia
        let own = Chain.modifiersFollowingConditionals(above: image)
        // The image names itself, or declares itself decorative, in every build
        // that compiles it.
        if world.holdsInEveryBuild(
            image: position,
            alternatives: alternatives(named: own, by: "accessibilityLabel")
        ) {
            return false
        }
        if world.holdsInEveryBuild(
            image: position,
            alternatives: alternatives(named: own, by: "accessibilityHidden", hidden: true)
        ) {
            return false
        }
        // Failing that, the control whose label the image sits in may name it, as
        // may the text of that label or, for a `Label`, its title.
        guard let window = LabelWindow(image: image) else { return true }
        return !window.names(image, world: world)
    }

    /// One alternative per modifier of that name: a name written in some arms of
    /// an `#if` only speaks in those builds, and the configuration arithmetic in
    /// `ConditionalWorld` decides whether that is enough.
    private static func alternatives(
        named modifiers: [AppliedModifier],
        by name: String,
        hidden: Bool = false
    ) -> [ConditionalWorld.Alternative] {
        modifiers
            .filter { $0.name == name && (!hidden || $0.hidesFromAccessibility) }
            .map {
                ConditionalWorld.Alternative(
                    spoken: [$0.node.positionAfterSkippingLeadingTrivia],
                    suppressors: []
                )
            }
    }

    /// The control whose label closure an image sits in.
    ///
    /// The climb outwards passes through the layouts the image may be wrapped in,
    /// which name nothing themselves, and stops at the first control whose label
    /// closure holds it. A plain view at the top of the climb leaves the image to
    /// be named in its own right.
    struct LabelWindow {
        /// The call that owns the label closure, and the control's name.
        let call: FunctionCallExprSyntax
        let name: String
        /// The closure holding the image, which is the control's label.
        let label: ClosureExprSyntax
        /// For a `Label`, the title closure as well: a `Label` speaks its title,
        /// so that title names the icon next to it.
        let title: ClosureExprSyntax?

        init?(image: FunctionCallExprSyntax) {
            var current = Syntax(image)
            while let parent = current.parent {
                current = parent
                guard let closure = parent.as(ClosureExprSyntax.self) else { continue }
                guard let owner = LabelWindow.owner(of: closure) else { continue }
                let name = Chain.writtenName(of: owner.call.calledExpression) ?? ""
                guard UnlabeledImageRule.controlNames.contains(name) else {
                    // A layout is not something a VoiceOver user operates, so it
                    // names nothing; the control it sits in still may.
                    continue
                }
                if UnlabeledImageRule.contentControls.contains(name),
                   owner.label == nil,
                   !LabelWindow.passesContent(owner.call) {
                    // The closure holds the actions or options of the control
                    // rather than its label, so the climb goes on outwards.
                    continue
                }
                self.call = owner.call
                self.name = name
                self.label = closure
                self.title = name == "Label" ? LabelWindow.titleClosure(of: owner.call) : nil
                return
            }
            return nil
        }

        /// Whether the control itself, or the text of its label, names the image.
        func names(_ image: FunctionCallExprSyntax, world: ConditionalWorld) -> Bool {
            let position = image.positionAfterSkippingLeadingTrivia
            let control = Chain.modifiersFollowingConditionals(above: call)
            if world.holdsInEveryBuild(
                image: position,
                alternatives: UnlabeledImageRule.alternatives(named: control, by: "accessibilityLabel")
            ) {
                return true
            }
            if world.holdsInEveryBuild(
                image: position,
                alternatives: UnlabeledImageRule.alternatives(
                    named: control,
                    by: "accessibilityHidden",
                    hidden: true
                )
            ) {
                return true
            }
            // Text in the same control label names the control; text in an
            // enclosing layout names something else entirely.
            for closure in [label, title].compactMap({ $0 }) {
                if world.holdsInEveryBuild(
                    image: position,
                    alternatives: LabelWindow.textAlternatives(in: closure)
                ) {
                    return true
                }
            }
            return false
        }

        /// The ways the text inside a label closure names its control.
        ///
        /// Text hidden from the accessibility tree reads nothing aloud, so it does
        /// not name the control in the builds that compile the hiding; a text
        /// hidden in one arm alone still names it in the others.
        static func textAlternatives(in closure: ClosureExprSyntax) -> [ConditionalWorld.Alternative] {
            let visitor = TextVisitor(viewMode: .sourceAccurate)
            visitor.walk(closure)
            return visitor.texts.map { text in
                let hidden = Chain.modifiersFollowingConditionals(above: text)
                    .filter { $0.name == "accessibilityHidden" && $0.hidesFromAccessibility }
                    .map { $0.node.positionAfterSkippingLeadingTrivia }
                return ConditionalWorld.Alternative(
                    spoken: [text.positionAfterSkippingLeadingTrivia],
                    suppressors: hidden
                )
            }
        }

        /// The call a closure is written as part of, and the argument label it
        /// carries, which is `nil` for an unlabelled trailing closure.
        static func owner(
            of closure: ClosureExprSyntax
        ) -> (call: FunctionCallExprSyntax, label: String?)? {
            if let call = closure.parent?.as(FunctionCallExprSyntax.self),
               call.trailingClosure?.id == closure.id {
                return (call, nil)
            }
            if let element = closure.parent?.as(MultipleTrailingClosureElementSyntax.self),
               let list = element.parent?.as(MultipleTrailingClosureElementListSyntax.self),
               let call = list.parent?.as(FunctionCallExprSyntax.self) {
                return (call, element.label?.text)
            }
            if let argument = closure.parent?.as(LabeledExprSyntax.self),
               let list = argument.parent?.as(LabeledExprListSyntax.self),
               let call = list.parent?.as(FunctionCallExprSyntax.self) {
                return (call, argument.label?.text)
            }
            return nil
        }

        /// Whether the control's content has already been passed as an argument,
        /// which leaves the trailing closure that follows it free to be the label.
        static func passesContent(_ call: FunctionCallExprSyntax) -> Bool {
            call.arguments.contains { $0.label?.text == "content" }
        }

        /// The title closure of a `Label`, whether it is written as a trailing
        /// closure or passed as the `title:` argument.
        static func titleClosure(of call: FunctionCallExprSyntax) -> ClosureExprSyntax? {
            if let argument = call.arguments.first(where: { $0.label?.text == "title" }),
               let closure = argument.expression.as(ClosureExprSyntax.self) {
                return closure
            }
            if let element = call.additionalTrailingClosures?.first,
               element.label?.text == "title",
               let closure = element.closure.as(ClosureExprSyntax.self) {
                return closure
            }
            // `Label { ... } icon: { ... }` puts the title in the first trailing
            // closure, which carries no label of its own.
            return call.trailingClosure
        }
    }
}

/// Collects the `Text(...)` calls of a subtree.
final class TextVisitor: SyntaxVisitor {
    private(set) var texts: [FunctionCallExprSyntax] = []

    override init(viewMode: SourceSelectionMode) {
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if Chain.writtenName(of: node.calledExpression) == "Text" {
            texts.append(node)
        }
        return .visitChildren
    }
}

/// Collects the `Image(...)` calls of a file.
final class ImageVisitor: SyntaxVisitor {
    private(set) var images: [FunctionCallExprSyntax] = []

    override init(viewMode: SourceSelectionMode) {
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if Chain.writtenName(of: node.calledExpression) == "Image" {
            images.append(node)
        }
        return .visitChildren
    }
}
