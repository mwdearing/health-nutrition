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
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }
}

/// The scanner sheet: the live camera, a way out, and nothing else.
///
/// Scanning never looks anything up. The first payload the UI package accepts as a barcode fills
/// the field and closes the sheet; the request to the source still waits for the user to tap Look
/// up (see `docs/providers/open-food-facts.md`).
struct BarcodeScannerSheet: View {
    let onScanned: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var failureMessage: String?

    var body: some View {
        NavigationStack {
            BarcodeDataScanner(onScan: accept, onFailure: fail)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    if let failureMessage {
                        failureNotice(failureMessage)
                    } else {
                        hint
                    }
                }
                .navigationTitle("Scan barcode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
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
        VStack(spacing: 8) {
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .font(.headline)
        }
        .padding()
        .frame(maxWidth: .infinity)
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

        init(parent: BarcodeDataScanner) {
            self.parent = parent
        }

        func startScanning(on controller: DataScannerViewController) {
            guard !isRunning, !hasDelivered else { return }
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
                // The same rule the field applies to typed digits: a code of another length, or one
                // with a wrong check digit, is skipped and scanning goes on.
                guard let accepted = ScannedBarcode.normalize(payload) else { continue }
                hasDelivered = true
                isRunning = false
                dataScanner.stopScanning()
                parent.onScan(accepted)
                return
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.Error
        ) {
            guard !hasDelivered else { return }
            report("Scanning stopped, so the barcode was not read. Type the digits instead.")
        }

        /// Told to SwiftUI outside the update pass that is running when scanning is started, so a
        /// failure never changes view state while SwiftUI is laying the view out.
        private func report(_ message: String) {
            isRunning = false
            let parent = parent
            DispatchQueue.main.async { parent.onFailure(message) }
        }
    }
}
#endif
