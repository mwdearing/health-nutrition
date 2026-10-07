import SwiftUI

public struct TodayView: View {
    @ObservedObject var model: TodayViewModel
    private let now: () -> Date
    private let onAddIntake: () -> Void
    private let onOpenJournal: (() -> Void)?
    private let onOpenLibrary: (() -> Void)?

    public init(
        model: TodayViewModel, now: @escaping () -> Date = { Date() }, onAddIntake: @escaping () -> Void,
        onOpenJournal: (() -> Void)? = nil, onOpenLibrary: (() -> Void)? = nil
    ) {
        self.model = model
        self.now = now
        self.onAddIntake = onAddIntake
        self.onOpenJournal = onOpenJournal
        self.onOpenLibrary = onOpenLibrary
    }

    public var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "drop.fill")
                        .foregroundStyle(TokenColors.accent)
                        .accessibilityLabel("Water")
                    Text(model.waterTotalDisplay.text)
                        .font(.title2)
                        .foregroundStyle(TokenColors.textPrimary)
                        .accessibilityValue(model.waterAccessibilityValue)
                }
                Button {
                    model.quickAddWater(now: now())
                } label: {
                    Text(model.quickWaterLabel).font(.headline)
                }
                .accessibilityLabel(model.quickWaterAccessibilityLabel)
                .accessibilityHint("Adds one water entry. You can undo it for 10 seconds.")
                if model.isUndoAvailable(now: now()) {
                    Button {
                        model.undoLastQuickAdd(now: now())
                    } label: {
                        Text("Undo").font(.body)
                    }
                    .accessibilityLabel("Undo last water")
                    .accessibilityValue("Available for 10 seconds after adding")
                }
                if model.waterSkippedCount > 0 {
                    Text("\(model.waterSkippedCount) water entries have a unit that is not a volume and are not counted.")
                        .font(.footnote)
                        .foregroundStyle(TokenColors.warning)
                }
            }
            Section("Coverage") {
                ForEach(model.coverage) { line in
                    Text(line.text)
                        .font(.body)
                        .foregroundStyle(line.isComplete ? TokenColors.success : TokenColors.warning)
                }
            }
            Section("Today") {
                ForEach(model.rows) { row in
                    VStack(alignment: .leading) {
                        Text(row.title).font(.headline).foregroundStyle(TokenColors.textPrimary)
                        Text(row.detail).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
                    }
                }
            }
            if onOpenJournal != nil || onOpenLibrary != nil {
                Section {
                    if let onOpenJournal {
                        Button {
                            onOpenJournal()
                        } label: {
                            Text("Journal").font(.body)
                        }
                        .accessibilityLabel("Open the journal")
                    }
                    if let onOpenLibrary {
                        Button {
                            onOpenLibrary()
                        } label: {
                            Text("Library").font(.body)
                        }
                        .accessibilityLabel("Open the library")
                    }
                }
            }
            if let message = model.errorMessage {
                Text(message).font(.footnote).foregroundStyle(TokenColors.error)
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Today")
        .toolbar {
            ToolbarItem {
                Button {
                    onAddIntake()
                } label: {
                    Image(systemName: "plus")
                        .accessibilityLabel("Add intake")
                }
                .accessibilityLabel("Add intake")
            }
        }
        .onAppear { model.load(now: now()) }
    }
}
