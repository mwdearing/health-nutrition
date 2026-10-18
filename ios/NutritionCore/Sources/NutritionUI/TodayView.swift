import SwiftUI
import NutritionDomain
import NutritionJournal

/// Today: how the day stands against its goals, the water, and what was logged by meal.
///
/// The Add action is not here. It is the capsule the app shell holds above the tab bar on every tab, so
/// this view only offers Add again where it has nothing else to say (the empty day).
public struct TodayView: View {
    @ObservedObject var model: TodayViewModel
    /// Whether the "Other amount" row is open, and what is typed in it. Held here, not in the model,
    /// because it is a draft: it only becomes a water entry when Add is pressed.
    @State private var otherWaterOpen = false
    @State private var otherWaterText = ""
    @FocusState private var otherWaterFocused: Bool
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
    /// Steps, active energy and weight from Apple Health. Nil hides the card.
    private let bodyActivity: BodyActivityViewModel?
    /// The supplement list. Nil hides the supplements tile, for a host that has none.
    private let supplementStack: SupplementStackViewModel?
    /// Called after a Taken or an Undo on the supplement list opened from the tile.
    private let onSupplementLogged: () -> Void

    public init(
        model: TodayViewModel, now: @escaping () -> Date = { Date() }, onAddIntake: @escaping () -> Void,
        onEditGoals: (() -> Void)? = nil, onSelect: ((String) -> Void)? = nil,
        onAddToMeal: ((MealLabel?) -> Void)? = nil,
        checklist: FirstDayChecklistModel? = nil, onOpenUnits: (() -> Void)? = nil,
        bodyActivity: BodyActivityViewModel? = nil, supplementStack: SupplementStackViewModel? = nil,
        onSupplementLogged: @escaping () -> Void = {}
    ) {
        self.model = model
        self.now = now
        self.onAddIntake = onAddIntake
        self.onEditGoals = onEditGoals
        self.onSelect = onSelect
        self.onAddToMeal = onAddToMeal
        self.checklist = checklist
        self.onOpenUnits = onOpenUnits
        self.bodyActivity = bodyActivity
        self.supplementStack = supplementStack
        self.onSupplementLogged = onSupplementLogged
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
                NourishTodayHeader(model: model, onEditGoals: onEditGoals)
                if let note = model.activityGoalNote {
                    Text(note).font(.footnote).foregroundStyle(TokenColors.textSecondary)
                }
                waterCard
                if let supplementStack {
                    SupplementsTodayTile(model: supplementStack, now: now, onLogged: onSupplementLogged)
                }
                if let bodyActivity {
                    BodyActivityCard(model: bodyActivity, now: now)
                }
                entries
                if let summary = model.missingValuesSummary {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.textSecondary)
                }
                nutrientGapsLink
            }
            .padding(.horizontal, DesignSpacing.m)
            .padding(.vertical, DesignSpacing.s)
            .padding(.bottom, DesignSpacing.floatingClearance)
        }
        .background(TokenColors.background)
        .navigationTitle("Today")
        .onAppear { model.load(now: now()) }
    }

    /// Opens today's vitamins and minerals against published reference values. It pushes onto the
    /// navigation stack Today is shown in, so it needs nothing from the host.
    private var nutrientGapsLink: some View {
        NavigationLink {
            NutrientGapsView(makeModel: { model.makeNutrientGaps() }, now: now)
        } label: {
            Card {
                HStack {
                    Text("Vitamins and minerals")
                        .font(.headline)
                        .foregroundStyle(TokenColors.textPrimary)
                    Spacer(minLength: DesignSpacing.s)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(TokenColors.textSecondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows today's vitamins and minerals beside published reference values")
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
                HStack(spacing: DesignSpacing.m) {
                    QuietCapsule("Other amount") {
                        self.otherWaterOpen.toggle()
                        self.otherWaterFocused = self.otherWaterOpen
                    }
                    .accessibilityHint("Shows a field to type a water amount.")
                    Spacer(minLength: DesignSpacing.s)
                }
                if self.otherWaterOpen {
                    HStack(spacing: DesignSpacing.s) {
                        LabeledField(self.model.otherWaterFieldLabel, focus: self.$otherWaterFocused) { focus in
                            TextField(text: self.$otherWaterText, prompt: Text("For example, 250")) {
                                Text(self.model.otherWaterFieldLabel)
                            }
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .focused(focus)
                            .accessibilityLabel(self.model.otherWaterFieldLabel)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                        }
                        Text(self.model.otherWaterUnitSymbol)
                            .foregroundStyle(TokenColors.textSecondary)
                            .accessibilityHidden(true)
                        QuietCapsule("Add") {
                            let handle = self.model.addWater(typed: self.otherWaterText, now: self.now())
                            // A refused amount keeps the text and the row, so the reader can correct it.
                            if handle != nil {
                                self.otherWaterText = ""
                                self.otherWaterOpen = false
                            }
                        }
                        .accessibilityLabel("Add water in \(self.model.otherWaterUnitSymbol)")
                    }
                    // A draft typed in one unit must not be read in another: clear it when the unit changes.
                    .onChange(of: self.model.otherWaterUnitSymbol) { _, _ in
                        self.otherWaterText = ""
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var entries: some View {
        // Above the empty state, so deleting the last entry still offers Undo.
        if model.undo?.isDelete == true, model.isUndoAvailable(now: now()) {
            QuietCapsule("Undo delete") {
                model.undoLastQuickAdd(now: now())
            }
            .accessibilityLabel("Undo delete")
            .accessibilityValue("Available for 10 seconds after deleting")
        }
        if model.rows.isEmpty {
            EmptyState(
                title: "Nothing logged today",
                message: "Scan a label, scan a barcode or type it in.",
                systemImage: "fork.knife",
                actionTitle: AddIntakeAction.title,
                action: onAddIntake)
        } else {
            ForEach(model.mealSections) { section in
                mealSection(section)
            }
        }
    }

    private func mealSection(_ section: TodayMealSection) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title)
                    .font(.headline)
                    .foregroundStyle(TokenColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let kcal = section.energyKcal {
                    // A small positive amount must not round to "0 kcal", which reads as nothing logged.
                    let figure = kcal > 0 && kcal < 1 ? "under 1" : BodyActivityViewModel.whole(kcal)
                    Text("\(figure) kcal")
                        .font(.subheadline)
                        .foregroundStyle(TokenColors.textSecondary)
                        .accessibilityLabel("\(figure) calories")
                }
                Spacer()
            }
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
        SwipeToDeleteRow(
            accessibilityName: "Delete \(row.title)",
            onDelete: { _ = model.deleteEntry(intakeID: row.id, now: now()) }
        ) {
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
                    title: row.title, detail: row.detailLine, kind: row.kind, isWater: row.isWater,
                    showsChevron: false)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.accessibilityText)
            }
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

/// Reveals a Delete button on a leftward swipe. The meal cards are not a List, so `swipeActions` is not
/// available; VoiceOver gets the same action without the swipe.
private struct SwipeToDeleteRow<Content: View>: View {
    let accessibilityName: String
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var offset: CGFloat = 0
    @State private var settled: CGFloat = 0
    private let revealWidth: CGFloat = 84

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive) {
                withAnimation(.snappy) { offset = 0; settled = 0 }
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.title3)
                    .frame(width: revealWidth)
                    .frame(maxHeight: .infinity)
                    .foregroundStyle(.white)
                    .background(TokenColors.error, in: RoundedRectangle(cornerRadius: DesignRadius.control))
            }
            .accessibilityLabel(accessibilityName)
            .opacity(offset < 0 ? 1 : 0)
            content()
                .offset(x: offset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            offset = min(0, max(-revealWidth, settled + value.translation.width))
                        }
                        .onEnded { _ in
                            withAnimation(.snappy) {
                                settled = offset < -revealWidth / 2 ? -revealWidth : 0
                                offset = settled
                            }
                        })
                .accessibilityAction(named: accessibilityName) { onDelete() }
        }
    }
}

