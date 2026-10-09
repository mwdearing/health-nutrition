import SwiftUI
import NutritionDomain
import NutritionJournal

/// Today: how the day stands against its goals, the water, and what was logged by meal.
///
/// The Add action is not here. It is the capsule the app shell holds above the tab bar on every tab, so
/// this view only offers Add again where it has nothing else to say (the empty day).
public struct TodayView: View {
    @ObservedObject var model: TodayViewModel
    private let now: () -> Date
    private let onAddIntake: () -> Void
    /// Opens the daily goals. Nil hides the "Edit goals" link, for a host with nowhere to route to.
    private let onEditGoals: (() -> Void)?
    /// Opens one entry, so what Today lists can be corrected there rather than only read. Nil hides
    /// the affordance and leaves the rows as plain content, which is what a host that has nowhere to
    /// route to wants.
    private let onSelect: ((String) -> Void)?
    private let onAddToMeal: ((MealLabel?) -> Void)?
    /// The first-day checklist. Nil hides the card, for a host that does not show it.
    private let checklist: FirstDayChecklistModel?
    /// Opens the units settings from the checklist's "Choose units" step. Nil leaves that step with no
    /// settings screen to open.
    private let onOpenUnits: (() -> Void)?

    public init(
        model: TodayViewModel, now: @escaping () -> Date = { Date() }, onAddIntake: @escaping () -> Void,
        onEditGoals: (() -> Void)? = nil, onSelect: ((String) -> Void)? = nil,
        onAddToMeal: ((MealLabel?) -> Void)? = nil,
        checklist: FirstDayChecklistModel? = nil, onOpenUnits: (() -> Void)? = nil
    ) {
        self.model = model
        self.now = now
        self.onAddIntake = onAddIntake
        self.onEditGoals = onEditGoals
        self.onSelect = onSelect
        self.onAddToMeal = onAddToMeal
        self.checklist = checklist
        self.onOpenUnits = onOpenUnits
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.m) {
                Text(model.dateSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(TokenColors.textSecondary)
                notices
                if let checklist {
                    FirstDayChecklistCard(
                        model: checklist, onLog: onAddIntake,
                        onGoals: { onEditGoals?() }, onUnits: { onOpenUnits?() })
                }
                goalsCard
                waterCard
                entries
                if let summary = model.missingValuesSummary {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.textSecondary)
                }
            }
            .padding(.horizontal, DesignSpacing.m)
            .padding(.vertical, DesignSpacing.s)
        }
        .background(TokenColors.background)
        .navigationTitle("Today")
        .onAppear { model.load(now: now()) }
    }

    @ViewBuilder
    private var notices: some View {
        if let message = model.errorMessage {
            InlineNotice(message, tone: .failed)
        }
        if model.skippedIntakeCount > 0 {
            InlineNotice("\(model.skippedIntakeCount) entries can't be shown.", tone: .waiting)
        }
    }

    private var goalsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: DesignSpacing.m) {
                HStack {
                    Text("Daily goals")
                        .font(.headline)
                        .foregroundStyle(TokenColors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: DesignSpacing.s)
                    if let onEditGoals {
                        Button("Edit goals") { onEditGoals() }
                            .font(.subheadline)
                            .foregroundStyle(TokenColors.accent)
                            .accessibilityHint("Opens the daily goals")
                    }
                }
                ForEach(model.goalBars) { bar in
                    GoalBar(bar)
                }
            }
        }
    }

    private var waterCard: some View {
        Card {
            VStack(alignment: .leading, spacing: DesignSpacing.m) {
                if let bar = model.waterBar {
                    GoalBar(bar)
                } else {
                    HStack {
                        Image(systemName: "drop.fill")
                            .foregroundStyle(TokenColors.accent)
                            .accessibilityHidden(true)
                        Text("Water")
                            .font(.headline)
                            .foregroundStyle(TokenColors.textPrimary)
                        Spacer(minLength: DesignSpacing.s)
                        Text(model.waterTotalDisplay.text)
                            .font(.title3)
                            .foregroundStyle(TokenColors.textPrimary)
                            .accessibilityValue(model.waterAccessibilityValue)
                    }
                    if model.waterSkippedCount > 0 {
                        InlineNotice(
                            "\(model.waterSkippedCount) water entries have a unit that is not a volume and are not counted.",
                            tone: .waiting)
                    }
                }
                HStack(spacing: DesignSpacing.m) {
                    QuietCapsule(model.quickWaterLabel) {
                        model.quickAddWater(now: now())
                    }
                    .accessibilityLabel(model.quickWaterAccessibilityLabel)
                    .accessibilityHint("Adds one water entry. You can undo it for 10 seconds.")
                    if model.isUndoAvailable(now: now()) {
                        QuietCapsule("Undo") {
                            model.undoLastQuickAdd(now: now())
                        }
                        .accessibilityLabel("Undo last water")
                        .accessibilityValue("Available for 10 seconds after adding")
                    }
                    Spacer(minLength: DesignSpacing.s)
                }
                HStack(spacing: DesignSpacing.s) {
                    Text("Other amount").font(.subheadline)
                    LaterBadge()
                }
                .foregroundStyle(TokenColors.textSecondary)
                .accessibilityElement(children: .combine)
                .laterPlaceholder()
            }
        }
    }

    @ViewBuilder
    private var entries: some View {
        if model.rows.isEmpty {
            EmptyState(
                title: "Nothing logged today",
                message: "Scan a label, scan a barcode or type it in.",
                systemImage: "fork.knife",
                actionTitle: "Add food or drink",
                action: onAddIntake)
        } else {
            ForEach(model.mealSections) { section in
                mealSection(section)
            }
        }
    }

    private func mealSection(_ section: TodayMealSection) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s) {
            Text(section.title)
                .font(.headline)
                .foregroundStyle(TokenColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Card {
                VStack(alignment: .leading, spacing: DesignSpacing.m) {
                    ForEach(section.rows) { row in
                        entryRow(row)
                        if row.id != section.rows.last?.id {
                            Divider()
                        }
                    }
                }
            }
            if self.onAddToMeal != nil {
                Button("Add to \(section.title)") {
                    self.onAddToMeal?(MealLabel(rawValue: section.title.lowercased()))
                }
                .font(.subheadline)
                .foregroundStyle(TokenColors.accent)
            }
        }
    }

    /// One entry. A supplement carries its tag, because its amounts read like any other entry's and
    /// nothing in them says it is not food; a food carries none.
    @ViewBuilder
    private func entryRow(_ row: TodayRow) -> some View {
        if let onSelect {
            Button {
                onSelect(row.id)
            } label: {
                EntryRow(title: row.title, detail: row.detailLine, kind: row.kind, isWater: row.isWater)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.accessibilityText)
            .accessibilityHint("Opens the entry")
        } else {
            EntryRow(
                title: row.title, detail: row.detailLine, kind: row.kind, isWater: row.isWater, showsChevron: false)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(row.accessibilityText)
        }
    }
}

/// Observes the checklist so the card appears and goes away as its steps change. An optional model
/// cannot be observed directly, so the card is held here.
private struct FirstDayChecklistCard: View {
    @ObservedObject var model: FirstDayChecklistModel
    let onLog: () -> Void
    let onGoals: () -> Void
    let onUnits: () -> Void

    var body: some View {
        if model.isVisible {
            FirstDayChecklistView(model: model, onLog: onLog, onGoals: onGoals, onUnits: onUnits)
        }
    }
}
