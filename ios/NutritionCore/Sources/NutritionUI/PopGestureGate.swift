import SwiftUI

#if canImport(UIKit)
import UIKit

/// Turns the edge swipe-back off while the screen on top of a navigation stack holds typed input. Hiding the Back
/// button does not stop the edge gesture, so the gesture is switched off on the navigation controller that hosts the
/// form, and the form's own Back or Cancel asks instead.
///
/// The gesture belongs to the navigation controller, not to a form, so it is decided from the whole stack: it is off
/// exactly when a blocked gate sits under the screen now on top. A form covered by another screen does not decide it
/// (the covering screen can be swiped away), and a form that is uncovered again decides it once more, so popping a
/// blocked form over another blocked form keeps the gesture off.
@MainActor
enum PopGateRegistry {
    private final class Box {
        weak var gate: PopGateController?
        init(_ gate: PopGateController) { self.gate = gate }
    }

    private static var gates: [ObjectIdentifier: [Box]] = [:]
    /// UIKit switches the recognizer back on itself as the stack changes, so a change made by anyone else is read
    /// against the stack again.
    private static var observers: [ObjectIdentifier: NSKeyValueObservation] = [:]

    static func add(_ gate: PopGateController, to nav: UINavigationController) {
        let key = ObjectIdentifier(nav)
        var boxes = (gates[key] ?? []).filter { $0.gate != nil }
        if !boxes.contains(where: { $0.gate === gate }) { boxes.append(Box(gate)) }
        gates[key] = boxes
        if observers[key] == nil, let recognizer = nav.interactivePopGestureRecognizer {
            observers[key] = recognizer.observe(\.isEnabled, options: [.new]) { [weak nav] _, _ in
                DispatchQueue.main.async { if let nav { PopGateRegistry.evaluate(nav) } }
            }
        }
    }

    static func remove(_ gate: PopGateController, from nav: UINavigationController) {
        let key = ObjectIdentifier(nav)
        gates[key] = (gates[key] ?? []).filter { $0.gate != nil && $0.gate !== gate }
        if gates[key]?.isEmpty == true {
            gates[key] = nil
            observers[key] = nil
        }
    }

    /// Sets the stack's edge pop from the screen on top: off when a blocked gate belongs to it, on otherwise.
    static func evaluate(_ nav: UINavigationController) {
        // Switching the recognizer off during a pan cancels the swipe, so a stack in transition (an interactive pop in
        // progress included) is read again once the transition has finished, or been cancelled.
        // Only an animated transition is waited for: a transition that is not animated never calls the completion.
        if let coordinator = nav.transitionCoordinator, coordinator.isAnimated,
           coordinator.animate(alongsideTransition: nil, completion: { [weak nav] _ in
               if let nav { evaluate(nav) }
           }) {
            return
        }
        let top = nav.topViewController
        let blocked = (gates[ObjectIdentifier(nav)] ?? []).contains { box in
            guard let gate = box.gate, gate.blocked, let top else { return false }
            return gate.belongs(to: top)
        }
        nav.interactivePopGestureRecognizer?.isEnabled = !blocked
    }
}

final class PopGateController: UIViewController {
    var blocked = false
    private weak var registeredNav: UINavigationController?

    /// Whether this gate is part of `screen`: a child of its view controller, or in its view.
    func belongs(to screen: UIViewController) -> Bool {
        var current: UIViewController? = self
        while let controller = current {
            if controller === screen { return true }
            current = controller.parent
        }
        return isViewLoaded && view.isDescendant(of: screen.view)
    }

    func sync(blocked: Bool) {
        self.blocked = blocked
        attachAndEvaluate()
    }

    private func attachAndEvaluate() {
        guard let nav = navigationController else { return }
        if registeredNav !== nav {
            registeredNav = nav
            PopGateRegistry.add(self, to: nav)
        }
        PopGateRegistry.evaluate(nav)
    }

    func detach() {
        guard let nav = registeredNav else { return }
        registeredNav = nil
        PopGateRegistry.remove(self, from: nav)
        PopGateRegistry.evaluate(nav)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attachAndEvaluate()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // The screen now on top is read once the stack has moved on.
        DispatchQueue.main.async { [weak self] in self?.registeredNav.map(PopGateRegistry.evaluate) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        registeredNav.map(PopGateRegistry.evaluate)
    }
}

struct PopGestureGate: UIViewControllerRepresentable {
    let blocked: Bool

    func makeUIViewController(context: Context) -> PopGateController {
        PopGateController()
    }

    func updateUIViewController(_ controller: PopGateController, context: Context) {
        controller.sync(blocked: blocked)
        // The controller may not be in the navigation stack yet on the first update, so apply again once it is.
        DispatchQueue.main.async { [weak controller] in controller?.sync(blocked: blocked) }
    }

    static func dismantleUIViewController(_ controller: PopGateController, coordinator: ()) {
        controller.detach()
    }
}

extension View {
    /// Blocks the edge swipe-back while `blocked` is true.
    func blocksEdgeSwipeBack(while blocked: Bool) -> some View {
        background(PopGestureGate(blocked: blocked).frame(width: 0, height: 0))
    }
}
#else
extension View {
    func blocksEdgeSwipeBack(while blocked: Bool) -> some View { self }
}
#endif
