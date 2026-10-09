import SwiftUI
import UniformTypeIdentifiers

public struct AppSettingsView: View {
    private let goals: GoalsViewModel?
    private let connections: ConnectionsPrivacyViewModel?
    private let now: () -> Date
    private let opensGoals: Bool
    private let onShowWelcome: (() -> Void)?

    public init(
        goals: GoalsViewModel? = nil, connections: ConnectionsPrivacyViewModel? = nil,
        now: @escaping () -> Date = { Date() }, opensGoals: Bool = false,
        onShowWelcome: (() -> Void)? = nil
    ) {
        self.goals = goals
        self.connections = connections
        self.now = now
        self.opensGoals = opensGoals
        self.onShowWelcome = onShowWelcome
    }

    public var body: some View {
        if let connections {
            SettingsContent(model: AppSettingsViewModel(connections: connections, goals: goals),
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
                HStack { placeholderText(0); Spacer(); LaterBadge() }
                    .disabled(true).accessibilityValue("Not available yet")
            }
            Section("Connections") {
                HStack { placeholderText(1); Spacer(); LaterBadge() }
                    .disabled(true).accessibilityValue("Not available yet")
                HStack { placeholderText(2); Spacer(); LaterBadge() }
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
                        Text(model.placeholderRows[3].detail)
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
                HStack { placeholderText(4); Spacer(); LaterBadge() }
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
        .onChange(of: connections.eraseGeneration) { _, _ in self.model.load() }
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

    private func placeholderText(_ index: Int) -> some View {
        let row = model.placeholderRows[index]
        return VStack(alignment: .leading, spacing: DesignSpacing.xs) {
            Text(row.title)
            Text(row.detail).font(.footnote).foregroundStyle(TokenColors.textSecondary)
        }
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
