import NutritionDomain
import SwiftUI

public struct JournalView: View {
    @ObservedObject var model: JournalViewModel
    private let now: () -> Date
    private let onSelect: (String) -> Void
    /// Adds an entry from the empty journal. Nil leaves the empty state without a button.
    private let onAdd: (() -> Void)?

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
        List {
            jumpToDateRow
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
            if let message = model.errorMessage {
                InlineNotice(message, tone: .failed)
                    .listRowBackground(TokenColors.background)
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Journal")
        .onAppear { model.load(now: now()) }
    }

    /// A disabled row for a feature this build does not have yet.
    private var jumpToDateRow: some View {
        HStack(spacing: DesignSpacing.s) {
            Label("Jump to date", systemImage: "calendar")
                .foregroundStyle(TokenColors.textPrimary)
            Spacer(minLength: DesignSpacing.s)
            LaterBadge()
        }
        .accessibilityElement(children: .combine)
        .laterPlaceholder()
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
            .laterPlaceholder()
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
        .accessibilityHint("Shows this day's entries")
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
