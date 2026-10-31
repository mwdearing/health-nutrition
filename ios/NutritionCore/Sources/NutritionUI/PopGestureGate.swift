import SwiftUI

#if canImport(UIKit)
import UIKit

/// Turns the edge swipe-back off while a pushed form holds typed input. Hiding the Back button does not
/// stop the edge gesture, so the gesture is switched off on the navigation controller that hosts the form,
/// and the form's own Back or Cancel asks instead.
///
/// The gate is a plain view inside the form. When it enters a window it walks its responder chain to the
/// view controller that owns it and switches that controller's stack. When it leaves the window, because the
/// form was popped or another screen was pushed over it, it switches the gesture back on, so the screen on top
/// can still be swiped away; coming back on screen applies the form's state again.
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
        nav.interactivePopGestureRecognizer?.isEnabled = !blocked
    }

    func release() {
        gatedStack?.interactivePopGestureRecognizer?.isEnabled = true
        gatedStack = nil
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
