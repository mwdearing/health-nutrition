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
        controller.navigationController?.interactivePopGestureRecognizer?.isEnabled = !blocked
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
