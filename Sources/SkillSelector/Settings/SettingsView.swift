import AppKit
import SkillSelectorCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var settingsError: String?
    @State private var exportStatus: String?
    @State private var editingRootID: String?
    @State private var editingRootName: String = ""
    @State private var customAgentSheetRequest: CustomAgentSheetRequest?
    @State private var showDiagnosticsViewer = false

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
        .sheet(item: $customAgentSheetRequest) { request in
            CustomAgentSheet(editing: request.agent)
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
                            customAgentSheetRequest = CustomAgentSheetRequest(agent: nil)
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
                customAgentSheetRequest = CustomAgentSheetRequest(agent: agent)
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
