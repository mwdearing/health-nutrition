import NutritionDomain
import SwiftUI

public struct JournalView: View {
    @ObservedObject var model: JournalViewModel
    private let now: () -> Date
    private let onSelect: (String) -> Void
    /// Adds an entry from the empty journal. Nil leaves the empty state without a button.
    private let onAdd: (() -> Void)?
    /// The day picked in the jump sheet, read when the sheet opens.
    @State private var pickedDay = Date()
    @State private var showingJumpSheet = false
    /// The sentence for the last jump, shown at the top of the list until the next jump or a reload.
    @State private var jumpNotice: String?
    /// The section the last jump chose, and a counter that changes on every jump so the list scrolls
    /// even when two jumps choose the same day.
    @State private var jumpSection: String?
    @State private var jumpSerial = 0
    /// The day sections currently on screen, kept as the list scrolls. The arrows step from the top one.
    @State private var visibleDayIDs: Set<String> = []
    /// The meal group "Save as meal" is naming, while its name prompt is up.
    @State private var saveMealTarget: SaveMealTarget?
    @State private var saveMealName = ""
    /// True once Save was tapped in the open prompt, so the prompt shows only its own refusal.
    @State private var saveMealTried = false
    @State private var saveNotice: SaveNotice?
    @Environment(\.scenePhase) private var scenePhase
    /// True while the reload on return to the app is in flight, so it keeps a jump notice on screen.
    @State private var reloadingOnReturn = false

    public init(
        model: JournalViewModel, now: @escaping () -> Date = { Date() }, onSelect: @escaping (String) -> Void,
        onAdd: (() -> Void)? = nil
    ) {
        self.model = model
        self.now = now
        self.onSelect = onSelect
        self.onAdd = onAdd
    }

    public var body: some View {
        ScrollViewReader { proxy in
            List {
                jumpToDateRow
                if let week = model.weekSummary {
                    weekSummaryCard(week)
                        .listRowSeparator(.hidden)
                        .listRowBackground(TokenColors.background)
                }
                if model.isEmpty {
                    EmptyState(
                        title: "Your journal is empty",
                        message: "Everything you log is listed here by day.",
                        systemImage: "book",
                        actionTitle: onAdd == nil ? nil : AddIntakeAction.title,
                        action: onAdd)
                }
                ForEach(model.sections) { section in
                    daySection(section)
                }
                if let skipped = model.skippedText {
                    InlineNotice(skipped, tone: .waiting)
                        .listRowBackground(TokenColors.background)
                }
                if let goalsMessage = model.goalsErrorMessage {
                    InlineNotice(goalsMessage, tone: .failed)
                        .listRowBackground(TokenColors.background)
                }
                if let message = model.errorMessage {
                    InlineNotice(message, tone: .failed)
                        .listRowBackground(TokenColors.background)
                }
            }
            // Outside the scrolling rows, so the sentence stays visible after the list scrolls to the day.
            .safeAreaInset(edge: .top) {
                // A jump made after a copy wins: the copy's own reload already cleared any earlier jump notice.
                if let notice = jumpNotice {
                    InlineNotice(notice, tone: .waiting)
                        .padding(DesignSpacing.m)
                        .background(TokenColors.background)
                } else if let copied = model.copyNotice {
                    InlineNotice(copied, tone: model.copyFailed ? .failed : .waiting)
                        .padding(DesignSpacing.m)
                        .background(TokenColors.background)
                }
            }
            // A notice about an earlier jump goes whenever the journal reloads, except the reload on return to the app.
            .onChange(of: model.loadCount) { _, _ in
                if !reloadingOnReturn { jumpNotice = nil }
                reloadingOnReturn = false
            }
            .onChange(of: jumpSerial) { _, _ in
                if let section = jumpSection {
                    proxy.scrollTo(section, anchor: .top)
                }
            }
            .contentMargins(.bottom, DesignSpacing.floatingClearance, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(TokenColors.background)
            .navigationTitle("Journal")
            .saveConfirmation(saveNotice)
            .onAppear {
                reloadingOnReturn = false
                model.load(now: now())
                jumpNotice = nil
            }
            // Coming back to the app reloads the day titles, so "Yesterday" moves on after midnight.
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    reloadingOnReturn = true
                    model.load(now: now())
                }
            }
            .sheet(isPresented: $showingJumpSheet) {
                jumpSheet
            }
            .sheet(item: $saveMealTarget) { target in
                saveMealSheet(target)
            }
        }
    }

    /// Names a meal group and saves it as a saved meal. Save waits for a name; a refusal shows as the notice.
    private func saveMealSheet(_ target: SaveMealTarget) -> some View {
        NavigationStack {
            Form {
                LabeledField("Meal name") { focus in
                    TextField("Such as Usual breakfast", text: $saveMealName).focused(focus)
                }
                Text("Keeps the \(target.entryCountText) of \(target.title) together, so you can log them again in one go from Add, in Find products.")
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
                // A refusal keeps the prompt open with the typed name, so the person can change it.
                if saveMealTried, model.copyFailed, let notice = model.copyNotice {
                    InlineNotice(notice, tone: .failed)
                }
            }
            .navigationTitle("Save as meal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { saveMealTarget = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // The outcome shows at the top of the list, where an earlier jump's note would hide it.
                        jumpNotice = nil
                        saveMealTried = true
                        if model.saveMeal(target.sectionID, groupID: target.groupID, name: saveMealName) {
                            saveNotice = SaveNotice(SaveLabels.mealSaved)
                            saveMealTarget = nil
                        }
                    }
                    .disabled(saveMealName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// Opens the jump sheet on today, with one-day arrows beside it. The arrows step from the day last shown.
    private var jumpToDateRow: some View {
        HStack(spacing: DesignSpacing.s) {
            Button {
                pickedDay = now()
                showingJumpSheet = true
            } label: {
                Label("Jump to date", systemImage: "calendar")
                    .foregroundStyle(TokenColors.textPrimary)
            }
            .accessibilityHint("Opens a calendar to choose a day")
            Spacer(minLength: DesignSpacing.s)
            Button { stepDay(-1) } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Previous day")
            Button { stepDay(1) } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Next day")
            .disabled(isShowingToday)
        }
    }

    /// The day the arrows step from: the earliest day at the top of the visible list, or today.
    private var arrowBase: Date {
        JournalViewModel.arrowBaseDay(sectionIDs: model.sections.map(\.id), visible: visibleDayIDs, zone: .current, now: now())
    }

    /// Forward is disabled when the arrows already point at today.
    private var isShowingToday: Bool {
        Calendar.current.isDate(arrowBase, inSameDayAs: now()) || arrowBase > now()
    }

    /// Moves one calendar day back or forward from the day at the top of the list, using the same jump as the sheet.
    /// Forward stops at today.
    private func stepDay(_ days: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: days, to: arrowBase), date <= now() || days < 0 else { return }
        let target = model.jumpTarget(for: date, now: now())
        model.reveal(target)
        jumpNotice = target.message
        jumpSection = target.sectionID
        jumpSerial += 1
    }

    /// The seven days ending today: a heading, the logged count, and one line per goal. It reads as one element.
    private func weekSummaryCard(_ week: JournalWeekSummary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: DesignSpacing.s) {
                Text("This week")
                    .font(.headline)
                    .foregroundStyle(TokenColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(week.headline)
                    .font(.subheadline)
                    .foregroundStyle(TokenColors.textPrimary)
                ForEach(Array(week.goalLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(TokenColors.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// A graphical day picker bounded to today, and the button that goes to the chosen day.
    private var jumpSheet: some View {
        NavigationStack {
            VStack(spacing: DesignSpacing.m) {
                DatePicker(
                    "Day", selection: $pickedDay, in: ...now(), displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .accessibilityLabel("Day to show")
                Button {
                    goToPickedDay()
                } label: {
                    Text("Go to day")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Go to day")
            }
            .padding(DesignSpacing.m)
            .navigationTitle("Jump to date")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingJumpSheet = false }
                }
            }
        }
    }

    /// Closes the sheet, shows the sentence for the day if it had none, and scrolls to the section chosen.
    private func goToPickedDay() {
        let target = model.jumpTarget(for: pickedDay, now: now())
        model.reveal(target)
        jumpNotice = target.message
        jumpSection = target.sectionID
        jumpSerial += 1
        showingJumpSheet = false
    }

    /// One day: a header card with its energy and goal bars, then its entries by meal. An old day is
    /// collapsed to one button that counts its entries until it is opened.
    private func daySection(_ section: JournalDaySection) -> some View {
        Section {
            Card {
                dayHeader(section)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(TokenColors.background)
            if section.isCollapsedByDefault {
                toggleRow(section)
            }
            if model.isExpanded(section) {
                // Each meal is its own row in its own card, so the List still lays out and recycles rows per meal.
                ForEach(section.mealGroups) { group in
                    Card {
                        VStack(alignment: .leading, spacing: DesignSpacing.m) {
                            mealHeader(group, in: section)
                            ForEach(group.rows) { row in
                                entryButton(row)
                            }
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(TokenColors.background)
                }
            }
        }
        .id(section.id)
        .onAppear { visibleDayIDs.insert(section.id) }
        .onDisappear { visibleDayIDs.remove(section.id) }
    }

    /// The title, the day's energy when it is known, one bar per goal, and the disabled add action.
    private func dayHeader(_ section: JournalDaySection) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s) {
            Text(section.title)
                .font(.headline)
                .foregroundStyle(TokenColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if let energy = section.energyText {
                Text(energy)
                    .font(.subheadline)
                    .foregroundStyle(TokenColors.textSecondary)
            }
            ForEach(section.headerBars) { bar in
                GoalBar(bar)
            }
            if model.canCopyToToday(section, now: now()) {
                Button {
                    model.copyDayToToday(section.id, now: now())
                } label: {
                    Label("Copy this day to today", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Adds every entry of this day to today as new entries")
            }
        }
    }

    /// A meal's title and, on a past day, a button that copies just that meal to today.
    private func mealHeader(_ group: JournalMealGroup, in section: JournalDaySection) -> some View {
        HStack(spacing: DesignSpacing.s) {
            Text(group.title)
                .font(.subheadline)
                .foregroundStyle(TokenColors.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: DesignSpacing.s)
            // Labeled buttons when they fit; icon-only when the row is too narrow for both.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSpacing.s) { mealActions(group, in: section, iconOnly: false) }
                HStack(spacing: DesignSpacing.s) { mealActions(group, in: section, iconOnly: true) }
            }
        }
    }

    @ViewBuilder
    private func mealActions(_ group: JournalMealGroup, in section: JournalDaySection, iconOnly: Bool) -> some View {
        if model.savedMeals != nil, !group.rows.isEmpty {
            Button {
                saveMealName = ""
                saveMealTried = false
                saveMealTarget = SaveMealTarget(
                    sectionID: section.id, groupID: group.id, title: group.title,
                    entryCountText: group.rows.count == 1 ? "1 entry" : "\(group.rows.count) entries")
            } label: {
                if iconOnly {
                    Label("Save as meal", systemImage: "bookmark").labelStyle(.iconOnly).font(.subheadline)
                } else {
                    Label("Save as meal", systemImage: "bookmark").font(.subheadline)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Save \(group.title) as a meal")
        }
        if model.canCopyToToday(section, now: now()) {
            Button {
                model.copyMealToToday(section.id, groupID: group.id, now: now())
            } label: {
                if iconOnly {
                    Label("Copy to today", systemImage: "doc.on.doc").labelStyle(.iconOnly).font(.subheadline)
                } else {
                    Label("Copy to today", systemImage: "doc.on.doc").font(.subheadline)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy \(group.title) to today")
        }
    }

    /// Opens a collapsed day or collapses an open one. It shows the day's entry count.
    private func toggleRow(_ section: JournalDaySection) -> some View {
        Button {
            model.toggleDay(section.id)
        } label: {
            HStack(spacing: DesignSpacing.s) {
                Text(section.entryCountText)
                    .font(.subheadline)
                    .foregroundStyle(TokenColors.textPrimary)
                Spacer(minLength: DesignSpacing.s)
                Image(systemName: model.isExpanded(section) ? "chevron.up" : "chevron.down")
                    .foregroundStyle(TokenColors.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(section.entryCountText)
        .accessibilityHint(model.isExpanded(section) ? "Hides this day's entries" : "Shows this day's entries")
    }

    private func entryButton(_ row: JournalRow) -> some View {
        Button {
            onSelect(row.id)
        } label: {
            entryRow(row)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(row.accessibilityText)
        .accessibilityHint("Opens the entry")
    }

    /// One entry: what it was, how much of it, and which meal it was for, as the shared row. The meal
    /// joins the amounts on one line because it qualifies the entry rather than being another amount.
    /// A supplement and a drink carry their tag; a food carries none.
    private func entryRow(_ row: JournalRow) -> some View {
        let detail = [row.detail, row.meal].compactMap { $0 }.joined(separator: " · ")
        return EntryRow(title: row.title, detail: detail, kind: row.kind, isWater: row.isWater)
    }
}

/// The meal group a Save as meal prompt is for.
private struct SaveMealTarget: Identifiable, Equatable {
    let sectionID: String
    let groupID: String
    let title: String
    let entryCountText: String
    var id: String { sectionID + "|" + groupID }
}
