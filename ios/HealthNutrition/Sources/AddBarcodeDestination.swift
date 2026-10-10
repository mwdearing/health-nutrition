import NutritionUI
import SwiftUI

/// Keeps the camera and lookup in one pushed destination, not another presentation.
struct AddBarcodeDestination: View {
    @ObservedObject var model: AddIntakeViewModel
    let onScanned: (String) async -> Void
    let onFound: () -> Void
    let onLabel: () -> Void
    let onType: () -> Void
    @State private var hasScanned = false
    @State private var scannedCode: String?
    @State private var awaitingResult = false

    var body: some View {
        Group {
            if !hasScanned {
                BarcodeScannerSheet(onScanned: { barcode in
                    self.hasScanned = true
                    self.scannedCode = barcode
                }, onType: onType)
            } else if model.lookupState.isLoading || model.lookupState == .idle {
                VStack(spacing: DesignSpacing.m) {
                    ProgressView("Looking up the product")
                    Button("Cancel") {
                        self.awaitingResult = false
                        self.model.setScannedBarcode("")
                        self.onType()
                    }
                }
            } else if model.lookupState == .notFound || model.statesNoNutrients {
                VStack {
                    EmptyState(title: "No product found for that barcode",
                        message: model.statesNoNutrients ? model.noStatedNutrientsSentence
                            : "Scan the nutrition label or enter the details yourself.",
                        systemImage: "barcode", actionTitle: "Scan the label instead", action: onLabel)
                    QuietCapsule("Type it in", action: onType).padding(DesignSpacing.m)
                }
            } else if let message = model.lookupMessage {
                VStack(spacing: DesignSpacing.m) {
                    InlineNotice(message, tone: .waiting)
                    Button("Try again") {
                        self.awaitingResult = true
                        Task { await self.model.lookUpBarcode() }
                    }
                    QuietCapsule("Type it in", action: onType)
                }
                .padding(DesignSpacing.m)
            }
        }
        .background(TokenColors.background)
        .navigationTitle("Scan barcode")
        .task(id: hasScanned) {
            guard self.hasScanned, self.model.lookupState == .idle, let code = self.scannedCode else { return }
            self.awaitingResult = true
            await self.onScanned(code)
        }
        .onChange(of: model.lookupState) { _, state in
            // Any finished lookup ends the wait, so a later lookup made from the details form is not
            // taken for this screen's own.
            guard self.awaitingResult, !state.isLoading, state != .idle else { return }
            self.awaitingResult = false
            if case .found = state, !self.model.statesNoNutrients { self.onFound() }
        }
    }
}
