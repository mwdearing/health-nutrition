import NutritionJournal
import SwiftUI

public struct AddHomeView: View {
    /// How the four quick actions lay out: one row at normal text sizes, two columns at accessibility sizes.
    public enum QuickActionLayout: Equatable {
        case row, grid
    }

    /// The layout is picked from the text size, not from whether a row happens to fit, so the choice is testable.
    public static func quickActionLayout(for size: DynamicTypeSize) -> QuickActionLayout {
        size.isAccessibilitySize ? .grid : .row
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The search row's visible text, also its spoken label, so the two cannot drift apart.
    public static let searchRowTitle = "Search foods"
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
                            Text(Self.searchRowTitle).foregroundStyle(TokenColors.textSecondary)
                            Spacer()
                        }
                        .padding(DesignSpacing.m)
                        .background(TokenColors.surface, in: RoundedRectangle(cornerRadius: DesignRadius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.searchRowTitle)
                    .accessibilityIdentifier("addSearchRow")
                    .accessibilityHint("Opens product search on this phone, public food databases and shared foods.")
                }
                Picker(selection: $model.meal) {
                    Text("None").tag(MealLabel?.none)
                    ForEach(MealLabel.allCases, id: \.self) { meal in
                        Text(meal.displayName).tag(Optional(meal))
                    }
                } label: {
                    Text(Self.mealRowTitle(model.meal))
                }
                .tint(TokenColors.accent)
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
                            // A tap on the row opens its details; the Add control beside it logs once, with Undo (#503).
                            Button {
                                onOpen?(recent.template)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(recent.template.displayName).font(.headline)
                                    Text(model.recentSubtitle(of: recent.template))
                                        .font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                                }
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Opens \(recent.template.displayName), \(model.recentSubtitle(of: recent.template))")
                            .accessibilityHint("Opens details without adding an entry")
                            Spacer()
                            QuietCapsule("Add") {
                                if self.model.quickAdd(recent) != nil { self.onChanged() }
                            }
                            .accessibilityLabel("Log \(recent.template.displayName)")
                            .accessibilityValue(model.recentSubtitle(of: recent.template))
                            .accessibilityHint("Logs once. You can undo for 10 seconds.")
                        }
                    }
                }
                if Self.quickActionLayout(for: dynamicTypeSize) == .grid {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DesignSpacing.s) {
                        ForEach(quickActions) { quickActionButton($0) }
                    }
                } else {
                    HStack(spacing: DesignSpacing.s) { ForEach(quickActions) { quickActionButton($0) } }
                }
                // Why a quick action is off is shown in words, not only in its hint.
                ForEach(quickActions.filter { !$0.available && !$0.explanation.isEmpty }) { action in
                    Text("\(action.title): \(action.explanation)")
                        .font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                }
                plainRow("From Library", help: "Choose a favorite, recent item or recipe.", action: onLibrary)
                if let onNewProduct {
                    plainRow("Create product", help: "Save product facts without logging an intake. A name is enough to start.", action: onNewProduct)
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
                .id(token.intakeID)
                .padding(DesignSpacing.m)
                .task(id: token.intakeID) {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    self.model.expireUndo(token)
                }
            }
        }
    }

    /// The Meal row's label names the current choice, so the value is visible without opening the picker.
    public static func mealRowTitle(_ meal: MealLabel?) -> String {
        "Meal: \(meal?.displayName ?? "None")"
    }

    /// The four quick actions in one compact row; a row too narrow for four wraps them into two columns.
    private var quickActions: [QuickAction] {
        [
            QuickAction(id: "barcode", title: "Barcode", icon: "barcode.viewfinder",
                help: "Read the code on the package.",
                available: model.scannerAvailability.barcode,
                explanation: model.scannerAvailability.barcodeExplanation, action: onBarcode),
            QuickAction(id: "label", title: "Label", icon: "text.viewfinder",
                help: "Read and check the nutrition values.",
                available: model.scannerAvailability.label,
                explanation: model.scannerAvailability.labelExplanation, action: onLabel),
            QuickAction(id: "type", title: "Type it in", icon: "keyboard",
                help: "Enter a name and amount yourself.",
                available: true, explanation: "", action: onType),
            QuickAction(id: "amounts", title: "Amounts only", icon: "slider.horizontal.3",
                help: "Log calories and macros without choosing a food.",
                available: true, explanation: "", action: { self.quickAdd = self.model.makeQuickAdd() }),
        ]
    }

    private func quickActionButton(_ action: QuickAction) -> some View {
        Button(action: action.action) {
            VStack(spacing: DesignSpacing.xs) {
                Image(systemName: action.icon).font(.title3)
                Text(action.title).font(.subheadline).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(DesignSpacing.s)
            .background(TokenColors.surface, in: RoundedRectangle(cornerRadius: DesignRadius.control, style: .continuous))
            .foregroundStyle(TokenColors.textPrimary)
            // Dimmed while unavailable, so the state reads without the reason line.
            .opacity(action.available ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!action.available)
        .accessibilityLabel(action.title)
        .accessibilityHint(action.available ? action.help : action.explanation)
    }

    /// A full-width row for the actions that need a line of help, such as From Library.
    private func plainRow(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Card {
                VStack(alignment: .leading, spacing: DesignSpacing.s) {
                    Text(title).font(.headline).foregroundStyle(TokenColors.textPrimary)
                    Text(help).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

private struct QuickAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    let help: String
    let available: Bool
    let explanation: String
    let action: () -> Void
}
