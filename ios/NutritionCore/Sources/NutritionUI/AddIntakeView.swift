import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders
import SwiftUI

public struct AddIntakeView: View {
    @ObservedObject var model: AddIntakeViewModel
    private let now: () -> Date
    private let onSaved: () -> Void
    /// Opens the pushed label scanner while keeping this form's edits.
    private let onScanLabel: (() -> Void)?

    public init(
        model: AddIntakeViewModel, now: @escaping () -> Date = { Date() }, onSaved: @escaping () -> Void,
        onScanLabel: (() -> Void)? = nil
    ) {
        self.model = model
        self.now = now
        self.onSaved = onSaved
        self.onScanLabel = onScanLabel
    }

    public var body: some View {
        Form {
            Card {
                VStack(alignment: .leading, spacing: DesignSpacing.m) {
                    TextField("Name", text: $model.name)
                        .font(.body)
                    if !model.brand.isEmpty {
                        TextField("Brand", text: $model.brand)
                            .font(.body)
                            .accessibilityLabel("Brand")
                    }
                    if let message = model.nameError {
                        Text(message).font(.footnote).foregroundStyle(TokenColors.error)
                    }
                    Picker("Kind", selection: $model.kind) {
                        ForEach(ProductKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Kind of product")
                    .accessibilityHint("Food, drink or supplement. A supplement is left out of the day's food coverage")
                    if model.canLookUpBarcode {
                        HStack {
                            TextField("Barcode", text: $model.barcode)
                                .font(.body)
                                .digitsOnlyKeyboard()
                                .accessibilityLabel("Barcode")
                                .accessibilityHint("Type the 8, 12 or 13 digits on the package, then look up")
                                .onSubmit { Task { await self.model.lookUpBarcode() } }
                            Button("Look up") {
                                Task { await self.model.lookUpBarcode() }
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.lookupState.isLoading)
                            .accessibilityLabel("Look up barcode")
                            .accessibilityHint("Fills in the name, brand and nutrients for this barcode")
                        }
                        if model.lookupState.isLoading {
                            ProgressView().accessibilityLabel("Looking up the barcode")
                        }
                        if let message = model.lookupMessage {
                            InlineNotice(message, tone: .waiting)
                        }
                    }
                    if let onScanLabel {
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
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(TokenColors.background)

            Section {
                HStack {
                    TextField("Amount", text: $model.amountText)
                        .font(.body)
                        .decimalAmountKeyboard()
                    Picker("Unit", selection: $model.unit) {
                        ForEach(model.units, id: \.symbol) { unit in
                            Text(unit.symbol).tag(unit)
                        }
                    }
                }
                if let message = model.amountError {
                    Text(message).font(.footnote).foregroundStyle(TokenColors.error)
                }
                if let hint = model.servingHint {
                    Text(hint).font(.footnote).foregroundStyle(TokenColors.textSecondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DesignSpacing.s) { servingChips }
                        VStack(alignment: .leading, spacing: DesignSpacing.s) { servingChips }
                    }
                }
                Picker("Meal", selection: $model.meal) {
                    Text("None").tag(MealLabel?.none)
                    ForEach(MealLabel.allCases, id: \.self) { label in
                        Text(label.displayName).tag(MealLabel?.some(label))
                    }
                }
                DatePicker("When", selection: $model.occurredAt)
            }

            // A product the catalog lists but states no nutrition facts for is one sentence rather than
            // rows of "unknown". Its attribution still travels with it.
            if model.statesNoNutrients {
                Section {
                    Text(AddIntakeViewModel.noStatedNutrientsMessage)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.textSecondary)
                        .accessibilityLabel(AddIntakeViewModel.noStatedNutrientsMessage)
                    sourceAndLicence
                }
            }
            if model.hasPrefilledValues {
                Section("This adds") {
                    ForEach(model.thisAdds, id: \.key) { line in
                        LabeledContent(line.displayName, value: line.text)
                    }
                    // Beside the values, not inside the collapsed list: some sources licence their data
                    // only if the attribution is shown wherever the values are.
                    sourceAndLicence
                    DisclosureGroup("All values") {
                        ForEach(model.labelValues != nil || model.lookedUp == nil
                            ? Self.capturedKeys : LookedUpProduct.standardKeys, id: \.self) { key in
                            LabeledContent(
                                model.displayName(forCaptured: key),
                                value: Self.text(for: model.prefilledValue(for: key)))
                            .font(.footnote)
                        }
                        if !model.additionalLabelNutrients.isEmpty {
                            Text("Also on the label")
                                .font(.footnote)
                                .foregroundStyle(TokenColors.textSecondary)
                                .accessibilityLabel("Also on the label")
                            ForEach(model.additionalLabelNutrients, id: \.self) { key in
                                LabeledContent(
                                    model.displayName(forAdditional: key),
                                    value: Self.text(for: model.prefilledNutrients[key]))
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
            }
            HStack {
                Text("Log to several days")
                Spacer()
                LaterBadge()
            }
            .disabled(true)
            .accessibilityElement(children: .combine)
            .accessibilityValue("Not available yet")
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Add")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: DesignSpacing.s) {
                if let message = model.saveError {
                    InlineNotice(message, tone: .failed)
                }
                if let message = model.saveBlockedMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.error)
                        .accessibilityLabel("Cannot save: \(message)")
                }
                PrimaryCapsule("Save") {
                    if self.model.save(now: self.now()) { self.onSaved() }
                }
                .accessibilityLabel("Save")
                .accessibilityHint("Checks the amount and adds the entry to the journal")
            }
            .padding(DesignSpacing.m)
            .background(TokenColors.background)
        }
    }

    private var servingChips: some View {
        ForEach(["1 serving", "½", "2"], id: \.self) { title in
            HStack(spacing: DesignSpacing.s) {
                Text(title).font(.body)
                LaterBadge()
            }
            .padding(DesignSpacing.s)
            .background(TokenColors.surface, in: Capsule())
            .disabled(true)
            .accessibilityElement(children: .combine)
            .accessibilityValue("Not available yet")
        }
    }

    /// Where the values came from and, when the source requires it, a titled link to its licence.
    @ViewBuilder
    private var sourceAndLicence: some View {
        if let source = model.sourceLine {
            Text(source).font(.footnote).foregroundStyle(TokenColors.textSecondary)
        }
        if let attribution = model.attribution,
            let attributionTitle = model.attributionTitle, let url = URL(string: attribution.url) {
            Link(attributionTitle, destination: url)
                .font(.footnote)
                .accessibilityLabel("Read the licence for these nutrition facts")
        }
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

    @ViewBuilder
    func decimalAmountKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}
