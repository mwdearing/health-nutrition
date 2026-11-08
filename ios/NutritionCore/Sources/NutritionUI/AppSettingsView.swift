import SwiftUI
import NutritionJournal
import UniformTypeIdentifiers

public struct AppSettingsView: View {
    private let goals: GoalsViewModel?
    private let connections: ConnectionsPrivacyViewModel?
    private let reminders: ReminderController?
    private let account: AccountViewModel?
    private let appleHealth: AppleHealthConnectionViewModel?
    private let medicationLog: MedicationLogViewModel?
    private let now: () -> Date
    private let opensGoals: Bool
    private let onShowWelcome: (() -> Void)?
    private let onShowGettingStarted: (() -> Void)?
    private let gettingStarted: FirstDayChecklistModel?

    /// - Parameter medicationLog: the medication log whose switch sits under "Units and logging". Nil leaves the
    ///   switch out.
    public init(
        goals: GoalsViewModel? = nil, connections: ConnectionsPrivacyViewModel? = nil,
        reminders: ReminderController? = nil,
        account: AccountViewModel? = nil,
        appleHealth: AppleHealthConnectionViewModel? = nil,
        medicationLog: MedicationLogViewModel? = nil,
        now: @escaping () -> Date = { Date() }, opensGoals: Bool = false,
        onShowWelcome: (() -> Void)? = nil,
        onShowGettingStarted: (() -> Void)? = nil,
        gettingStarted: FirstDayChecklistModel? = nil
    ) {
        self.goals = goals
        self.connections = connections
        self.reminders = reminders
        self.account = account
        self.appleHealth = appleHealth
        self.medicationLog = medicationLog
        self.now = now
        self.opensGoals = opensGoals
        self.onShowWelcome = onShowWelcome
        self.onShowGettingStarted = onShowGettingStarted
        self.gettingStarted = gettingStarted
    }

    public var body: some View {
        if let connections {
            SettingsContent(model: AppSettingsViewModel(connections: connections, goals: goals, reminders: reminders, account: account),
                            appleHealth: appleHealth, medicationLog: medicationLog,
                            now: now, opensGoals: opensGoals, onShowWelcome: onShowWelcome,
                            onShowGettingStarted: onShowGettingStarted, gettingStarted: gettingStarted)
        }
    }
}

/// The Medication log switch and its footnote. Observes the model so the switch redraws when it changes.
private struct MedicationLogSwitchRow: View {
    @ObservedObject var model: MedicationLogViewModel

    var body: some View {
        Toggle("Medication log", isOn: Binding(
            get: { model.isOn },
            set: { model.isOn = $0 }
        ))
        Text("Turning it off hides the log and keeps the data.")
            .font(.footnote).foregroundStyle(TokenColors.textSecondary)
        Text(MedicationLogViewModel.notice)
            .font(.footnote).foregroundStyle(TokenColors.textSecondary)
    }
}

/// The Apple Health connection: what Health currently allows, and the one thing a person can do about
/// it. The status is read again whenever the row appears or the app returns to the foreground, because
/// the answer can be changed in the Health app while this one is in the background.
private struct AppleHealthRows: View {
    @ObservedObject var model: AppleHealthConnectionViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
            HStack(spacing: DesignSpacing.m) {
                IconWell(systemName: "heart.text.square", size: .small)
                Text(AppleHealthConnectionViewModel.title)
                Spacer()
                Text(model.statusText).foregroundStyle(TokenColors.textSecondary)
            }
            Text(model.detailText).font(.footnote).foregroundStyle(TokenColors.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .onAppear { self.model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { self.model.refresh() }
        }
        if let action = model.actionTitle {
            Button(action) {
                if model.opensHealthSettings {
                    openURL(URL(string: "x-apple-health://")!)
                } else {
                    Task { await self.model.connect() }
                }
            }
            .disabled(!model.canAct)
        }
    }
}

private struct SettingsContent: View {
    @StateObject private var model: AppSettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var waterFocused: Bool
    @State private var showingGoals: Bool
    @State private var showingPrivacy = false
    @State private var showingLicenses = false
    @State private var isImporting = false
    @State private var isReadingImport = false
    @State private var importReadToken: JournalImportReadToken?
    @State private var importReadGate = JournalImportReadGate()
    @State private var importReadTask: Task<Data, Error>?
    private let appleHealth: AppleHealthConnectionViewModel?
    private let medicationLog: MedicationLogViewModel?
    private let now: () -> Date
    private let onShowWelcome: (() -> Void)?
    private let onShowGettingStarted: (() -> Void)?
    private let gettingStarted: FirstDayChecklistModel?

    init(
        model: AppSettingsViewModel, appleHealth: AppleHealthConnectionViewModel? = nil,
        medicationLog: MedicationLogViewModel? = nil,
        now: @escaping () -> Date, opensGoals: Bool,
        onShowWelcome: (() -> Void)? = nil,
        onShowGettingStarted: (() -> Void)? = nil,
        gettingStarted: FirstDayChecklistModel? = nil
    ) {
        _model = StateObject(wrappedValue: model)
        self.appleHealth = appleHealth
        self.medicationLog = medicationLog
        _showingGoals = State(initialValue: opensGoals && model.goals != nil)
        self.now = now
        self.onShowWelcome = onShowWelcome
        self.onShowGettingStarted = onShowGettingStarted
        self.gettingStarted = gettingStarted
    }

    private var connections: ConnectionsPrivacyViewModel { model.connections }

    var body: some View {
        Form {
            Section {
                if model.goals != nil {
                    SettingsGoalsCard(summary: model.goalsSummary) { self.showingGoals = true }
                    .accessibilityIdentifier("Daily goals")
                    .listRowBackground(TokenColors.hero)
                }
            }
            if let account = model.account {
                AccountSectionView(model: account)
            }
            Section("Units and logging") {
                HStack(spacing: DesignSpacing.m) {
                    IconWell(systemName: "ruler", size: .small)
                    Picker("Units", selection: $model.unitSystem) {
                        Text("Metric").tag(UnitSystem.metric)
                        Text("US").tag(UnitSystem.usCustomary)
                    }
                    .pickerStyle(.segmented)
                }
                LabeledField("Quick water amount", focus: $waterFocused) { focus in
                    HStack {
                        TextField(text: $model.quickWaterText, prompt: Text("For example, 250")) {
                            Text("Quick water amount")
                        }
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .focused(focus)
                        .accessibilityLabel("Quick water amount in \(connections.quickWaterUnitSymbol)")
                        .onSubmit { self.model.commitQuickWater() }
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        Text(connections.quickWaterUnitSymbol)
                    }
                }
                Text(model.quickWaterHelper).font(.footnote).foregroundStyle(TokenColors.textSecondary)
                if let error = model.quickWaterError {
                    InlineNotice(error, tone: .failed)
                }
                reminderRows
                if let medicationLog {
                    MedicationLogSwitchRow(model: medicationLog)
                }
            }
            if appleHealth != nil {
                Section("Connections") {
                    if let appleHealth {
                        AppleHealthRows(model: appleHealth)
                    }
                }
            }
            Section("Privacy") {
                Button { self.showingPrivacy = true } label: {
                    HStack(spacing: DesignSpacing.m) {
                        IconWell(systemName: "lock", size: .small)
                        Text(model.privacyStatement).multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }
                }
                Link("Privacy policy", destination: URL(string: "https://github.com/mwdearing/health-nutrition/blob/main/PRIVACY.md")!)
            }
            Section {
                Button {
                    self.connections.export(now: self.now())
                } label: {
                    HStack(spacing: DesignSpacing.m) {
                        IconWell(systemName: "square.and.arrow.up", size: .small)
                        Text(ConnectionsPrivacyViewModel.exportButtonTitle)
                    }
                }
                .disabled(!connections.canExport)
                .accessibilityHint("Writes a copy on this device. Nothing is sent until you share it.")
                if let url = connections.exportFileURL {
                    ShareLink(ConnectionsPrivacyViewModel.shareButtonTitle, item: url)
                    Text(ConnectionsPrivacyViewModel.exportedText(count: connections.entryCount)).font(.footnote)
                }
                Button("Restore from an export") { self.isImporting = true }
                    .accessibilityHint("Restores an export only while this device's journal is empty.")
                    .disabled(isReadingImport || connections.isImporting || connections.isErasing)
                Text(ConnectionsPrivacyViewModel.restoreAddsNotice).font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
                if isReadingImport || connections.isImporting {
                    ProgressView(isReadingImport ? "Reading export…" : "Restoring export…")
                }
                if isReadingImport {
                    Button("Cancel import", role: .cancel) { self.cancelFileImport() }
                }
                if let message = connections.importMessage {
                    Text(message).font(.footnote)
                        .foregroundStyle(connections.importState == .failed ? TokenColors.error : TokenColors.textSecondary)
                }
                if let warning = connections.incompleteRestoreWarning,
                   warning != connections.importMessage {
                    Text(warning).font(.footnote).foregroundStyle(TokenColors.error)
                }
                if connections.canEraseAll {
                    Button(ConnectionsPrivacyViewModel.eraseButtonTitle, role: .destructive) {
                        self.connections.requestErase()
                    }
                }
                if let error = connections.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(TokenColors.error)
                }
                if connections.eraseRetryAvailable {
                    Button("Retry") { self.connections.requestErase() }
                        .disabled(self.connections.isErasing)
                }
            } header: {
                Text("Your data")
            } footer: {
                Text(ConnectionsPrivacyViewModel.eraseFooterMessage).font(.footnote)
            }
            Section("About") {
                HStack(spacing: DesignSpacing.m) {
                    IconWell(systemName: "info.circle", size: .small)
                    Text("Version"); Spacer(); Text(model.versionText)
                }
                if let onShowWelcome {
                    Button("Show welcome again") { onShowWelcome() }
                }
                if let gettingStarted {
                    GettingStartedRow(model: gettingStarted, onClosed: onShowGettingStarted)
                }
                Button { self.showingLicenses = true } label: {
                    HStack(spacing: DesignSpacing.m) {
                        IconWell(systemName: "doc.text", size: .small)
                        Text("Licenses")
                        Spacer()
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }
                }
            }
        }
        .font(.body)
        .foregroundStyle(TokenColors.textPrimary)
        .tint(TokenColors.accent)
        .scrollContentBackground(.hidden)
        .background(TokenColors.page)
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
        .navigationDestination(isPresented: $showingPrivacy) {
            ConnectionsPrivacyView(model: connections, now: now)
        }
        .navigationDestination(isPresented: $showingLicenses) {
            Form {
                Text(model.openFoodFactsAttribution)
                Link("Open Database License", destination: URL(string: "https://opendatacommons.org/licenses/odbl/1-0/")!)
                Text(model.usdaAttribution)
                Link("USDA FoodData Central", destination: URL(string: "https://fdc.nal.usda.gov/")!)
            }
            .scrollContentBackground(.hidden)
            .background(TokenColors.page)
            .navigationTitle("Licenses")
        }
        .accountPresentations(model.account)
        .onAppear { self.model.load() }
        .onChange(of: waterFocused) { _, focused in
            if !focused { self.model.commitQuickWater() }
        }
        .onChange(of: connections.eraseGeneration) { _, _ in
            self.model.load()
            self.model.reminders?.refreshFromPreferences()
            self.model.account?.refreshAfterErase()
        }
        .onChange(of: connections.isErasing) { _, isErasing in
            if isErasing { self.cancelFileImport() }
        }
        .confirmationDialog(
            ConnectionsPrivacyViewModel.eraseConfirmationTitle,
            isPresented: Binding(
                get: { self.connections.eraseConfirmationPending },
                set: { if !$0 { self.connections.cancelEraseRequest() } }),
            titleVisibility: .visible
        ) {
            Button(ConnectionsPrivacyViewModel.eraseButtonTitle, role: .destructive) {
                Task { _ = await self.connections.confirmErase() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ConnectionsPrivacyViewModel.eraseConfirmationMessage)
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json], allowsMultipleSelection: false) {
            self.importPickedFile($0)
        }
        .onDisappear {
            // A file read still running stops whenever the form goes, pushed over or not: the sheet can close
            // from a pushed screen, and nothing else could cancel the read then. There is no result yet to lose.
            if self.isReadingImport { self.cancelFileImport() }
            // A screen pushed over this form (Privacy, Licenses, Daily goals) also disappears it. That must not
            // delete the export or wipe a finished import result; only leaving Settings does. A sheet dismissed
            // from inside a pushed screen never reaches here, so the host clears on dismissal too.
            guard !(self.showingGoals || self.showingPrivacy || self.showingLicenses) else { return }
            self.cancelFileImport()
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
            Text("A reminder on this device at the time you choose. Nothing is sent anywhere.")
                .font(.footnote).foregroundStyle(TokenColors.textSecondary)
            if let message = reminders.message {
                InlineNotice(message, tone: .failed)
            }
            if let custom = reminders.customReminders {
                customReminderRows(custom)
            }
        }
    }

    /// One water and one supplement reminder: a switch each, and a time of day while it is on.
    @ViewBuilder
    private func customReminderRows(_ controller: CustomReminderController) -> some View {
        ForEach(CustomReminderKind.allCases, id: \.self) { kind in
            let reminder = controller.reminders.first { $0.kind == kind }
            Toggle("\(kind.title) reminder", isOn: Binding(
                get: { reminder?.isOn ?? false },
                set: { on in
                    Task {
                        if let reminder { await controller.setOn(on, id: reminder.id) }
                        else if on { await controller.add(kind) }
                    }
                }
            ))
            if let reminder, reminder.isOn {
                DatePicker("\(kind.title) time", selection: Binding(
                    get: { Self.date(for: reminder.time) },
                    set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        let time = ReminderTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
                        Task { await controller.setTime(time, id: reminder.id) }
                    }
                ), displayedComponents: .hourAndMinute)
            }
        }
        if let message = controller.message {
            InlineNotice(message, tone: .failed)
        }
    }

    /// A fixed day with no daylight-saving change in the stored clock time, for the time picker to show. Using
    /// today would move a time in a skipped hour on a spring-forward day.
    private static func date(for time: ReminderTime) -> Date {
        var parts = DateComponents(year: 2001, month: 1, day: 15, hour: time.hour, minute: time.minute)
        parts.calendar = Calendar.current
        return parts.date ?? Date()
    }

    private func importPickedFile(_ result: Result<[URL], Error>) {
        cancelFileImport()
        guard case .success(let urls) = result, let url = urls.first else {
            connections.clearImport()
            return
        }
        let token = importReadGate.begin(eraseGeneration: connections.eraseGeneration)
        importReadToken = token
        isReadingImport = true
        let task = Task.detached(priority: .userInitiated) { () throws -> Data in
            try JournalImportFileReader.readScoped(url, limits: .default)
        }
        importReadTask = task
        Task { @MainActor in
            do {
                let data = try await task.value
                guard self.finishFileImport(token) else { return }
                self.connections.importJournal(data: data)
            } catch is CancellationError {
                guard self.finishFileImport(token) else { return }
                self.connections.clearImport()
            } catch JournalImportError.tooLarge {
                guard self.finishFileImport(token) else { return }
                self.connections.importFileTooLarge()
            } catch {
                guard self.finishFileImport(token) else { return }
                self.connections.importCouldNotReadFile()
            }
        }
    }

    private func finishFileImport(_ token: JournalImportReadToken) -> Bool {
        guard importReadToken == token else { return false }
        let accepted = importReadGate.finish(
            token, currentEraseGeneration: connections.eraseGeneration, isErasing: connections.isErasing)
        importReadToken = nil
        importReadTask = nil
        isReadingImport = false
        if !accepted { connections.clearImport() }
        return accepted
    }

    private func cancelFileImport() {
        importReadTask?.cancel()
        importReadTask = nil
        if let importReadToken { importReadGate.cancel(importReadToken) }
        importReadToken = nil
        isReadingImport = false
        connections.clearImport()
    }
}

/// The Settings row that brings the first-day checklist back. It shows only while the card is hidden and a
/// real step is left, and it re-renders when the checklist changes (approved wording, #516).
private struct GettingStartedRow: View {
    @ObservedObject var model: FirstDayChecklistModel
    let onClosed: (() -> Void)?

    var body: some View {
        if model.canShowAgain {
            Button("Show getting started") {
                model.showAgain()
                onClosed?()
            }
        }
    }
}
