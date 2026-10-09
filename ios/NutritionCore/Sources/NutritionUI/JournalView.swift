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
                        actionTitle: onAdd == nil ? nil : "Add food or drink",
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
                if let notice = jumpNotice {
                    InlineNotice(notice, tone: .waiting)
                        .padding(DesignSpacing.m)
                        .background(TokenColors.background)
                }
            }
            // A notice about an earlier jump goes whenever the journal reloads.
            .onChange(of: model.loadCount) { _, _ in
                jumpNotice = nil
            }
            .onChange(of: jumpSerial) { _, _ in
                if let section = jumpSection {
                    proxy.scrollTo(section, anchor: .top)
                }
            }
            .scrollContentBackground(.hidden)
            .background(TokenColors.background)
            .navigationTitle("Journal")
            .onAppear {
                model.load(now: now())
                jumpNotice = nil
            }
            .sheet(isPresented: $showingJumpSheet) {
                jumpSheet
            }
        }
    }

    /// Opens the jump sheet on today. The row is a button, so a screen reader hears what it does.
    private var jumpToDateRow: some View {
        Button {
            pickedDay = now()
            showingJumpSheet = true
        } label: {
            HStack(spacing: DesignSpacing.s) {
                Label("Jump to date", systemImage: "calendar")
                    .foregroundStyle(TokenColors.textPrimary)
                Spacer(minLength: DesignSpacing.s)
            }
        }
        .accessibilityHint("Opens a calendar to choose a day")
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
                ForEach(week.goalLines, id: \.self) { line in
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
                ForEach(section.mealGroups) { group in
                    Text(group.title)
                        .font(.subheadline)
                        .foregroundStyle(TokenColors.textSecondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.rows) { row in
                        entryButton(row)
                    }
                }
            }
        }
        .id(section.id)
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
            HStack(spacing: DesignSpacing.s) {
                Label("Add to this day", systemImage: "plus")
                    .foregroundStyle(TokenColors.textPrimary)
                Spacer(minLength: DesignSpacing.s)
                LaterBadge()
            }
            .accessibilityElement(children: .combine)
            .disabled(true)
            .accessibilityValue("Not available yet")
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
