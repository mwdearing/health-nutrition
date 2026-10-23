import SwiftUI

#if canImport(UIKit)
import UIKit

/// Turns the edge swipe-back off while a pushed form holds typed input. Hiding the Back button does not
/// stop the edge gesture, so the gesture is switched off on the navigation controller that hosts the form,
/// and the form's own Back or Cancel asks instead. It is switched back on when the form goes away.
struct PopGestureGate: UIViewControllerRepresentable {
    let blocked: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        apply(to: controller)
        // The controller may not be in the navigation stack yet on the first update, so apply again once it is.
        DispatchQueue.main.async { apply(to: controller) }
    }

    private func apply(to controller: UIViewController) {
        controller.navigationController?.interactivePopGestureRecognizer?.isEnabled = !blocked
        let nav = controller.navigationController
        print("PopGateProbe apply blocked=\(blocked) nav=\(nav != nil) enabledAfter=\(String(describing: nav?.interactivePopGestureRecognizer?.isEnabled))")
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: ()) {
        controller.navigationController?.interactivePopGestureRecognizer?.isEnabled = true
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
