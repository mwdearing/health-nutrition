import NutritionJournal
import SwiftUI

public struct AddHomeView: View {
    @ObservedObject private var model: AddHomeViewModel
    private let onBarcode: () -> Void
    private let onLabel: () -> Void
    private let onLibrary: () -> Void
    private let onType: () -> Void
    private let onNewProduct: (() -> Void)?
    private let onSearchProducts: (() -> Void)?
    private let onChanged: () -> Void
    /// Opens the details form for a Recent row (long-press or the Details action). Nothing is logged there.
    private let onOpen: ((RepeatTemplate) -> Void)?
    @State private var quickAdd: QuickAddViewModel?

    public init(model: AddHomeViewModel, onBarcode: @escaping () -> Void,
        onLabel: @escaping () -> Void, onLibrary: @escaping () -> Void,
        onType: @escaping () -> Void, onChanged: @escaping () -> Void,
        onNewProduct: (() -> Void)? = nil, onSearchProducts: (() -> Void)? = nil,
        onOpen: ((RepeatTemplate) -> Void)? = nil) {
        self.onNewProduct = onNewProduct; self.onSearchProducts = onSearchProducts; self.onOpen = onOpen
        self.model = model
        self.onBarcode = onBarcode
        self.onLabel = onLabel
        self.onLibrary = onLibrary
        self.onType = onType
        self.onChanged = onChanged
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.m) {
                // Search sits at the top: a tap opens product search, where the field takes focus.
                if let onSearchProducts {
                    Button(action: onSearchProducts) {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(TokenColors.textSecondary)
                            Text("Search foods, brands, drinks").foregroundStyle(TokenColors.textSecondary)
                            Spacer()
                        }
                        .padding(DesignSpacing.m)
                        .background(TokenColors.surface, in: RoundedRectangle(cornerRadius: DesignRadius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search foods, brands and drinks")
                    .accessibilityHint("Opens product search on this phone, Open Food Facts and shared foods.")
                }
                Picker("Meal", selection: $model.meal) {
                    Text("None").tag(MealLabel?.none)
                    ForEach(MealLabel.allCases, id: \.self) { meal in
                        Text(meal.displayName).tag(Optional(meal))
                    }
                }
                .tint(TokenColors.accent)
                tile("Scan barcode", help: model.scannerAvailability.barcode
                    ? "Read the code on the package." : model.scannerAvailability.barcodeExplanation,
                    available: model.scannerAvailability.barcode, action: onBarcode)
                tile("Scan label", help: model.scannerAvailability.label
                    ? "Read and check the nutrition values." : model.scannerAvailability.labelExplanation,
                    available: model.scannerAvailability.label, action: onLabel)
                tile("From Library", help: "Choose a favorite, recent item or recipe.", action: onLibrary)
                if let onNewProduct { tile("Create product", help: "Save product facts without logging an intake. A name is enough to start.", action: onNewProduct) }
                tile("Type it in", help: "Enter a name and amount yourself.", action: onType)
                HStack {
                    Text("Recent").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("See all", action: onLibrary).foregroundStyle(TokenColors.accent)
                }
                if model.recents.isEmpty {
                    Text(model.emptyRecentsText).foregroundStyle(TokenColors.textSecondary)
                }
                ForEach(model.recents) { recent in
                    Card {
                        HStack {
                            // A tap on the row logs once, the same as the Add capsule, with Undo.
                            Button {
                                if self.model.quickAdd(recent) != nil { self.onChanged() }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(recent.template.displayName).font(.headline)
                                    Text(model.amountSummary(of: recent.template))
                                        .font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                                }
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Log \(recent.template.displayName) now, \(model.amountSummary(of: recent.template))")
                            .accessibilityHint("Logs once. You can undo for 10 seconds.")
                            .contextMenu {
                                if let onOpen { Button("Details") { onOpen(recent.template) } }
                            }
                            .accessibilityActions {
                                if let onOpen { Button("Details") { onOpen(recent.template) } }
                            }
                            Spacer()
                            QuietCapsule("Add") {
                                if self.model.quickAdd(recent) != nil { self.onChanged() }
                            }
                            .accessibilityLabel("Log \(recent.template.displayName)")
                        }
                    }
                }
                Text("More ways").font(.headline).accessibilityAddTraits(.isHeader)
                placeholder("Describe or photograph a meal")
                tile("Amounts only", help: "Log calories and macros without choosing a food.") {
                    self.quickAdd = self.model.makeQuickAdd()
                }
                if let message = model.errorMessage { InlineNotice(message, tone: .failed) }
            }
            .padding(DesignSpacing.m)
        }
        .background(TokenColors.background)
        .navigationTitle("Add")
        .sheet(item: $quickAdd) { form in
            NavigationStack {
                QuickAddView(model: form) { token in
                    self.model.quickAdded(token)
                    self.quickAdd = nil
                    self.onChanged()
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { self.quickAdd = nil }
                    }
                }
            }
        }
        .onAppear { self.model.load() }
        .safeAreaInset(edge: .bottom) {
            if let token = model.undoToken {
                UndoToast(token.message) {
                    if self.model.undo() { self.onChanged() }
                }
                .padding(DesignSpacing.m)
                .task(id: token.intakeID) {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    self.model.expireUndo(token)
                }
            }
        }
    }

    private func tile(_ title: String, help: String, available: Bool = true,
        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Card {
                VStack(alignment: .leading, spacing: DesignSpacing.s) {
                    Text(title).font(.headline).foregroundStyle(TokenColors.textPrimary)
                    Text(help).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityElement(children: .combine)
    }

    private func placeholder(_ title: String) -> some View {
        Card {
            HStack { Text(title); Spacer(); LaterBadge() }
        }
        .disabled(true)
        .accessibilityElement(children: .combine)
        .accessibilityValue("Not available yet")
    }
}
