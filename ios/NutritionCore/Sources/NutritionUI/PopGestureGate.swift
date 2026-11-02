import SwiftUI

#if canImport(UIKit)
import UIKit

/// Turns the edge swipe-back off while a pushed form holds typed input. Hiding the Back button does not
/// stop the edge gesture, so the gesture is switched off on the navigation controller that hosts the form,
/// and the form's own Back or Cancel asks instead.
///
/// The gate is a plain view inside the form. Whenever it enters a window, leaves one, or lays out, it sets the
/// edge swipe from the state of the stack's top screen: off while a blocked gate sits in that screen's view tree,
/// on otherwise. So a form covered by another blocked form cannot re-enable the gesture over its input, and a
/// clean screen on top stays swipeable.
final class PopGateView: UIView {
    var blocked = false {
        didSet { if blocked != oldValue { apply() } }
    }

    private weak var gatedStack: UINavigationController?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            release()
        } else {
            apply()
        }
    }

    /// SwiftUI can attach this view before its hosting controller has joined the stack. Each layout pass
    /// re-applies, so the gate finds its navigation controller as soon as the responder chain is complete.
    override func layoutSubviews() {
        super.layoutSubviews()
        if window != nil { apply() }
    }

    /// The navigation controller of the nearest view controller that owns this view, if any.
    var owningNavigationController: UINavigationController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController, let nav = controller.navigationController { return nav }
            responder = current.next
        }
        return nil
    }

    func apply() {
        guard window != nil, let nav = owningNavigationController else { return }
        gatedStack = nav
        Self.refresh(nav, excluding: nil)
    }

    func release() {
        guard let nav = gatedStack else { return }
        gatedStack = nil
        Self.refresh(nav, excluding: self)
    }

    /// Sets the edge swipe from the top screen. `excluding` is the gate being released, which can still be in the
    /// tree while it leaves the window.
    private static func refresh(_ nav: UINavigationController, excluding released: PopGateView?) {
        let top = nav.topViewController?.viewIfLoaded
        let blockedOnTop = top.map { containsBlockedGate($0, excluding: released) } ?? false
        nav.interactivePopGestureRecognizer?.isEnabled = !blockedOnTop
    }

    private static func containsBlockedGate(_ view: UIView, excluding released: PopGateView?) -> Bool {
        if let gate = view as? PopGateView, gate !== released, gate.blocked { return true }
        return view.subviews.contains { containsBlockedGate($0, excluding: released) }
    }
}

struct PopGestureGate: UIViewRepresentable {
    let blocked: Bool

    func makeUIView(context: Context) -> PopGateView {
        let view = PopGateView()
        view.isUserInteractionEnabled = false
        view.blocked = blocked
        return view
    }

    func updateUIView(_ view: PopGateView, context: Context) {
        view.blocked = blocked
    }

    static func dismantleUIView(_ view: PopGateView, coordinator: ()) {
        view.release()
    }
}

extension View {
    /// Blocks the edge swipe-back while `blocked` is true.
    func blocksEdgeSwipeBack(while blocked: Bool) -> some View {
        background(PopGestureGate(blocked: blocked).frame(width: 1, height: 1).allowsHitTesting(false))
    }
}
#else
extension View {
    func blocksEdgeSwipeBack(while blocked: Bool) -> some View { self }
}
#endif
