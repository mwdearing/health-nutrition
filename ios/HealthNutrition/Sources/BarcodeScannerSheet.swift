import Foundation
import NutritionUI
import SwiftUI

// The camera lives in the app target, never in the UI package: this file owns VisionKit, and the
// form only gets the digits the scanner read. Everything is behind this one door because the rest
// of the package has to keep building where VisionKit does not exist.
#if os(iOS)
import UIKit
import Vision
import VisionKit

/// Whether this device can scan barcodes with the camera right now. `isSupported` is a build-time
/// answer, `isAvailable` the runtime one: a device may support the scanner and still have it
/// unavailable (no camera, or the camera in use by something else). Both have to hold, otherwise
/// Add intake shows no Scan button at all and the barcode is typed.
enum BarcodeScanner {
    // Both properties are main-actor isolated, so this is too. It is read from the form's Scan
    // action, which runs on the main actor like the rest of the view.
    @MainActor
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }
}

/// The scanner sheet: the live camera, a way out, and nothing else.
///
/// Scanning never looks anything up. The first payload the UI package accepts as a barcode fills
/// the field and closes the sheet; the request to the source still waits for the user to tap Look
/// up (see `docs/providers/open-food-facts.md`). Once the camera becomes unavailable the sheet
/// says so once, with a Close button, and never asks again.
struct BarcodeScannerSheet: View {
    let onScanned: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var failureMessage: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scan barcode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(failureMessage == nil ? "Cancel" : "Close") { dismiss() }
                    }
                }
        }
    }

    /// The camera while it works, the notice once it cannot. A terminal failure takes the scanner
    /// out of the tree altogether, so nothing asks it to start again.
    @ViewBuilder
    private var content: some View {
        if let failureMessage {
            failureNotice(failureMessage)
        } else {
            BarcodeDataScanner(onScan: accept, onFailure: fail)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) { hint }
        }
    }

    private var hint: some View {
        Text("Hold the barcode inside the frame. The field is filled in; nothing is looked up until you tap Look up.")
            .font(.footnote)
            .multilineTextAlignment(.center)
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

    private func accept(_ barcode: String) {
        onScanned(barcode)
        dismiss()
    }

    private func fail(_ message: String) {
        failureMessage = message
    }
}

/// VisionKit's scanner, wrapped for SwiftUI. Only EAN and UPC symbologies are recognized, because
/// those are the codes the intake form looks up; anything else the camera reads is ignored.
struct BarcodeDataScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
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
        var parent: BarcodeDataScanner
        /// Scanning is started once and never restarted: restarting it while it runs throws.
        private var isRunning = false
        /// Set the moment a barcode is handed over, so the same code read again frame after frame
        /// cannot fill the field twice or reopen the sheet.
        private var hasDelivered = false
        /// Set when scanning became unavailable for good, and never cleared. Reporting a failure
        /// changes the sheet's state, which sends SwiftUI back through `updateUIViewController`, so
        /// without this the availability guard would report the same failure on every update and
        /// keep the main queue busy for as long as the notice is on screen. A terminal failure is
        /// asked for once and never retried.
        private var hasFailed = false

        init(parent: BarcodeDataScanner) {
            self.parent = parent
        }

        // Main actor, because it reads the scanner's main-actor isolated availability and starts
        // the controller. SwiftUI calls this from its update pass, which is on the main actor.
        @MainActor
        func startScanning(on controller: DataScannerViewController) {
            guard !isRunning, !hasDelivered, !hasFailed else { return }
            guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
                report("This device cannot scan barcodes. Type the digits instead.")
                return
            }
            do {
                try controller.startScanning()
                isRunning = true
            } catch {
                report("The camera could not be started. Type the digits instead.")
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !hasDelivered else { return }
            for item in addedItems {
                guard case let .barcode(barcode) = item else { continue }
                guard let payload = barcode.payloadStringValue else { continue }
                // A UPC-E payload is compressed: its eight digits would pass the EAN-8 check while
                // standing for a different number, so it is expanded to its GTIN-12 first. Every
                // other symbology is used as printed.
                let expanded = barcode.observationBarcode.symbology == .upce
                    ? ScannedBarcode.expandUPCE(payload) : nil
                if let expanded {
                    deliver(expanded, from: dataScanner)
                    return
                }
                // The same rule the field applies to typed digits: a code of another length, or one
                // with a wrong check digit, is skipped and scanning goes on. A UPC-E payload that did
                // not expand is skipped for the same reason: looking up its eight printed digits
                // would ask about a GTIN-8 that was never on the package.
                guard barcode.observationBarcode.symbology != .upce,
                      let accepted = ScannedBarcode.normalize(payload)
                else { continue }
                deliver(accepted, from: dataScanner)
                return
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            guard !hasDelivered else { return }
            report("Scanning stopped, so the barcode was not read. Type the digits instead.")
        }

        /// Hands the barcode over once and stops the camera. Set before the callback, so the same
        /// code read again in a later frame is ignored rather than delivered twice.
        private func deliver(_ barcode: String, from dataScanner: DataScannerViewController) {
            hasDelivered = true
            isRunning = false
            dataScanner.stopScanning()
            parent.onScan(barcode)
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
