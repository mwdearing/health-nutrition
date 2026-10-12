import Foundation
import SwiftUI
import NutritionDomain
import NutritionJournal
import NutritionProviders

public struct CustomProductEditorView: View {
    @ObservedObject private var model: CustomProductEditorViewModel
    private let sharing: CustomProductSharingModel?
    private let onSaved: (CustomProductRevision, Bool) -> Void
    @State private var openDetails = false
    public init(model: CustomProductEditorViewModel, sharing: CustomProductSharingModel? = nil, onSaved: @escaping (CustomProductRevision, Bool) -> Void) {
        self.model = model; self.sharing = sharing; self.onSaved = onSaved
    }
    public var body: some View {
        Form {
            Section("Product") {
                LabeledField("Name") { focus in
                    TextField("Name", text: $model.name).focused(focus)
                }
                LabeledField("Brand (optional)") { focus in
                    TextField("Brand (optional)", text: $model.brand).focused(focus)
                }
                LabeledField("Barcode (optional)") { focus in
                    TextField("Barcode (optional)", text: $model.barcode).focused(focus)
                }
                Picker("Kind", selection: $model.kind) {
                    Text("Choose kind").tag(ProductKind?.none)
                    ForEach(ProductKind.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
                if let source = model.revision?.source { Text("Imported from \(source.attribution). This is your local copy.").font(.footnote) }
            }
            Section("Product serving and facts basis") {
                Picker("Facts are stated", selection: $model.basis) {
                    Text("Choose basis").tag(ProductBasis?.none)
                    Text("Per 100 g").tag(Optional(ProductBasis.per100g))
                    Text("Per 100 mL").tag(Optional(ProductBasis.per100mL))
                    Text("Per serving").tag(Optional(ProductBasis.perServing))
                }
                LabeledField("Product serving quantity (optional)") { focus in
                    TextField("Product serving quantity (optional)", text: $model.servingQuantity).decimalAmountKeyboard().focused(focus)
                }
                Picker("Product serving unit", selection: $model.servingUnit) {
                    ForEach(CustomProductEditorViewModel.servingUnits, id: \.self) { Text($0.symbol).tag($0) }
                }
                LabeledField("Serving description (optional)") { focus in
                    TextField("Serving description (optional)", text: $model.servingText).focused(focus)
                }
                    .disabled(model.legacyServingText != nil)
                Text("Use the serving printed on the product. The amount you consume is entered separately.").font(.footnote)
            }
            Section("Facts") {
                if model.missingFacts { Text("Missing facts. You can save a name-only product.").foregroundStyle(TokenColors.textSecondary) }
                ForEach($model.facts) { $fact in
                    VStack(alignment: .leading) {
                        LabeledField("Fact key") { focus in
                            TextField("Fact key", text: $fact.key).focused(focus)
                        }
                        LabeledField("Display name") { focus in
                            TextField("Display name", text: $fact.displayName).focused(focus)
                        }
                        Picker("Fact state", selection: $fact.state) {
                            Text("Known amount").tag(ProductFactState.known)
                            Text("Unknown").tag(ProductFactState.unknown)
                            Text("Not applicable").tag(ProductFactState.notApplicable)
                            Text("Below reporting threshold").tag(ProductFactState.belowReportingThreshold)
                        }
                        if fact.state == .known {
                            LabeledField("Amount") { focus in
                                TextField("Amount", text: $fact.amount).decimalAmountKeyboard().focused(focus)
                            }
                        }
                        if fact.state == .known || fact.state == .belowReportingThreshold {
                            Picker("Fact unit", selection: $fact.unit) {
                                Text("No unit stated").tag(MeasureUnit?.none)
                                ForEach(CustomProductEditorViewModel.units, id: \.self) { Text($0.symbol).tag(Optional($0)) }
                            }
                        }
                        Button("Remove fact", role: .destructive) { model.facts.removeAll { $0.id == fact.id } }
                    }
                    .accessibilityElement(children: .contain)
                }
                Button("Add fact") { model.facts.append(ProductFactInput()) }.disabled(model.facts.count >= 64)
                Text("Standard keys include protein, sodium and energyKcal. For another compound use ingredient: followed by its name. IU stays IU.").font(.footnote)
            }
            Section {
                Toggle("Open intake details after saving", isOn: $openDetails)
                Button("Save product on this phone") {
                    do { let saved = try model.save(now: Date()); onSaved(saved, openDetails) } catch { }
                }
                .accessibilityHint("Saves a product without logging an intake or sharing it")
                if let message = model.errorMessage { Text(message).foregroundStyle(TokenColors.error) }
            }
            if let item = model.revision, let sharing { CustomProductSharingSection(item: item, model: sharing) }
        }
        .navigationTitle("Product editor")
    }
}

/// Status remains based on the durable operation/receipt. Actions stay separately accessible.
public struct CustomProductSharingSection: View {
    public let item: CustomProductRevision
    @ObservedObject var model: CustomProductSharingModel
    @State private var actionError: String?
    @State private var confirmRemoval = false
    public init(item: CustomProductRevision, model: CustomProductSharingModel) { self.item = item; self.model = model }
    public var body: some View {
        Section("Sharing") {
            Text(model.status(item).rawValue).accessibilityIdentifier("productDeliveryStatus")
            Text(model.detail(item)).font(.footnote)
            if model.canRetry(item) { Button("Retry") { Task { await model.retry(item) } } }
            Button("Review product to share") { Task { await model.review(item) } }.disabled((!model.canShare && !model.canWithdraw(item)) || model.busy)
            if !model.canShare { Text(model.eligibilityText).font(.footnote) }
            if model.canWithdraw(item) { Button("Remove my contribution", role: .destructive) { confirmRemoval = true } }
            if let message = model.errorMessage ?? actionError { Text(message).foregroundStyle(TokenColors.error) }
        }
        .task { await model.observeStatus() }
        .onDisappear { model.cancelReview() }
        .confirmationDialog("Remove your contribution? Other people's contributions can remain searchable.", isPresented: $confirmRemoval) {
            Button("Remove my contribution", role: .destructive) { perform { try model.withdraw(item) } }
        }
        .sheet(item: Binding(get: { model.preview?.revision.localProductID == item.localProductID ? model.preview : nil }, set: { if $0 == nil { model.cancelReview() } })) { preview in
            NavigationStack {
                List {
                    Section("Only these product facts will be shared") {
                        Text(preview.revision.content.name)
                        if let brand = preview.revision.content.brand { Text(brand) }
                        Text(preview.revision.content.kind.displayName)
                        Text(preview.revision.content.basis.rawValue)
                        if let serving = preview.revision.content.serving {
                            Text("Serving: \(NSDecimalNumber(decimal: serving.quantity).stringValue) \(serving.unit.symbol)")
                            if let text = serving.text { Text(text) }
                        }
                        if let barcode = preview.revision.content.barcode { Text("Barcode: \(barcode)") }
                        ForEach(preview.revision.content.facts, id: \.key) { fact in Text("\(fact.displayName): \(Self.describe(fact.value))") }
                    }
                    Text("Shared products are visible immediately and remain unverified until owner review. Your consumed amount, time, meal, notes and history are excluded.")
                    if let state = preview.ownState { Text("Your current contribution: \(state.currentState.rawValue), revision \(state.currentRevision ?? "none").") }
                    if let sharedProduct = preview.currentSharedProduct {
                        DisclosureGroup("Current shared representative") {
                            Text("These shared facts may differ from your own contribution. They are not merged with your edit.").font(.footnote)
                            currentFacts(sharedProduct)
                        }
                    } else if preview.ownState?.currentState == .active {
                        Text("Current shared facts are unavailable. Keep the current contribution or cancel and retry review.")
                    }
                    if preview.reconciliation != nil {
                        Text("Review conflict: this action uses the displayed current revision. Your earlier failed request is retained.")
                        Button("Keep current contribution") { perform { try model.keepCurrentContribution() } }
                    }
                    Button("Share these product facts") { perform { try model.confirmShare() } }.disabled(!preview.canPublish)
                    if preview.ownState?.currentState == .rejected { Text("A rejected contribution cannot be republished. Keep the current state to review removal.") }
                    if let actionError { Text(actionError).foregroundStyle(TokenColors.error) }
                }
                .navigationTitle("Review sharing")
                .toolbar { Button("Cancel") { model.cancelReview() } }
            }
        }
    }
    @ViewBuilder private func currentFacts(_ product: CommunityProduct) -> some View {
        Text(CommunityProductSearchViewModel.name(product)).font(.headline)
        Text(CommunityProductSearchViewModel.verificationText(product))
        switch product.product {
        case .custom(let content):
            Text(content.kind.displayName)
            Text(content.basis.rawValue)
            ForEach(content.facts, id: \.key) { fact in
                Text("\(fact.displayName): \(fact.amount ?? fact.state.rawValue) \(fact.unit?.symbol ?? "")")
            }
        case .legacyLabel(let label):
            Text(label.kind?.displayName ?? "Kind needs review")
            if let serving = label.rawServingText { Text(serving) }
            ForEach(label.nutrients.keys.sorted(), id: \.self) { key in
                Text("\(key): \(NSDecimalNumber(decimal: label.nutrients[key]!).stringValue)")
            }
        }
    }
    private static func describe(_ value: NutrientValue) -> String {
        switch value {
        case .known(let amount, let unit): return "\(NSDecimalNumber(decimal: amount).stringValue) \(unit.symbol)"
        case .unknown: return "Unknown"
        case .notApplicable: return "Not applicable"
        case .belowReportingThreshold(let unit): return "Below reporting threshold" + (unit.map { " (\($0.symbol))" } ?? "")
        }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); actionError = nil; Task { await model.deliver() } }
        catch { actionError = "The product or account changed. Reopen review before trying again." }
    }
}
