import AppKit
import SkillSelectorCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct CustomAgentEditorState {
    var selectedAgentID: String?
    var agentName = ""
    var globalRoots = ""
    var projectPatterns = ""
    var entryFilename = "SKILL.md"

    mutating func beginEditing(_ definition: AgentDefinition) {
        selectedAgentID = definition.id
        agentName = definition.displayName
        globalRoots = definition.globalRoots.joined(separator: ", ")
        projectPatterns = definition.projectPatterns.joined(separator: ", ")
        entryFilename = definition.entryFilename
    }

    mutating func save(using model: AppModel) throws {
        try model.saveCustomAgent(
            displayName: agentName,
            globalRoots: splitPaths(globalRoots),
            projectPatterns: splitPaths(projectPatterns),
            entryFilename: entryFilename,
            existingID: selectedAgentID
        )
        reset()
    }

    mutating func reset() {
        selectedAgentID = nil
        agentName = ""
        globalRoots = ""
        projectPatterns = ""
        entryFilename = "SKILL.md"
    }

    mutating func resetIfEditing(removedID: String) {
        guard selectedAgentID == removedID else { return }
        reset()
    }

    private func splitPaths(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: ",\n"))
    }
}

enum SettingsTab: Hashable {
    case general
    case directories
    case about
}

/// The settings window from design/screens/settings.html: a tab bar with
/// 通用 / 目录授权 / 关于 panes built from `.group` cards.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("SkillSelector.preferredLanguage") private var preferredLanguage: String?
    @State private var activeTab: SettingsTab = .general
    @State private var customAgentEditor = CustomAgentEditorState()
    @State private var settingsError: String?
    @State private var exportStatus: String?
    @State private var editingRootID: String?
    @State private var editingRootName: String = ""
    @State private var showCustomAgentSheet = false
    @State private var showDiagnosticsViewer = false
    @State private var patternDryRunResult: PatternDryRunReport?
    @State private var isPatternDryRunning = false

    init(initialTab: SettingsTab = .general) {
        _activeTab = State(initialValue: initialTab)
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            tabBar
            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch activeTab {
                    case .general: generalPane
                    case .directories: directoriesPane
                    case .about: aboutPane
                    }
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 48)
            }
        }
        .frame(width: 720, height: 780)
        .background(AppTheme.background)
        .background(SettingsWindowTitle(title: L10n.string("Settings")))
        .languageReloading()
        .themedAppearance()
        .sheet(isPresented: $showCustomAgentSheet) {
            customAgentSheet
        }
        .sheet(isPresented: $showDiagnosticsViewer) {
            DiagnosticsViewerView(
                input: model.redactedDiagnostics(),
                onExport: {
                    showDiagnosticsViewer = false
                    exportDiagnostics()
                }
            )
        }
        .alert(
            L10n.string("Settings Error"),
            isPresented: Binding(
                get: { settingsError != nil },
                set: { if !$0 { settingsError = nil } }
            )
        ) {
            Button(L10n.string("OK")) { settingsError = nil }
        } message: {
            Text(verbatim: settingsError ?? "")
        }
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 2) {
            tabButton(.general, title: L10n.string("General"), icon: "gearshape")
            tabButton(.directories, title: L10n.string("Directory Authorization"), icon: "folder")
            tabButton(.about, title: L10n.string("About"), icon: "info.circle")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(AppTheme.surfaceWarm)
    }

    private func tabButton(_ tab: SettingsTab, title: String, icon: String) -> some View {
        Button {
            activeTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                Text(verbatim: title)
                    .font(AppTheme.body(11))
                    .lineLimit(1)
            }
            .foregroundStyle(activeTab == tab ? AppTheme.accentActive : AppTheme.foregroundSecondary)
            .frame(width: 76)
            .padding(.vertical, 7)
            .background(activeTab == tab ? AppTheme.accentTint : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsTabHoverStyle(isActive: activeTab == tab))
        .accessibilityAddTraits(activeTab == tab ? .isSelected : [])
        .accessibilityLabel(title)
    }

    // MARK: 通用 pane

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupTitle(L10n.string("Scan"))
            SettingsGroup {
                SettingsRow(
                    label: L10n.string("Auto-scan Home Directory"),
                    sub: L10n.string("Scan agent skill folders in the home directory when the app launches.")
                ) {
                    ThemeSwitch(
                        isOn: Binding(
                            get: { model.autoScanHome },
                            set: { model.autoScanHome = $0 }
                        ),
                        accessibilityLabel: L10n.string("Auto-scan Home Directory")
                    )
                }
            }

            groupTitle(L10n.string("Display"))
                .padding(.top, 4)
            SettingsGroup {
                languageSegment
            }

            groupTitle(L10n.string("Legacy Agents"))
                .padding(.top, 4)
            SettingsGroup {
                ForEach(model.legacyAgentDefinitions) { agent in
                    SettingsRow(label: agent.displayName) {
                        ThemeSwitch(
                            isOn: Binding(
                                get: { model.manuallyEnabledAgentIDs.contains(agent.id) },
                                set: { model.setLegacyAgent(agent.id, enabled: $0) }
                            ),
                            accessibilityLabel: agent.displayName
                        )
                    }
                }
                SettingsRow(
                    label: L10n.string("Legacy Agent Hint"),
                    hint: true
                )
            }

            groupTitle(L10n.string("Data"))
                .padding(.top, 4)
            SettingsGroup {
                SettingsRow(
                    label: L10n.string("Skill Index"),
                    sub: L10n.string("Skill Index Sub")
                )
                SettingsRow(
                    label: L10n.string("Export Diagnostics Report"),
                    sub: L10n.string("Export Diagnostics Sub")
                ) {
                    HStack(spacing: 10) {
                        Button(L10n.string("View…"), action: { showDiagnosticsViewer = true })
                            .buttonStyle(SettingsButtonStyle())
                            .help(L10n.string("View Redacted Diagnostics"))
                        Button(L10n.string("Export…"), action: exportDiagnostics)
                            .buttonStyle(SettingsButtonStyle())
                            .help(L10n.string("Export Redacted Diagnostics"))
                    }
                }
            }
            if let exportStatus {
                Text(verbatim: exportStatus)
                    .font(AppTheme.body(12))
                    .foregroundStyle(AppTheme.muted)
                    .padding(.top, 8)
            }
        }
    }

    /// `.seg` — the three-option language segment with radio dots.
    private var languageSegment: some View {
        HStack(spacing: 3) {
            languageOption(L10n.string("Follow System"), value: nil)
            languageOption("简体中文", value: "zh-Hans")
            languageOption("English", value: "en")
        }
        .padding(6)
    }

    private func languageOption(_ title: String, value: String?) -> some View {
        let isSelected = preferredLanguage == value
        return Button {
            preferredLanguage = value
            L10n.setLanguage(value)
        } label: {
            HStack(spacing: 7) {
                RadioDot(isOn: isSelected)
                Text(verbatim: title)
                    .font(AppTheme.body(12.5, weight: .medium))
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .background(isSelected ? AppTheme.accentTint : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? AppTheme.accentTintBorder : AppTheme.borderSoft, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(title)
    }

    // MARK: 目录授权 pane

    private var directoriesPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupTitle(L10n.string("Authorized Directories"))
            if model.authorizedRoots.isEmpty {
                SettingsGroup {
                    SettingsRow(label: L10n.string("No directories authorized."))
                }
            } else {
                SettingsGroup {
                    ForEach(model.authorizedRoots) { root in
                        authorizedRootRow(root)
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    importProject()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12))
                        Text(verbatim: L10n.string("Add Project Folder…"))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(SettingsButtonStyle())
                .help(L10n.string("Import Project Directory"))
            }
            .padding(.top, 12)

            groupTitle(L10n.string("Custom Agent Directories"), spaced: true)
            SettingsGroup {
                ForEach(model.customAgentDefinitions) { agent in
                    customAgentRow(agent)
                }
                SettingsRow(
                    label: L10n.string("Custom Agent Hint"),
                    hint: true
                ) {
                    HStack(spacing: 10) {
                        Button(L10n.string("Add…")) {
                            customAgentEditor.reset()
                            patternDryRunResult = nil
                            showCustomAgentSheet = true
                        }
                        .buttonStyle(SettingsButtonStyle())
                        .help(L10n.string("Add Custom Agent"))
                        Button(L10n.string("Export…"), action: exportCustomAgents)
                            .buttonStyle(SettingsButtonStyle())
                            .help(L10n.string("Export Custom Agents"))
                            .disabled(model.customAgentDefinitions.isEmpty)
                        Button(L10n.string("Import…"), action: importCustomAgents)
                            .buttonStyle(SettingsButtonStyle())
                            .help(L10n.string("Import Custom Agents"))
                    }
                }
            }
        }
    }

    private func authorizedRootRow(_ root: AuthorizedRootSnapshot) -> some View {
        let isHome = root.kind == .home
        let isHealthy = !model.unhealthyRootIDs.contains(root.id)
        return SettingsRow(
            label: isHome ? L10n.string("User Home Directory") : root.displayName,
            sub: isHome
                ? L10n.string("Home Directory Sub")
                : root.url.path,
            subMonospaced: !isHome
        ) {
            HStack(spacing: 10) {
                if isHome {
                    Text(verbatim: "~")
                        .font(AppTheme.mono(11.5))
                        .foregroundStyle(AppTheme.muted)
                } else {
                    statusDot(L10n.string("Project"), color: AppTheme.meta)
                }
                statusDot(
                    L10n.string(isHealthy ? "Authorized" : "Needs Re-authorization"),
                    color: isHealthy ? AppTheme.success : AppTheme.warn
                )
                if !isHealthy {
                    Button(L10n.string("Re-authorize…")) {
                        reauthorize(root)
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .accessibilityLabel(L10n.string("Re-authorize Directory"))
                }
                if !isHome {
                    Button(L10n.string("Remove")) {
                        Task { await model.revokeAuthorization(id: root.id) }
                    }
                    .buttonStyle(SettingsDangerButtonStyle())
                    .accessibilityLabel(L10n.string("Revoke Authorization"))
                }
            }
        }
        .contextMenu {
            if editingRootID != root.id {
                Button(L10n.string("Rename")) {
                    editingRootID = root.id
                    editingRootName = root.customName ?? ""
                }
            }
            Button(L10n.string("Re-authorize Directory")) {
                reauthorize(root)
            }
            if isHome {
                Divider()
                Button(L10n.string("Revoke Authorization"), role: .destructive) {
                    Task { await model.revokeAuthorization(id: root.id) }
                }
            }
        }
    }

    private func customAgentRow(_ agent: AgentDefinition) -> some View {
        SettingsRow(
            label: agent.displayName,
            sub: agent.entryFilename,
            subMonospaced: true
        ) {
            HStack(spacing: 10) {
                Button(L10n.string("Remove")) {
                    do {
                        try model.removeCustomAgent(id: agent.id)
                        customAgentEditor.resetIfEditing(removedID: agent.id)
                    } catch {
                        settingsError = String(describing: error)
                    }
                }
                .buttonStyle(SettingsDangerButtonStyle())
                .accessibilityLabel(L10n.string("Remove Custom Agent"))
            }
        }
        .contextMenu {
            Button(L10n.string("Edit Custom Agent")) {
                customAgentEditor.beginEditing(agent)
                patternDryRunResult = nil
                showCustomAgentSheet = true
            }
        }
    }

    // MARK: 关于 pane

    private var aboutPane: some View {
        VStack(alignment: .center, spacing: 0) {
            AppIconView(size: 128)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
            LogoView(height: 40)
                .padding(.top, 16)
            Text(verbatim: L10n.string("Version Line", appVersion))
                .font(AppTheme.body(12.5))
                .foregroundStyle(AppTheme.muted)
                .padding(.top, 8)
            Text(verbatim: L10n.string("Tagline"))
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.foregroundSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            HStack(spacing: 16) {
                aboutLink(L10n.string("GitHub"), url: URL(string: "https://github.com/BlackArt40/SkillSelector"))
                aboutLink(L10n.string("Release Notes"), url: URL(string: "https://github.com/BlackArt40/SkillSelector/releases"))
                aboutLink(L10n.string("Apache License"), url: URL(string: "https://github.com/BlackArt40/SkillSelector/blob/main/LICENSE"))
            }
            .padding(.top, 16)

            SettingsGroup {
                SettingsRow(
                    label: L10n.string("Privacy"),
                    sub: L10n.string("Privacy Sub")
                )
                SettingsRow(
                    label: L10n.string("Signature"),
                    sub: L10n.string("Signature Sub")
                )
            }
            .padding(.top, 24)

            Text(verbatim: L10n.string("About Footer"))
                .font(AppTheme.body(11))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 24)
        }
        .frame(maxWidth: .infinity)
    }

    private func aboutLink(_ title: String, url: URL?) -> some View {
        Button {
            if let url {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Text(verbatim: title)
                .font(AppTheme.body(12.5))
                .foregroundStyle(AppTheme.accentActive)
                .underline()
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    // MARK: Custom agent form sheet

    private var customAgentSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: L10n.string(customAgentEditor.selectedAgentID == nil
                ? "Add Custom Agent"
                : "Edit Custom Agent"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)

            VStack(spacing: 12) {
                field(L10n.string("Agent Name"), text: $customAgentEditor.agentName, prompt: L10n.string("Agent Name"))
                field(L10n.string("Global Roots"), text: $customAgentEditor.globalRoots, prompt: L10n.string("Comma-separated paths"))
                field(L10n.string("Project Patterns"), text: $customAgentEditor.projectPatterns, prompt: L10n.string("Comma-separated paths"))
                field(L10n.string("Entry Filename"), text: $customAgentEditor.entryFilename, prompt: "SKILL.md")
            }
            .onChange(of: customAgentEditor.projectPatterns) { _, _ in
                patternDryRunResult = nil
            }
            .onChange(of: customAgentEditor.entryFilename) { _, _ in
                patternDryRunResult = nil
            }

            patternDryRunSection

            HStack(spacing: 8) {
                Spacer()
                Button(L10n.string("Cancel")) {
                    customAgentEditor.reset()
                    showCustomAgentSheet = false
                }
                .buttonStyle(ActionButtonStyle(role: .secondary))
                .keyboardShortcut(.cancelAction)
                Button(L10n.string(customAgentEditor.selectedAgentID == nil ? "Add" : "Save")) {
                    do {
                        try customAgentEditor.save(using: model)
                        showCustomAgentSheet = false
                    } catch {
                        settingsError = String(describing: error)
                    }
                }
                .buttonStyle(ActionButtonStyle(role: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(customAgentEditor.agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(AppTheme.background)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: label)
                .font(AppTheme.body(12.5, weight: .medium))
                .foregroundStyle(AppTheme.foregroundSecondary)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(AppTheme.body(13))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppTheme.border, lineWidth: 1)
                }
        }
    }

    // MARK: Pattern dry run

    private var draftPatterns: [String] {
        customAgentEditor.projectPatterns
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
    }

    private var hasDraftPatterns: Bool {
        !draftPatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .allSatisfy(\.isEmpty)
    }

    private var patternDryRunSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: L10n.string("Pattern Preview"))
                    .font(AppTheme.body(12.5, weight: .medium))
                    .foregroundStyle(AppTheme.foregroundSecondary)
                Spacer()
                Button {
                    runPatternDryRun()
                } label: {
                    HStack(spacing: 6) {
                        if isPatternDryRunning {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(verbatim: L10n.string("Dry Run…"))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(SettingsButtonStyle())
                .disabled(!hasDraftPatterns || isPatternDryRunning)
                .help(L10n.string("Dry Run Help"))
            }
            if let patternDryRunResult {
                patternDryRunResultView(patternDryRunResult)
            }
        }
    }

    private func patternDryRunResultView(_ report: PatternDryRunReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if report.matches.isEmpty {
                Text(verbatim: hasProjectRoots
                    ? L10n.string("Dry Run No Matches")
                    : L10n.string("Dry Run No Project Roots"))
                    .font(AppTheme.body(12))
                    .foregroundStyle(AppTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: L10n.string("Dry Run Matches", report.matches.count))
                    .font(AppTheme.body(12, weight: .medium))
                    .foregroundStyle(AppTheme.foregroundSecondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.matches) { match in
                            patternDryRunMatchRow(match)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !report.skippedRootPaths.isEmpty {
                Text(verbatim: L10n.string("Dry Run Skipped Roots", report.skippedRootPaths.count))
                    .font(AppTheme.body(11.5))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.borderSoft, lineWidth: 1)
        }
    }

    private func patternDryRunMatchRow(_ match: PatternDryRunMatch) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: match.url.path)
                .font(AppTheme.mono(11.5))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(match.url.path)
            HStack(spacing: 10) {
                if match.skillNames.isEmpty {
                    Text(verbatim: L10n.string("Dry Run No Skills", customAgentEditor.entryFilename.isEmpty ? "SKILL.md" : customAgentEditor.entryFilename))
                        .foregroundStyle(AppTheme.warn)
                } else {
                    Text(verbatim: L10n.string("Dry Run Skill Count", match.skillNames.count))
                        .foregroundStyle(AppTheme.muted)
                }
                ForEach(match.bindings.keys.sorted(), id: \.self) { name in
                    Text(verbatim: "{\(name)} = \(match.bindings[name] ?? "")")
                        .foregroundStyle(AppTheme.muted)
                }
            }
            .font(AppTheme.body(11.5))
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var hasProjectRoots: Bool {
        model.authorizedRoots.contains { $0.kind == .project }
    }

    private func runPatternDryRun() {
        let entry = customAgentEditor.entryFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        isPatternDryRunning = true
        Task {
            patternDryRunResult = await model.dryRunProjectPatterns(
                patterns: draftPatterns,
                entryFilename: entry.isEmpty ? "SKILL.md" : entry
            )
            isPatternDryRunning = false
        }
    }

    // MARK: Shared

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    private func groupTitle(_ title: String, spaced: Bool = false) -> some View {
        Text(verbatim: title)
            .font(AppTheme.body(12, weight: .semibold))
            .foregroundStyle(AppTheme.muted)
            .kerning(0.1)
            .padding(.horizontal, 4)
            .padding(.top, spaced ? 24 : 0)
            .padding(.bottom, 8)
    }

    private func statusDot(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(verbatim: text)
                .font(AppTheme.body(12))
                .foregroundStyle(AppTheme.muted)
        }
    }

    private func reauthorize(_ root: AuthorizedRootSnapshot) {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Re-authorize Directory")
        panel.prompt = L10n.string("Authorize")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root.url
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.authorize(url, as: root.kind) }
    }

    private func importProject() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Import Project Directory")
        panel.message = L10n.string("Choose a project directory to scan for all Skills.")
        panel.prompt = L10n.string("Import")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.authorize(url, as: .project) }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = L10n.string("Export Redacted Diagnostics")
        panel.prompt = L10n.string("Export")
        panel.nameFieldStringValue = "SkillSelector-Diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await model.exportDiagnostics(to: url)
                exportStatus = L10n.string("Diagnostics Exported")
            } catch {
                settingsError = String(describing: error)
            }
        }
    }

    private func exportCustomAgents() {
        let panel = NSSavePanel()
        panel.title = L10n.string("Export Custom Agents")
        panel.prompt = L10n.string("Export")
        panel.nameFieldStringValue = "SkillSelector-CustomAgents.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportCustomAgents(to: url)
            exportStatus = L10n.string("Custom Agents Exported")
        } catch {
            settingsError = String(describing: error)
        }
    }

    private func importCustomAgents() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Import Custom Agents")
        panel.prompt = L10n.string("Import")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try model.importCustomAgents(from: url)
            exportStatus = String.localizedStringWithFormat(
                L10n.string("Custom Agents Imported"), result.imported, result.skipped
            )
        } catch {
            settingsError = String(describing: error)
        }
    }
}

// MARK: - Group building blocks

/// `.group` — a surface card whose rows are separated by hairline borders
/// (the design removes the border under the last row).
struct SettingsGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        _VariadicView.Tree(SettingsGroupLayout()) {
            content
        }
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.borderSoft, lineWidth: 1)
        }
    }
}

private struct SettingsGroupLayout: _VariadicView.MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let views = Array(children)
        VStack(spacing: 0) {
            ForEach(Array(views.enumerated()), id: \.offset) { index, child in
                child
                if index < views.count - 1 {
                    Rectangle()
                        .fill(AppTheme.borderSoft)
                        .frame(height: 1)
                }
            }
        }
    }
}

/// `.group-row` — 44 pt min-height row with label, optional sub, and a
/// trailing control. Rows inside a group separate themselves with a
/// hairline border above (the design removes it on the first row).
struct SettingsRow<Content: View>: View {
    let label: String
    var sub: String? = nil
    var subMonospaced = false
    var hint = false
    let trailing: Content

    init(
        label: String,
        sub: String? = nil,
        subMonospaced: Bool = false,
        hint: Bool = false,
        @ViewBuilder trailing: () -> Content = { EmptyView() }
    ) {
        self.label = label
        self.sub = sub
        self.subMonospaced = subMonospaced
        self.hint = hint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: label)
                    .font(AppTheme.body(13))
                    .foregroundStyle(hint ? AppTheme.muted : AppTheme.foreground)
                if let sub {
                    Text(verbatim: sub)
                        .font(subMonospaced ? AppTheme.mono(11.5) : AppTheme.body(11.5))
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if !(trailing is EmptyView) {
                trailing
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .padding(.vertical, 11)
        .background(AppTheme.surface)
    }
}

/// `.radio` — 17 pt circle; on state fills with the accent border.
struct RadioDot: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .strokeBorder(isOn ? AppTheme.accent : AppTheme.meta, lineWidth: isOn ? 5.5 : 1.5)
            .frame(width: 17, height: 17)
            .accessibilityHidden(true)
    }
}

/// `.btn` — 30 pt settings button with an elevation ring.
struct SettingsButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.body(12.5, weight: .medium))
            .foregroundStyle(AppTheme.foreground)
            .frame(height: 30)
            .padding(.horizontal, 14)
            .background(isHovering && !configuration.isPressed ? AppTheme.borderSoft : AppTheme.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
            .onHover { hovering in
                isHovering = hovering
            }
            .contentShape(Rectangle())
    }
}

/// `.btn.danger` — bordered-less destructive text button.
struct SettingsDangerButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.body(12.5, weight: .semibold))
            .foregroundStyle(AppTheme.danger)
            .frame(height: 30)
            .padding(.horizontal, 14)
            .background(isHovering && !configuration.isPressed ? AppTheme.dangerTint : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovering in
                isHovering = hovering
            }
            .contentShape(Rectangle())
    }
}

/// `.tab:hover:not(.active)` — soft fill on hover.
private struct SettingsTabHoverStyle: ButtonStyle {
    let isActive: Bool
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if isHovering && !isActive && !configuration.isPressed {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(AppTheme.borderSoft)
                }
            }
            .onHover { hovering in
                isHovering = hovering
            }
    }
}
