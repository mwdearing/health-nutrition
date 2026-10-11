import SwiftUI
import UIKit

/// Installs a scene-scoped opaque window before UIKit takes an inactive app snapshot.
@MainActor
final class PrivacyShieldController: ObservableObject {
    private weak var scene: UIWindowScene?
    private weak var appWindow: UIWindow?
    private var appliedInitialPhase = false
    private var priorAccessibilityHidden: Bool?
    private(set) var shieldWindow: UIWindow?

    func attach(to appWindow: UIWindow, phase: ScenePhase) {
        guard let scene = appWindow.windowScene else { return }
        self.scene = scene
        self.appWindow = appWindow
        guard !appliedInitialPhase else { return }
        appliedInitialPhase = true
        update(phase: phase)
    }

    func update(phase: ScenePhase) {
        setShielded(phase != .active)
    }

    /// Called on `willResignActive`, before SwiftUI's scene-phase update can lag the snapshot.
    func coverBeforeSnapshot() {
        setShielded(true)
    }

    private func setShielded(_ shielded: Bool) {
        guard shielded else {
            shieldWindow?.isHidden = true
            shieldWindow = nil
            if let priorAccessibilityHidden, let appWindow {
                appWindow.accessibilityElementsHidden = priorAccessibilityHidden
            }
            priorAccessibilityHidden = nil
            return
        }
        guard let scene else { return }

        if let shieldWindow {
            hideAppAccessibility()
            return
        }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.accessibilityViewIsModal = true
        window.rootViewController = PrivacyShieldViewController()
        // Keep the app's key window and any authentication session owned by the system untouched.
        // This scene-local window sits above the app's tab, navigation and presented sheet windows.
        window.isHidden = false
        shieldWindow = window
        hideAppAccessibility()
    }

    private func hideAppAccessibility() {
        guard let appWindow else { return }
        if priorAccessibilityHidden == nil {
            priorAccessibilityHidden = appWindow.accessibilityElementsHidden
        }
        appWindow.accessibilityElementsHidden = true
    }
}

private final class PrivacyShieldViewController: UIViewController {
    override func loadView() {
        let shield = UIView()
        shield.backgroundColor = .black
        shield.isOpaque = true
        shield.isUserInteractionEnabled = true
        shield.accessibilityViewIsModal = true

        let label = UILabel()
        label.text = "Screen hidden"
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .body)
        label.textAlignment = .center
        label.isAccessibilityElement = true
        label.accessibilityTraits = .staticText
        label.translatesAutoresizingMaskIntoConstraints = false
        shield.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: shield.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: shield.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: shield.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: shield.trailingAnchor, constant: -24),
        ])
        view = shield
    }
}

struct PrivacyShieldWindowAttachment: UIViewRepresentable {
    let controller: PrivacyShieldController
    let phase: ScenePhase

    func makeUIView(context: Context) -> PrivacyShieldAnchorView {
        let view = PrivacyShieldAnchorView()
        view.onWindowChange = { [weak controller] window in
            guard let window else { return }
            controller?.attach(to: window, phase: phase)
        }
        return view
    }

    func updateUIView(_ uiView: PrivacyShieldAnchorView, context: Context) {
        uiView.onWindowChange = { [weak controller] window in
            guard let window else { return }
            controller?.attach(to: window, phase: phase)
        }
        if let window = uiView.window {
            controller.attach(to: window, phase: phase)
        }
    }
}

#if DEBUG
/// Isolated synthetic content for the simulator app-switcher privacy test.
struct PrivacyShieldCaptureHost: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = PrivacyShieldController()
    @State private var showingSheet = false
    @State private var sheetTitle = ""

    var body: some View {
        VStack(spacing: 24) {
            Text("Synthetic entry: protein 42g")
                .accessibilityIdentifier("synthetic-entry-marker")
            Button("Show synthetic sheet") {
                sheetTitle = "Synthetic sheet marker"
                showingSheet = true
            }
            Button("Show sign-in and CAPTCHA return fixture") {
                sheetTitle = "Synthetic sign-in and CAPTCHA return marker"
                showingSheet = true
            }
            .accessibilityIdentifier("show-auth-return-fixture")
        }
        .sheet(isPresented: $showingSheet) {
            Text(sheetTitle).accessibilityIdentifier("synthetic-sheet-marker")
                .padding(40)
        }
        .background {
            PrivacyShieldWindowAttachment(controller: controller, phase: scenePhase)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .onChange(of: scenePhase) { _, phase in controller.update(phase: phase) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            controller.coverBeforeSnapshot()
        }
    }
}
#endif

private final class PrivacyShieldAnchorView: UIView {
    var onWindowChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
    }
}
