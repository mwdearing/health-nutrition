import SwiftUI

#if canImport(UIKit)
import UIKit

/// Turns the edge swipe-back off while a pushed form holds typed input. Hiding the Back button does not
/// stop the edge gesture, so the gesture is switched off on the navigation controller that hosts the form,
/// and the form's own Back or Cancel asks instead. It is switched back on when the form goes away.
/// Holds the gate's state and applies it when it is in a navigation stack: on appearing, and on every change.
/// Applying from a lifecycle callback rather than from the SwiftUI update means the recognizer is reached once the
/// controller is actually in the hierarchy, not on an update that may run before it is.
final class PopGateController: UIViewController {
    var blocked = false {
        didSet { apply() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        apply()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }

    func apply() {
        navigationController?.interactivePopGestureRecognizer?.isEnabled = !blocked
    }
}

struct PopGestureGate: UIViewControllerRepresentable {
    let blocked: Bool

    func makeUIViewController(context: Context) -> PopGateController {
        let controller = PopGateController()
        controller.blocked = blocked
        return controller
    }

    func updateUIViewController(_ controller: PopGateController, context: Context) {
        controller.blocked = blocked
    }

    static func dismantleUIViewController(_ controller: PopGateController, coordinator: ()) {
        controller.blocked = false
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
