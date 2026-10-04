import Foundation
import NutritionDomain
import SwiftUI

public struct AddIntakeView: View {
    @ObservedObject var model: AddIntakeViewModel
    private let now: () -> Date
    private let onSaved: () -> Void
    private let onFromLibrary: (() -> Void)?
    /// Opens the camera scanner. The app target injects this, so this package stays free of any
    /// camera framework; nil hides the button and the field is typed instead.
    private let onScanBarcode: (() -> Void)?

    public init(
        model: AddIntakeViewModel, now: @escaping () -> Date = { Date() }, onSaved: @escaping () -> Void,
        onFromLibrary: (() -> Void)? = nil, onScanBarcode: (() -> Void)? = nil
    ) {
        self.model = model
        self.now = now
        self.onSaved = onSaved
        self.onFromLibrary = onFromLibrary
        self.onScanBarcode = onScanBarcode
    }

    public var body: some View {
        Form {
            if let onFromLibrary {
                Button {
                    onFromLibrary()
                } label: {
                    Text("From library").font(.headline)
                }
                .accessibilityLabel("Add from library")
                .accessibilityHint("Shows favorites and recent items")
            }
            if model.canLookUpBarcode {
                Section("Barcode") {
                    HStack {
                        TextField("Barcode", text: $model.barcode)
                            .font(.body)
                            .digitsOnlyKeyboard()
                            .accessibilityLabel("Barcode")
                            .accessibilityHint("Type the 8, 12 or 13 digits on the package, then look up")
                            .onSubmit { Task { await model.lookUpBarcode() } }
                        if let onScanBarcode {
                            // Scanning only fills the field. The lookup still waits for Look up,
                            // so nothing is requested while the camera is open.
                            Button {
                                onScanBarcode()
                            } label: {
                                Image(systemName: "barcode.viewfinder")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Scan barcode")
                            .accessibilityHint("Points the camera at the barcode on the package and fills in the field")
                        }
                        Button("Look up") {
                            Task { await model.lookUpBarcode() }
                        }
                        // Two buttons in one form row are both row actions under the automatic style,
                        // and tapping either can then fire both. Their hit areas have to stay apart,
                        // otherwise looking up would open the camera, and scanning would send a
                        // request the form promises not to send.
                        .buttonStyle(.borderless)
                        .disabled(model.lookupState.isLoading)
                        .accessibilityLabel("Look up barcode")
                        .accessibilityHint("Fills in the name, brand and nutrients for this barcode")
                    }
                    if model.lookupState.isLoading {
                        ProgressView().accessibilityLabel("Looking up the barcode")
                    }
                    if let message = model.lookupMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(TokenColors.textSecondary)
                            .accessibilityLabel(message)
                    }
                }
            }
            Section("Food or drink") {
                TextField("Name", text: $model.name)
                    .font(.body)
                if model.canLookUpBarcode, !model.brand.isEmpty {
                    TextField("Brand", text: $model.brand)
                        .font(.body)
                        .accessibilityLabel("Brand")
                }
                if let message = model.nameError {
                    Text(message).font(.footnote).foregroundStyle(TokenColors.error)
                }
                TextField("Amount", text: $model.amountText)
                    .font(.body)
                if let message = model.amountError {
                    Text(message).font(.footnote).foregroundStyle(TokenColors.error)
                }
                Picker("Unit", selection: $model.unit) {
                    ForEach(model.units, id: \.symbol) { unit in
                        Text(unit.symbol).tag(unit)
                    }
                }
                DatePicker("When", selection: $model.occurredAt)
            }
            if model.canLookUpBarcode, let basis = model.lookupBasis {
                Section("From the barcode (\(basis.label))") {
                    if let serving = model.serving {
                        LabeledContent("One serving", value: serving.label)
                            .font(.footnote)
                    }
                    ForEach(LookedUpProduct.standardKeys, id: \.self) { key in
                        LabeledContent(
                            LookedUpProduct.displayNames[key] ?? key,
                            value: Self.text(for: model.prefilledNutrients[key])
                        )
                        .font(.footnote)
                    }
                    // Shown next to every value above: some sources licence their data only if the
                    // attribution travels with it. Both the wording and the link come from the
                    // source, so the UI never has to know which source it is.
                    if let attribution = model.attribution {
                        Text(attribution.text)
                            .font(.footnote)
                            .foregroundStyle(TokenColors.textSecondary)
                        if let url = URL(string: attribution.url) {
                            Link(attribution.url, destination: url)
                                .font(.footnote)
                                .accessibilityLabel("Read the licence for these nutrition facts")
                        }
                    }
                }
            }
            if let message = model.saveError {
                Text(message).font(.footnote).foregroundStyle(TokenColors.error)
            }
            Button {
                if model.save(now: now()) { onSaved() }
            } label: {
                Text("Save").font(.headline)
            }
            .accessibilityLabel("Save intake")
            .accessibilityHint("Checks the amount and adds the entry to the journal")
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Add intake")
    }

    /// A nutrient the source did not give reads as unknown, never as zero.
    static func text(for value: NutrientValue?) -> String {
        switch value {
        case .known(let amount, let unit):
            return "\(amount) \(unit.symbol)"
        case .unknown:
            return "unknown"
        case .notApplicable:
            return "not applicable"
        case .belowReportingThreshold:
            return "below reporting threshold"
        case nil:
            return "unknown"
        }
    }
}

/// The keyboard is only set where the platform has one. This package also builds for macOS, where
/// `keyboardType` and the text-input modifiers do not exist, so they stay behind this one door.
private extension View {
    @ViewBuilder
    func digitsOnlyKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.numberPad).textContentType(nil)
        #else
        self
        #endif
    }
}
