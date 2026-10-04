import Foundation
import NutritionJournal
import NutritionUI
import SwiftUI

// The camera lives in the app target, never in the UI package: this file owns VisionKit, and the
// review screen only ever gets the text lines the scanner read. Everything is behind this one door
// because the rest of the package has to keep building where VisionKit does not exist.
#if os(iOS)
import UIKit
import Vision
import VisionKit

/// Whether this device can read a Nutrition Facts panel with the camera right now. `isSupported` is
/// a build-time answer, `isAvailable` the runtime one: a device may support the scanner and still
/// have it unavailable (no camera, or the camera in use by something else). Both have to hold,
/// otherwise Add intake shows no Scan label entry at all and the values are typed instead.
enum LabelTextScanner {
    // Both properties are main-actor isolated, so this is too. It is read from the form's Scan label
    // action, which runs on the main actor like the rest of the view.
    @MainActor
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }
}

/// Holds the lines the camera can see right now, so the Capture button can ask for them.
///
/// Only text is kept, never an image: each frame's recognized items replace the previous frame's, so
/// what is held is the transcript of the panel as it is on screen at that moment. Nothing is stored
/// and nothing is sent anywhere; recognition runs on the device and the lines go to the parser.
///
/// The type is not actor-isolated, for the same reason the barcode scanner's coordinator is not: the
/// scanner's delegate callbacks and the Capture button both arrive on the main thread, and marking
/// the delegate methods for an actor would not be something this SDK's protocol asks for.
final class LabelCaptureSession: ObservableObject {
    private let model: LabelCaptureViewModel
    /// The controller as it was last handed over, so capturing can stop the camera.
    private weak var controller: DataScannerViewController?
    private var lines: [String] = []

    init(model: LabelCaptureViewModel) {
        self.model = model
    }

    func attach(_ controller: DataScannerViewController) {
        self.controller = controller
    }

    /// Replaces the held lines with the ones the scanner recognizes now. Called for every change to the
    /// recognized set — an item added, changed or taken away — so what is held is the frame in front of
    /// the camera and not the last frame that had anything on it.
    func update(with items: [RecognizedItem]) {
        lines = LabelCaptureSession.linesInReadingOrder(items)
    }

    /// Hands the lines to the parser and stops the camera, so the review screen is not competing with
    /// a live preview. An empty capture is still handed over: the parser then says the panel was
    /// unreadable, which is a clearer answer than a Capture button that does nothing.
    ///
    /// Main actor, because it loads the parser's rows into the view model, and because it is only ever
    /// reached from the Capture button.
    @MainActor
    func capture() {
        let collected = lines
        lines = []
        controller?.stopScanning()
        model.load(lines: collected)
    }

    /// The recognized items as lines of text in the order a person reads them: top to bottom, and
    /// left to right within one line of print.
    ///
    /// A Nutrition Facts panel is two columns, so a capture reads a left-hand row and a right-hand
    /// row of the same printed line as two fragments. Putting them in one line per row of print is
    /// what lets the parser see "Total Fat 7g 9%" the way it was printed, rather than as two
    /// disconnected halves. Rows are found by comparing the middle of each box: Vision's origin is the
    /// bottom-left corner, so a larger `midY` is higher on the panel.
    static func linesInReadingOrder(_ items: [RecognizedItem]) -> [String] {
        let boxes: [(text: String, midY: CGFloat, midX: CGFloat)] = items.compactMap { item in
            guard case let .text(text) = item else { return nil }
            let box = text.observation.boundingBox
            let transcript = text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { return nil }
            return (transcript, box.midY, box.midX)
        }
        var bands: [(midY: CGFloat, pieces: [(text: String, midX: CGFloat)])] = []
        for box in boxes.sorted(by: { $0.midY > $1.midY }) {
            if let last = bands.last, abs(last.midY - box.midY) < bandHeight {
                bands[bands.count - 1].pieces.append((box.text, box.midX))
            } else {
                bands.append((midY: box.midY, pieces: [(box.text, box.midX)]))
            }
        }
        return bands
            .map { $0.pieces.sorted { $0.midX < $1.midX }.map(\.text).joined(separator: " ") }
            .filter { !$0.isEmpty }
    }

    /// How close two boxes have to be to count as the same line of print, as a fraction of the frame's
    /// height. A printed row is about this tall, so two boxes inside it are one line.
    private static let bandHeight: CGFloat = 0.02
}

/// The capture sheet: the live camera with a Capture button, and the review screen once there is
/// something to review.
///
/// Nothing is filled into the intake form before the user has seen every value the parser was unsure
/// about, and no image is kept: the scanner reads text, the review screen hands over the values the
/// user checked, and each frame's items replace the last frame's as they arrive.
struct LabelCaptureSheet: View {
    /// Observed, so the Capture button takes the sheet from the camera to the review screen as soon as
    /// the parser has read something, and a retake takes it back again.
    @ObservedObject var model: LabelCaptureViewModel
    /// Called with the reviewed product, and only once the review screen says the values can be used.
    let onUse: (ProductDefinition) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: LabelCaptureSession
    @State private var failureMessage: String?

    init(model: LabelCaptureViewModel, onUse: @escaping (ProductDefinition) -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.onUse = onUse
        _session = StateObject(wrappedValue: LabelCaptureSession(model: model))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.hasPanel ? "Check the label" : "Scan the label")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }

    /// The camera while it reads, the review screen once the Capture button has handed it the lines. A
    /// terminal failure takes the camera out of the tree, so nothing asks it to start again.
    @ViewBuilder
    private var content: some View {
        if let failureMessage {
            failureNotice(failureMessage)
        } else if model.hasPanel {
            LabelCaptureView(
                model: model,
                onUse: { product in
                    onUse(product)
                    dismiss()
                },
                onRetake: {}
            )
        } else {
            camera
        }
    }

    private var camera: some View {
        LabelCaptureDataScanner(session: session, onFailure: { failureMessage = $0 })
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) { captureBar }
    }

    /// The Capture button. It collects the lines the camera has read so far, in reading order, and
    /// hands them to the parser; nothing is parsed and nothing is saved while the camera is open.
    private var captureBar: some View {
        VStack(spacing: 8) {
            Text("Hold the Nutrition Facts panel inside the frame, then tap Capture. Nothing is saved until you have checked what was read.")
                .font(.footnote)
                .multilineTextAlignment(.center)
            Button {
                session.capture()
            } label: {
                Text("Capture").font(.headline)
            }
            .accessibilityLabel("Capture the panel")
            .accessibilityHint("Reads the text of the panel in front of the camera and shows it for checking")
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
    }

    private func failureNotice(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .font(.headline)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial)
    }
}

/// VisionKit's scanner, wrapped for SwiftUI and pointed at text rather than at barcodes.
struct LabelCaptureDataScanner: UIViewControllerRepresentable {
    let session: LabelCaptureSession
    /// Called when the camera cannot keep scanning, so the sheet can say so once and stop.
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .balanced,
            // A Nutrition Facts panel is printed as many separate items — a heading, fifteen rows, a
            // footnote — so the scanner is asked to identify all of them. Asking for one at a time caps
            // `allItems` at whatever the scanner felt like return, and most captures would then parse as
            // incomplete or unreadable.
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.startScanning(on: controller)
    }

    // Main actor for the same reason as `startScanning(on:)`: it touches the controller.
    @MainActor
    static func dismantleUIViewController(
        _ controller: DataScannerViewController, coordinator: Coordinator
    ) {
        controller.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var parent: LabelCaptureDataScanner
        /// Scanning is started once and never restarted: restarting it while it runs throws.
        private var isRunning = false
        /// Set when scanning became unavailable for good, and never cleared. Reporting a failure
        /// changes the sheet's state, which sends SwiftUI back through `updateUIViewController`, so
        /// without this the availability guard would report the same failure on every update and keep
        /// the main queue busy for as long as the notice is on screen.
        private var hasFailed = false

        init(parent: LabelCaptureDataScanner) {
            self.parent = parent
        }

        // Main actor, because it reads the scanner's main-actor isolated availability and starts the
        // controller. SwiftUI calls this from its update pass, which is on the main actor.
        @MainActor
        func startScanning(on controller: DataScannerViewController) {
            parent.session.attach(controller)
            guard !isRunning, !hasFailed else { return }
            guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
                report("This device cannot read text with the camera. Type the values in instead.")
                return
            }
            do {
                try controller.startScanning()
                isRunning = true
            } catch {
                report("The camera could not be started. Type the values in instead.")
            }
        }

        /// All three of VisionKit's item callbacks feed the same place: each one carries the collection
        /// the scanner currently recognizes, so the held lines are replaced from every one of them.
        ///
        /// Reacting only to additions would leave the previous panel's text in place after that panel
        /// left the frame, and tapping Capture with the camera pointing at something else would then
        /// submit lines that are no longer on screen. An update says a recognized item changed, and a
        /// removal says one went away; either can change what the frame says, so both are answered.
        func dataScanner(
            _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            refresh(with: allItems)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            refresh(with: allItems)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            refresh(with: allItems)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            report("The camera stopped, so the panel was not read. Try again in a moment.")
        }

        /// Replaces the held lines with what the scanner recognizes now, so Capture submits the frame
        /// in front of the camera rather than the last frame that had anything on it. An empty
        /// collection clears them, which is what makes a capture of a blank frame come back unreadable
        /// instead of quietly reusing the previous panel.
        ///
        /// The callback arrives on the main thread, like the Capture button that reads these lines.
        private func refresh(with items: [RecognizedItem]) {
            guard isRunning, !hasFailed else { return }
            parent.session.update(with: items)
        }

        /// Told to SwiftUI outside the update pass that is running when scanning is started, so a
        /// failure never changes view state while SwiftUI is laying the view out.
        private func report(_ message: String) {
            isRunning = false
            hasFailed = true
            let parent = parent
            DispatchQueue.main.async { parent.onFailure(message) }
        }
    }
}
#endif
