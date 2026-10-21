import Foundation
import NutritionJournal
import SwiftUI

/// One row of the first-day checklist.
public struct FirstDayChecklistItem: Equatable, Identifiable {
    public enum Kind: String {
        case logFirst, setGoal, chooseUnits, connectHealth
    }

    public let kind: Kind
    public var id: String { kind.rawValue }
    public let title: String
    /// A short line under the title, where the row has a value to show.
    public let detail: String?
    public let isDone: Bool
}

/// The first-day checklist: the steps a new person can work through, and whether each is done.
///
/// The three real steps tick off from what is stored: an entry in the journal, a daily goal, and the
/// units having been looked at. The Health step is the last row, shown when this device has Health.
/// The card is shown until the three real
/// steps are done or until the person hides it, and the hiding is stored.
@MainActor
public final class FirstDayChecklistModel: ObservableObject {
    private let store: JournalStore
    private let goals: GoalStore?
    private let preferences: DisplayPreferences & FirstRunPreferences
    private let health: AppleHealthConnectionViewModel?

    @Published public private(set) var items: [FirstDayChecklistItem] = []
    @Published public private(set) var isVisible: Bool = false

    /// `goals` is nil for a host with no goal store; the goal step then stays not done. `health` is nil
    /// for a host with no Health row; the Health step is then left off the card.
    public init(
        store: JournalStore, goals: GoalStore?, preferences: DisplayPreferences & FirstRunPreferences,
        health: AppleHealthConnectionViewModel? = nil
    ) {
        self.store = store
        self.goals = goals
        self.preferences = preferences
        self.health = health
    }

    /// Reads the steps again. A journal or goal read that throws leaves its step not done rather
    /// than failing the card. The Health step is done when Health is connected and has nothing left to
    /// ask, and is left off when this device has no Health to connect to.
    public func load() {
        let hasEntry = (try? store.activeIntakes()).map { !$0.isEmpty } ?? false
        var hasGoal = false
        if let goals = goals, let stored = try? goals.goals() {
            hasGoal = !stored.isEmpty
        }
        items = [
            FirstDayChecklistItem(
                kind: .logFirst, title: "Log your first food, drink, or supplement", detail: nil,
                isDone: hasEntry),
            FirstDayChecklistItem(
                kind: .setGoal, title: "Set a daily goal", detail: nil,
                isDone: hasGoal),
            FirstDayChecklistItem(
                kind: .chooseUnits, title: "Choose units", detail: Self.unitsName(preferences.unitSystem),
                isDone: preferences.hasReviewedUnits),
        ]
        if let health = health {
            health.refresh()
            if health.state != .unavailable {
                items.append(FirstDayChecklistItem(
                    kind: .connectHealth, title: "Connect Apple Health", detail: nil,
                    isDone: health.isComplete))
            }
        }
        // The Health row is appended after the three real steps, so these are the first three.
        let realStepsDone = items.prefix(3).allSatisfy { $0.isDone }
        isVisible = !preferences.isChecklistHidden && !realStepsDone
    }

    /// Asks Health for access where it can still be asked, then reads the steps again.
    public func connectHealth() async {
        guard let health = health else { return }
        await health.connect()
        load()
    }

    /// Hides the card now and keeps it hidden for later launches.
    public func hide() {
        preferences.setChecklistHidden(true)
        isVisible = false
    }

    /// Records that the units were looked at, then reads the steps again.
    public func markUnitsReviewed() {
        preferences.setHasReviewedUnits(true)
        load()
    }

    /// The short name the Settings unit picker shows for each system.
    private static func unitsName(_ system: UnitSystem) -> String {
        switch system {
        case .metric: return "Metric"
        case .usCustomary: return "US"
        }
    }
}

/// The checklist card on Today. Each step is a button.
public struct FirstDayChecklistView: View {
    @ObservedObject private var model: FirstDayChecklistModel
    private let onLog: () -> Void
    private let onGoals: () -> Void
    private let onUnits: () -> Void

    public init(
        model: FirstDayChecklistModel, onLog: @escaping () -> Void, onGoals: @escaping () -> Void,
        onUnits: @escaping () -> Void
    ) {
        self.model = model
        self.onLog = onLog
        self.onGoals = onGoals
        self.onUnits = onUnits
    }

    public var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DesignSpacing.m) {
                Text("Getting started")
                    .font(.headline)
                    .foregroundStyle(TokenColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(model.items) { item in
                    itemRow(item)
                }
                HStack {
                    Spacer(minLength: DesignSpacing.s)
                    Button("Hide checklist") { model.hide() }
                        .font(.subheadline)
                        .foregroundStyle(TokenColors.accent)
                        .accessibilityHint("Hides this checklist")
                }
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: FirstDayChecklistItem) -> some View {
        Button {
            act(item.kind)
        } label: {
            rowContent(item)
        }
        .buttonStyle(.plain)
        .accessibilityValue(item.isDone ? "Done" : "Not done")
    }

    private func rowContent(_ item: FirstDayChecklistItem) -> some View {
        HStack(alignment: .center, spacing: DesignSpacing.s) {
            Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.isDone ? TokenColors.accent : TokenColors.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                Text(item.title)
                    .foregroundStyle(TokenColors.textPrimary)
                if let detail = item.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.textSecondary)
                }
            }
            Spacer(minLength: DesignSpacing.s)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func act(_ kind: FirstDayChecklistItem.Kind) {
        switch kind {
        case .logFirst:
            onLog()
        case .setGoal:
            onGoals()
        case .chooseUnits:
            model.markUnitsReviewed()
            onUnits()
        case .connectHealth:
            Task { await model.connectHealth() }
        }
    }
}
