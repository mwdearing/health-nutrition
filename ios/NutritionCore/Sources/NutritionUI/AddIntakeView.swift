import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders
import SwiftUI

public struct AddIntakeView: View {
    @ObservedObject var model: AddIntakeViewModel
    private let now: () -> Date
    private let onSaved: () -> Void
    private let onFromLibrary: (() -> Void)?
    /// Opens the camera scanner. The app target injects this, so this package stays free of any
    /// camera framework; nil hides the button and the field is typed instead.
    private let onScanBarcode: (() -> Void)?
    /// Opens the label capture sheet, which reads a Nutrition Facts panel the user checks before
    /// anything is filled in. Injected the same way, and nil hides the entry.
    private let onScanLabel: (() -> Void)?

    public init(
        model: AddIntakeViewModel, now: @escaping () -> Date = { Date() }, onSaved: @escaping () -> Void,
        onFromLibrary: (() -> Void)? = nil, onScanBarcode: (() -> Void)? = nil,
        onScanLabel: (() -> Void)? = nil
    ) {
        self.model = model
        self.now = now
        self.onSaved = onSaved
        self.onFromLibrary = onFromLibrary
        self.onScanBarcode = onScanBarcode
        self.onScanLabel = onScanLabel
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
            // Label capture sits next to the barcode scanner because it is the other way to get values
            // into this form. It asks the camera for text rather than for a code, and nothing is filled
            // in until the user has checked what was read, so it does not wait for a lookup to be
            // available: a package with no barcode is exactly what it is for.
            if let onScanLabel {
                Section("Label") {
                    Button {
                        onScanLabel()
                    } label: {
                        Label("Scan label", systemImage: "text.viewfinder").font(.body)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Scan label")
                    .accessibilityHint(
                        "Points the camera at the Nutrition Facts panel, then shows you what was read before filling anything in")
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
                Picker("Meal", selection: $model.meal) {
                    // None is a real answer, not an absent one: an entry can be logged without saying
                    // which meal it was, and the form starts there rather than on a default.
                    Text("None").tag(MealLabel?.none)
                    ForEach(MealLabel.allCases, id: \.self) { label in
                        Text(label.displayName).tag(MealLabel?.some(label))
                    }
                }
                // What kind of thing this is. Food unless the panel or the source said otherwise, which
                // is what the form starts on: a supplement left out of the day's food count, and a drink
                // counted in it, are only distinguishable from the entry itself.
                Picker("Kind", selection: $model.kind) {
                    ForEach(ProductKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Kind of product")
                .accessibilityHint("Food, drink or supplement. A supplement is left out of the day's food coverage")
                DatePicker("When", selection: $model.occurredAt)
            }
            if model.canLookUpBarcode, let basis = model.lookupBasis {
                Section("From the barcode (\(basis.label))") {
                    if let serving = model.serving {
                        LabeledContent("One serving", value: serving.label)
                            .font(.footnote)
                    }
                    // A product the catalog lists but states no nutrition facts for is one sentence
                    // rather than nine rows of "unknown", which reads as a failed lookup rather than as a
                    // product with nothing stated on it. The attribution below it still travels with it.
                    if model.statesNoNutrients {
                        Text(AddIntakeViewModel.noStatedNutrientsMessage)
                            .font(.footnote)
                            .foregroundStyle(TokenColors.textSecondary)
                            .accessibilityLabel(AddIntakeViewModel.noStatedNutrientsMessage)
                    } else {
                        ForEach(LookedUpProduct.standardKeys, id: \.self) { key in
                            LabeledContent(
                                LookedUpProduct.displayNames[key] ?? key,
                                value: Self.text(for: model.prefilledNutrients[key])
                            )
                            .font(.footnote)
                        }
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
            if let captured = model.labelValues {
                // The values the user checked on the review screen, on the basis the panel states. A
                // nutrient the panel did not state is shown as unknown, never as zero.
                Section("From the label (\(captured.labelBasis))") {
                    if let serving = model.serving {
                        LabeledContent("One serving", value: serving.label)
                            .font(.footnote)
                    }
                    ForEach(Self.capturedKeys, id: \.self) { key in
                        LabeledContent(
                            model.displayName(forCaptured: key),
                            value: Self.text(for: model.prefilledNutrients[key])
                        )
                        .font(.footnote)
                    }
                    // The compounds the panel states under its own names, which the fifteen journal
                    // nutrients do not. They are shown apart from that list but with the same values,
                    // so a scanned supplement's own rows are visible on the form rather than dropped.
                    if !model.additionalLabelNutrients.isEmpty {
                        Text("Also on the label")
                            .font(.footnote)
                            .foregroundStyle(TokenColors.textSecondary)
                            .accessibilityLabel("Also on the label")
                        ForEach(model.additionalLabelNutrients, id: \.self) { key in
                            LabeledContent(
                                model.displayName(forAdditional: key),
                                value: Self.text(for: model.prefilledNutrients[key])
                            )
                            .font(.footnote)
                        }
                    }
                    if let message = model.labelMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(TokenColors.textSecondary)
                            .accessibilityLabel(message)
                    }
                }
            }
            if let message = model.saveError {
                Text(message).font(.footnote).foregroundStyle(TokenColors.error)
            }
            // Beside the button rather than only at the field it names: on a long form the field is far
            // above, and a Save that refused an empty amount would otherwise look like a button that
            // did nothing at all.
            if let message = model.saveBlockedMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.error)
                    .accessibilityLabel("Cannot save: \(message)")
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

    /// The rows a captured panel is shown under, in panel order. Every row the parser knows is listed,
    /// so a nutrient the panel did not state reads as "unknown" on the form instead of going missing.
    static var capturedKeys: [String] {
        NutritionFactKey.allCases.map(\.rawValue)
    }

    /// The name a captured panel row is shown under. The keys the parser uses are the journal's own,
    /// so a reader who has seen one screen sees the same names on the other.
    static func displayName(forCaptured key: String) -> String {
        guard let fact = NutritionFactKey(rawValue: key) else { return key }
        return LabelCaptureRow.displayNames[fact] ?? LookedUpProduct.displayNames[key] ?? key
    }

    /// The name a compound row is shown under, spelled out from its slug: `creatine-monohydrate` reads
    /// as `Creatine Monohydrate`. A captured snapshot carries the key, not the printed words, so the
    /// words are restored from it rather than the row going unnamed.
    static func displayName(forAdditional key: String) -> String {
        key.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
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
