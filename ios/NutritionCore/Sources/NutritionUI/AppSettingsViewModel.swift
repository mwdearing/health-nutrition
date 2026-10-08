import Combine
import Foundation

public struct SettingsPlaceholderRow: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let detail: String
    public let issueReference: String
    public var isEnabled: Bool { false }
}

/// Settings owns presentation only; the existing models retain every store operation.
@MainActor
public final class AppSettingsViewModel: ObservableObject {
    public let connections: ConnectionsPrivacyViewModel
    public let goals: GoalsViewModel?
    public let versionText: String
    private var observations: Set<AnyCancellable> = []

    public init(
        connections: ConnectionsPrivacyViewModel, goals: GoalsViewModel? = nil,
        version: String? = nil, build: String? = nil, bundle: Bundle = .main
    ) {
        self.connections = connections
        self.goals = goals
        let version = version ?? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = build ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        self.versionText = "\(version) (\(build))"
        connections.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &observations)
        goals?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &observations)
    }

    public func load() { goals?.load() }

    public var goalsSetText: String {
        let count = goals?.rows.filter { $0.targetText != nil }.count ?? 0
        return count == 0 ? "None set" : "\(count) set"
    }

    public var unitSystem: UnitSystem {
        get { connections.unitSystem }
        set { connections.unitSystem = newValue }
    }

    public var quickWaterText: String {
        get { connections.quickWaterText }
        set { connections.quickWaterText = newValue }
    }

    @discardableResult
    public func commitQuickWater() -> Bool { connections.saveQuickWaterAmount() }
    public var quickWaterHelper: String { connections.quickWaterEquivalenceText }
    public var quickWaterError: String? { connections.quickWaterError }
    public let privacyStatement = "Your journal stays on this phone. Nothing is sent anywhere unless you export it."
    public let openFoodFactsAttribution = "Open Food Facts — database available under the Open Database Licence (ODbL)."

    public let placeholderRows: [SettingsPlaceholderRow] = [
        SettingsPlaceholderRow(id: "dailyPrompts", title: "Daily prompts", detail: "Choose daily prompts in a later release.", issueReference: "#98"),
        SettingsPlaceholderRow(id: "appleHealth", title: "Apple Health", detail: "Not connected", issueReference: "#103"),
        SettingsPlaceholderRow(id: "healthRelay", title: "HealthRelay", detail: "Not connected", issueReference: "HealthRelay #123"),
        SettingsPlaceholderRow(id: "communitySharing", title: "Share product labels with the community", detail: "Only product facts would ever be shared, never amounts, times or identity.", issueReference: "Needs issue: community sharing"),
        SettingsPlaceholderRow(id: "keepHistory", title: "Keep history for", detail: "History is kept until you erase it.", issueReference: "#104"),
    ]
}
