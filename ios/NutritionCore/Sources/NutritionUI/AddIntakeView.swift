import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders
import SwiftUI
#if os(iOS)
import UIKit
#endif

public struct AddIntakeView: View {
    @ObservedObject var model: AddIntakeViewModel
    @Environment(\.dismiss) private var dismiss
    /// The imported values open by default; the person can fold them away.
    @State private var allValuesOpen = true
    @State private var confirmDiscard = false
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
                    LabeledField(
                        "Name", error: model.visibleNameError, onFocusEnd: { model.fieldDidEnd(.name) },
                    onFocusBegin: { model.fieldDidBegin(.name) }
                    ) { focus in
                        TextField(text: $model.name, prompt: Text("For example, Greek yogurt")) {
                            Text("Name")
                        }
                        .labelsHidden()
                        .font(.body)
                        .focused(focus)
                    }
                    .disabled(model.isCustomProduct)
                    // A typed food has nowhere to keep a brand, so the field shows only for a looked-up or captured
                    // product, whose brand is kept with it.
                    if !model.brand.isEmpty {
                        LabeledField("Brand (optional)") { focus in
                            TextField(text: $model.brand, prompt: Text("For example, a store brand")) {
                                Text("Brand (optional)")
                            }
                            .labelsHidden()
                            .font(.body)
                            .focused(focus)
                            .disabled(model.isCustomProduct)
                        }
                    }
                    Picker("Kind", selection: $model.kind) {
                        ForEach(ProductKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .disabled(model.isCustomProduct)
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Kind of product")
                    .accessibilityHint("Food, drink or supplement. A supplement is left out of the day's food coverage")
                    if model.kind == .drink, model.unit.dimension == .volume {
                        Picker("Drink type", selection: $model.drinkType) {
                            Text("Choose a type").tag(DrinkType?.none)
                            ForEach(DrinkType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(DrinkType?.some(type))
                            }
                        }
                        .pickerStyle(.menu)
                        Stepper(
                            value: Binding(
                                get: { Double(truncating: (model.waterSharePercent ?? IntakeComponent.defaultDrinkHydrationPercent) as NSDecimalNumber) },
                                set: { model.waterSharePercent = Decimal($0) }),
                            in: 0...100, step: 1
                        ) {
                            Text("Water share \(Int(truncating: (model.waterSharePercent ?? IntakeComponent.defaultDrinkHydrationPercent) as NSDecimalNumber))%")
                        }
                        Text("Counts as \(Int(truncating: (model.waterSharePercent ?? IntakeComponent.defaultDrinkHydrationPercent) as NSDecimalNumber))% water")
                            .font(.footnote)
                            .foregroundStyle(TokenColors.textSecondary)
                    }
                    if model.canLookUpBarcode && !model.isCustomProduct {
                        LabeledField("Barcode (optional)") { focus in
                            HStack {
                                TextField(text: $model.barcode, prompt: Text("8, 12 or 13 digits")) {
                                    Text("Barcode (optional)")
                                }
                                .labelsHidden()
                                .font(.body)
                                .digitsOnlyKeyboard()
                                .focused(focus)
                                .accessibilityLabel("Barcode (optional)")
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
                        }
                        if model.lookupState.isLoading {
                            ProgressView().accessibilityLabel("Looking up the barcode")
                        }
                        if let message = model.lookupMessage {
                            InlineNotice(message, tone: .waiting)
                        }
                    }
                    if let onScanLabel, !model.isCustomProduct {
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
                LabeledField(
                    "Amount", error: model.visibleAmountError, onFocusEnd: { model.fieldDidEnd(.amount) },
                    onFocusBegin: { model.fieldDidBegin(.amount) }
                ) { focus in
                    HStack {
                        TextField(text: $model.amountText, prompt: Text("For example, 150")) {
                            Text("Amount")
                        }
                        .labelsHidden()
                        .font(.body)
                        .decimalAmountKeyboard()
                        .focused(focus)
                        .accessibilityLabel("Amount")
                        // The unit is a menu, so the picker shows its own chevron; the word above it names it.
                        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                            Text("Unit")
                                .font(.footnote)
                                .foregroundStyle(TokenColors.textSecondary)
                                .accessibilityHidden(true)
                            Picker("Unit", selection: $model.unit) {
                                ForEach(model.unitOptions, id: \.symbol) { unit in
                                    Text(unit.screenSymbol).tag(unit)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }
                }
                // A typed cup, tablespoon or teaspoon says what it became, and whose typical density gave the
                // grams, with the license line the catalog requires beside them.
                if let note = model.densityNote {
                    Text(note).font(.footnote).foregroundStyle(TokenColors.textSecondary)
                    Text(IngredientDensityCatalog.attribution)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.textSecondary)
                }
                if let note = model.densityUnavailableNote {
                    Text(note).font(.footnote).foregroundStyle(TokenColors.textSecondary)
                }
                if let hint = model.servingHint {
                    Text(hint).font(.footnote).foregroundStyle(TokenColors.textSecondary)
                }
                Picker("Meal", selection: $model.meal) {
                    Text("None").tag(MealLabel?.none)
                    ForEach(MealLabel.allCases, id: \.self) { label in
                        Text(label.displayName).tag(MealLabel?.some(label))
                    }
                }
                DatePicker("When", selection: $model.occurredAt)
            }
            AddServingControls(model: model)

            // A product the catalog lists but states no nutrition facts for is one sentence rather than
            // rows of "unknown". Its attribution still travels with it.
            if model.statesNoNutrients {
                Section {
                    Text(model.noStatedNutrientsSentence)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.textSecondary)
                        .accessibilityLabel(model.noStatedNutrientsSentence)
                    sourceAndLicense
                }
            }
            if model.hasPrefilledValues {
                Section(model.thisAddsTitle) {
                    ForEach(model.thisAdds, id: \.key) { line in
                        LabeledContent(line.displayName, value: line.text)
                    }
                    // Beside the values, not inside the collapsed list: some sources license their data
                    // only if the attribution is shown wherever the values are.
                    sourceAndLicense
                    DisclosureGroup("All values", isExpanded: $allValuesOpen) {
                        ForEach(model.labelValues != nil || model.lookedUp == nil
                            ? Self.capturedKeys : LookedUpProduct.standardKeys, id: \.self) { key in
                            LabeledContent(
                                model.displayName(forCaptured: key),
                                value: Self.text(for: model.prefilledValue(for: key)))
                            .font(.footnote)
                        }
                        if !model.additionalLabelNutrients.isEmpty {
                            Text("Also on the label")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(TokenColors.textPrimary)
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
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Log entry")
        // Typed input is not lost to a Back tap or a swipe: a form with input asks first.
        .navigationBarBackButtonHidden(model.hasTypedInput)
        .blocksEdgeSwipeBack(while: model.blocksSwipeBack)
        .toolbar {
            if model.hasTypedInput {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        confirmDiscard = true
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                }
            }
        }
        .confirmationDialog("Discard this entry?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
        }
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
                if model.canChooseLibrary {
                    Toggle(SaveToLibraryAccessibility.label, isOn: $model.savesToLibrary)
                        .accessibilityHintIfPresent(SaveToLibraryHint.hint(for: SaveToLibraryAccessibility.hint))
                    Text("Also keep this product in Library.")
                        .font(.footnote)
                        .foregroundStyle(TokenColors.textSecondary)
                }
                Text(model.saveScopeMessage)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PrimaryCapsule("Log") {
                    if self.model.save(now: self.now()) { self.onSaved() }
                }
                .accessibilityLabel("Log")
                .accessibilityHint("Adds this entry to the Diary")
            }
            .padding(DesignSpacing.m)
            .background(TokenColors.background)
        }
    }

    /// Where the values came from and, when the source requires it, a titled link to its license.
    @ViewBuilder
    private var sourceAndLicense: some View {
        if let source = model.sourceLine {
            Text(source).font(.footnote).foregroundStyle(TokenColors.textSecondary)
        }
        // A source with no link (the community catalog) still shows its line, so a person can tell the values' origin.
        if let attribution = model.attribution, let attributionTitle = model.attributionTitle {
            if !attribution.url.isEmpty, let url = URL(string: attribution.url) {
                Link(attributionTitle, destination: url)
                    .font(.footnote)
                    .accessibilityLabel("Read the license for these nutrition facts")
            } else {
                Text(attributionTitle).font(.footnote).foregroundStyle(TokenColors.textSecondary)
            }
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

    /// A nutrient the source did not give reads as "Not on the label", never as zero. A figure reads as the
    /// label stated it, unless it is longer than a label prints (`AmountDisplay.stated`).
    static func text(for value: NutrientValue?) -> String {
        switch value {
        case .known(let amount, let unit):
            return AmountDisplay.stated(amount, unit: unit).text
        case .unknown:
            return "Not on the label"
        case .notApplicable:
            return "Does not apply"
        case .belowReportingThreshold(let unit):
            return "Less than the label reports" + (unit.map { " (\($0.screenSymbol))" } ?? "")
        case nil:
            return "Not on the label"
        }
    }
}

/// The keyboard is only set where the platform has one. This package also builds for macOS, where
/// `keyboardType` and the text-input modifiers do not exist, so they stay behind this one door.
extension View {
    @ViewBuilder
    fileprivate func digitsOnlyKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.numberPad).textContentType(nil)
        #else
        self
        #endif
    }

    /// The decimal keypad with its own Done key, for a screen with one amount field.
    @ViewBuilder
    func decimalAmountKeyboard() -> some View {
        #if os(iOS)
        self.decimalKeypadOnly()
            .toolbar { KeyboardDoneToolbar() }
        #else
        self
        #endif
    }

    /// The decimal keypad without a toolbar. A screen with several amount fields (the product editor) must not
    /// attach a keyboard toolbar to each one, because SwiftUI stacks one Done key per field. Such a screen adds
    /// `KeyboardDoneToolbar` once, on the form.
    @ViewBuilder
    func decimalKeypadOnly() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}

/// The single keyboard Done key. Attach it once per screen, never once per field.
public struct KeyboardDoneToolbar: ToolbarContent {
    public init() {}

    public var body: some ToolbarContent {
        #if os(iOS)
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        #endif
    }
}

/// The Save to Library switch's accessibility hint, or nil when it should have none. A nil hint must not reach
/// the element as an empty string, because that is still an applied hint (#644).
public enum SaveToLibraryHint {
    public static func hint(for hint: String?) -> String? {
        guard let hint, !hint.isEmpty else { return nil }
        return hint
    }
}

/// The Save to Library switch's spoken text. The label says what the switch does, so it has no hint: a hint
/// would repeat or contradict the label (#527). Kept here, so a test can pin the hint without a UI tree.
public enum SaveToLibraryAccessibility {
    public static let label = "Save to Library"
    public static let hint: String? = nil
}

extension View {
    /// Applies the hint only when there is one, so a nil hint leaves the element with no hint at all (#644).
    @ViewBuilder
    func accessibilityHintIfPresent(_ hint: String?) -> some View {
        if let hint {
            accessibilityHint(Text(hint))
        } else {
            self
        }
    }
}
