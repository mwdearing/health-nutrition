import SwiftUI
import UniformTypeIdentifiers

public struct AppSettingsView: View {
    private let goals: GoalsViewModel?
    private let connections: ConnectionsPrivacyViewModel?
    private let reminders: ReminderController?
    private let now: () -> Date
    private let opensGoals: Bool
    private let onShowWelcome: (() -> Void)?

    public init(
        goals: GoalsViewModel? = nil, connections: ConnectionsPrivacyViewModel? = nil,
        reminders: ReminderController? = nil,
        now: @escaping () -> Date = { Date() }, opensGoals: Bool = false,
        onShowWelcome: (() -> Void)? = nil
    ) {
        self.goals = goals
        self.connections = connections
        self.reminders = reminders
        self.now = now
        self.opensGoals = opensGoals
        self.onShowWelcome = onShowWelcome
    }

    public var body: some View {
        if let connections {
            SettingsContent(model: AppSettingsViewModel(connections: connections, goals: goals, reminders: reminders),
                            now: now, opensGoals: opensGoals, onShowWelcome: onShowWelcome)
        }
    }
}

private struct SettingsContent: View {
    @StateObject private var model: AppSettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var waterFocused: Bool
    @State private var showingGoals: Bool
    @State private var isImporting = false
    @State private var confirmingErase = false
    private let now: () -> Date
    private let onShowWelcome: (() -> Void)?

    init(
        model: AppSettingsViewModel, now: @escaping () -> Date, opensGoals: Bool,
        onShowWelcome: (() -> Void)? = nil
    ) {
        _model = StateObject(wrappedValue: model)
        _showingGoals = State(initialValue: opensGoals && model.goals != nil)
        self.now = now
        self.onShowWelcome = onShowWelcome
    }

    private var connections: ConnectionsPrivacyViewModel { model.connections }

    var body: some View {
        Form {
            Section {
                if model.goals != nil {
                    Button { self.showingGoals = true } label: {
                        HStack {
                            Text("Daily goals")
                            Spacer()
                            Text(model.goalsSetText).foregroundStyle(TokenColors.textSecondary)
                            Image(systemName: "chevron.right").accessibilityHidden(true)
                        }
                    }
                }
            }
            Section("Units and logging") {
                Picker("Units", selection: $model.unitSystem) {
                    Text("Metric").tag(UnitSystem.metric)
                    Text("US").tag(UnitSystem.usCustomary)
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Quick water amount")
                    TextField(connections.quickWaterUnitSymbol, text: $model.quickWaterText)
                        .multilineTextAlignment(.trailing)
                        .focused($waterFocused)
                        .accessibilityLabel("Quick water amount in \(connections.quickWaterUnitSymbol)")
                        .onSubmit { self.model.commitQuickWater() }
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Text(connections.quickWaterUnitSymbol)
                }
                Text(model.quickWaterHelper).font(.footnote).foregroundStyle(TokenColors.textSecondary)
                if let error = model.quickWaterError {
                    InlineNotice(error, tone: .failed)
                }
                reminderRows
            }
            Section("Connections") {
                HStack { placeholderText("appleHealth"); Spacer(); LaterBadge() }
                    .disabled(true).accessibilityValue("Not available yet")
                HStack { placeholderText("healthRelay"); Spacer(); LaterBadge() }
                    .disabled(true).accessibilityValue("Not available yet")
            }
            Section("Privacy") {
                NavigationLink {
                    ConnectionsPrivacyView(model: connections, now: now)
                } label: {
                    Text(model.privacyStatement)
                }
                Toggle(isOn: .constant(false)) {
                    VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                        HStack { Text("Share product labels with the community"); LaterBadge() }
                        Text(placeholderDetail("communitySharing"))
                            .font(.footnote).foregroundStyle(TokenColors.textSecondary)
                    }
                }
                .disabled(true).accessibilityValue("Not available yet")
                Link("Privacy policy", destination: URL(string: "https://github.com/mwdearing/health-nutrition/blob/main/PRIVACY.md")!)
            }
            Section {
                Button(ConnectionsPrivacyViewModel.exportButtonTitle) {
                    self.connections.export(now: self.now())
                }
                .disabled(!connections.canExport)
                .accessibilityHint("Writes a copy on this device. Nothing is sent until you share it.")
                if let url = connections.exportFileURL {
                    ShareLink(ConnectionsPrivacyViewModel.shareButtonTitle, item: url)
                    Text("Exported \(connections.entryCount) entries.").font(.footnote)
                }
                Button("Restore from an export") { self.isImporting = true }
                    .accessibilityHint("Restores an export only while this phone's journal is empty.")
                if let message = connections.importMessage {
                    Text(message).font(.footnote)
                        .foregroundStyle(connections.importState == .failed ? TokenColors.error : TokenColors.textSecondary)
                }
                HStack { placeholderText("keepHistory"); Spacer(); LaterBadge() }
                    .disabled(true).accessibilityValue("Not available yet")
                if connections.canEraseAll {
                    Button(ConnectionsPrivacyViewModel.eraseButtonTitle, role: .destructive) {
                        self.confirmingErase = true
                    }
                }
                if let error = connections.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(TokenColors.error)
                }
            } header: {
                Text("Your data")
            } footer: {
                Text(ConnectionsPrivacyViewModel.eraseFooterMessage).font(.footnote)
            }
            Section("About") {
                HStack { Text("Version"); Spacer(); Text(model.versionText) }
                if let onShowWelcome {
                    Button("Show welcome again") { onShowWelcome() }
                } else {
                    HStack { Text("Show welcome again"); Spacer(); LaterBadge() }
                        .disabled(true).accessibilityValue("Not available yet")
                }
                NavigationLink("Licences") {
                    Form {
                        Text(model.openFoodFactsAttribution)
                        Link("Open Database Licence", destination: URL(string: "https://opendatacommons.org/licenses/odbl/1-0/")!)
                    }
                    .navigationTitle("Licences")
                }
            }
        }
        .font(.body)
        .foregroundStyle(TokenColors.textPrimary)
        .tint(TokenColors.accent)
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { self.dismiss() }
            }
        }
        .navigationDestination(isPresented: $showingGoals) {
            if let goals = model.goals { GoalsView(model: goals) }
        }
        .onAppear { self.model.load() }
        .onChange(of: waterFocused) { _, focused in
            if !focused { self.model.commitQuickWater() }
        }
        .onChange(of: connections.eraseGeneration) { _, _ in
            self.model.load()
            self.model.reminders?.refreshFromPreferences()
        }
        .confirmationDialog(
            ConnectionsPrivacyViewModel.eraseConfirmationTitle, isPresented: $confirmingErase,
            titleVisibility: .visible
        ) {
            Button(ConnectionsPrivacyViewModel.eraseButtonTitle, role: .destructive) {
                self.connections.eraseAllData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ConnectionsPrivacyViewModel.eraseConfirmationMessage)
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json], allowsMultipleSelection: false) {
            self.importPickedFile($0)
        }
        .onDisappear {
            self.connections.clearExport()
            self.connections.clearImport()
        }
    }

    /// The daily reminder: the switch, the time while it is on, the footnote and any notice. Shown only
    /// where a controller is wired in.
    @ViewBuilder
    private var reminderRows: some View {
        if let reminders = model.reminders {
            Toggle("Daily reminder", isOn: Binding(
                get: { reminders.isOn },
                set: { on in Task { await reminders.setOn(on) } }
            ))
            if reminders.isOn {
                DatePicker("Reminder time", selection: Binding(
                    get: { Self.date(for: reminders.time) },
                    set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        let time = ReminderTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
                        Task { await reminders.setTime(time) }
                    }
                ), displayedComponents: .hourAndMinute)
            }
            Text("A reminder on this phone at the time you choose. Nothing is sent anywhere.")
                .font(.footnote).foregroundStyle(TokenColors.textSecondary)
            if let message = reminders.message {
                InlineNotice(message, tone: .failed)
            }
        }
    }

    /// A fixed day with no daylight-saving change in the stored clock time, for the time picker to show. Using
    /// today would move a time in a skipped hour on a spring-forward day.
    private static func date(for time: ReminderTime) -> Date {
        var parts = DateComponents(year: 2001, month: 1, day: 15, hour: time.hour, minute: time.minute)
        parts.calendar = Calendar.current
        return parts.date ?? Date()
    }

    /// Looks a placeholder row up by its id, so the rows can change without shifting the others.
    private func placeholderText(_ id: String) -> some View {
        let row = model.placeholderRows.first { $0.id == id }
        return VStack(alignment: .leading, spacing: DesignSpacing.xs) {
            Text(row?.title ?? "")
            Text(row?.detail ?? "").font(.footnote).foregroundStyle(TokenColors.textSecondary)
        }
    }

    private func placeholderDetail(_ id: String) -> String {
        model.placeholderRows.first { $0.id == id }?.detail ?? ""
    }

    private func importPickedFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            connections.clearImport()
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            connections.importCouldNotReadFile()
            return
        }
        connections.importJournal(data: data)
    }
}
