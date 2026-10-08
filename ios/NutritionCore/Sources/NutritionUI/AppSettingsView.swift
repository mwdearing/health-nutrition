import SwiftUI

/// A setting the product intends and this build does not have yet. Shown as a disabled row with a
/// "Later" badge so the design is present; it has no handler and no stored state.
public enum SettingsPlaceholder: CaseIterable, Equatable, Sendable {
    case dailyPrompts, appleHealth, healthRelay, communitySharing, keepHistory

    public var title: String {
        switch self {
        case .dailyPrompts: return "Daily prompts"
        case .appleHealth: return "Apple Health"
        case .healthRelay: return "HealthRelay"
        case .communitySharing: return "Community sharing"
        case .keepHistory: return "Keep history for"
        }
    }

    public var detail: String {
        switch self {
        case .dailyPrompts: return "A gentle prompt to log a meal"
        case .appleHealth: return "Write entries to Apple Health"
        case .healthRelay: return "Send entries to your own HealthRelay"
        case .communitySharing: return "Share foods you have checked"
        case .keepHistory: return "Choose how long old entries are kept"
        }
    }

    public var systemImage: String {
        switch self {
        case .dailyPrompts: return "clock"
        case .appleHealth: return "heart"
        case .healthRelay: return "arrow.triangle.2.circlepath"
        case .communitySharing: return "person.2"
        case .keepHistory: return "calendar"
        }
    }

    /// Always false: a placeholder is never available in this build.
    public var isAvailable: Bool { false }
}

/// Settings, interim shell: the way to the daily goals and to the units, data and privacy screen, and
/// the placeholder rows the design lists. A later package replaces the two links with real sections.
public struct AppSettingsView: View {
    private let goals: GoalsViewModel?
    private let connections: ConnectionsPrivacyViewModel?
    private let now: () -> Date
    @State private var showingGoals: Bool

    /// - Parameter opensGoals: opens the daily goals as soon as the screen appears, which is how Today's
    ///   "Edit goals" link gets there.
    public init(
        goals: GoalsViewModel? = nil, connections: ConnectionsPrivacyViewModel? = nil,
        now: @escaping () -> Date = { Date() }, opensGoals: Bool = false
    ) {
        self.goals = goals
        self.connections = connections
        self.now = now
        _showingGoals = State(initialValue: opensGoals && goals != nil)
    }

    public var body: some View {
        List {
            if goals != nil {
                Section("Your goals") {
                    Button {
                        showingGoals = true
                    } label: {
                        linkLabel("Daily goals")
                    }
                    .accessibilityLabel("Daily goals")
                    .accessibilityHint("Set what you are aiming for in protein, sugar, salt and the rest")
                }
            }
            if let connections {
                Section("Units, data and privacy") {
                    NavigationLink {
                        ConnectionsPrivacyView(model: connections, now: now)
                    } label: {
                        Text("Units, data and privacy")
                            .font(.body)
                            .foregroundStyle(TokenColors.textPrimary)
                    }
                    .accessibilityLabel("Units, data and privacy")
                    .accessibilityHint("Choose units, export your journal and read what data leaves this device")
                }
            }
            Section("Coming later") {
                ForEach(SettingsPlaceholder.allCases, id: \.title) { placeholder in
                    placeholderRow(placeholder)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Settings")
        .navigationDestination(isPresented: $showingGoals) {
            if let goals {
                GoalsView(model: goals)
            }
        }
    }

    private func linkLabel(_ title: String) -> some View {
        HStack {
            Text(title).font(.body).foregroundStyle(TokenColors.textPrimary)
            Spacer(minLength: DesignSpacing.s)
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(TokenColors.textSecondary)
                .accessibilityHidden(true)
        }
    }

    private func placeholderRow(_ placeholder: SettingsPlaceholder) -> some View {
        HStack(spacing: DesignSpacing.m) {
            Image(systemName: placeholder.systemImage)
                .foregroundStyle(TokenColors.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                Text(placeholder.title).font(.body).foregroundStyle(TokenColors.textPrimary)
                Text(placeholder.detail).font(.footnote).foregroundStyle(TokenColors.textSecondary)
            }
            Spacer(minLength: DesignSpacing.s)
            LaterBadge()
        }
        .accessibilityElement(children: .combine)
        .laterPlaceholder()
    }
}
