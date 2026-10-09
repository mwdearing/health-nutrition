import NutritionJournal
import SwiftUI

public struct AddHomeView: View {
    @ObservedObject private var model: AddHomeViewModel
    private let onBarcode: () -> Void
    private let onLabel: () -> Void
    private let onLibrary: () -> Void
    private let onType: () -> Void
    private let onChanged: () -> Void

    public init(model: AddHomeViewModel, onBarcode: @escaping () -> Void,
        onLabel: @escaping () -> Void, onLibrary: @escaping () -> Void,
        onType: @escaping () -> Void, onChanged: @escaping () -> Void) {
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
                Card {
                    HStack {
                        TextField("Search foods", text: .constant(""))
                            .accessibilityLabel("Search foods")
                        LaterBadge()
                    }
                    .disabled(true)
                    .accessibilityValue("Not available yet")
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
                            VStack(alignment: .leading) {
                                Text(recent.template.displayName).font(.headline)
                                Text(AmountText.summary(recent.template.components))
                                    .font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                            }
                            Spacer()
                            QuietCapsule("Add") {
                                if self.model.quickAdd(recent) != nil { self.onChanged() }
                            }
                            .accessibilityLabel("Add \(recent.template.displayName)")
                        }
                    }
                }
                Text("More ways").font(.headline).accessibilityAddTraits(.isHeader)
                placeholder("Describe or photograph a meal")
                placeholder("Amounts only")
                if let message = model.errorMessage { InlineNotice(message, tone: .failed) }
            }
            .padding(DesignSpacing.m)
        }
        .background(TokenColors.background)
        .navigationTitle("Add")
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
