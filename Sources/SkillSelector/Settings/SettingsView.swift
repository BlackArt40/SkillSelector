import AppKit
import SkillSelectorCore
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

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var customAgentEditor = CustomAgentEditorState()
    @State private var settingsError: String?
    @State private var exportStatus: String?

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                settingsSection(
                    title: L10n.string("Refresh and Metadata"),
                    systemImage: "arrow.clockwise"
                ) {
                    Toggle(L10n.string("Refresh Skills at Launch"), isOn: $model.refreshOnLaunch)
                    Toggle(
                        L10n.string("Enrich Missing Descriptions After Refresh"),
                        isOn: $model.enrichMissingDescriptionsAfterRefresh
                    )
                    Text(verbatim: L10n.string(
                        "Uses local gh, npm, and enabled read-only MCP tools only for Skills without custom, local, or remote descriptions."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Divider()

                settingsSection(
                    title: L10n.string("Authorized Directories"),
                    systemImage: "folder.badge.gearshape"
                ) {
                    authorizedRoots
                    AuthorizationViews(showsHeading: false)
                }

                Divider()

                settingsSection(
                    title: L10n.string("Custom Agents"),
                    systemImage: "person.crop.square.badge.plus"
                ) {
                    customAgents
                }

                Divider()

                settingsSection(
                    title: L10n.string("Legacy Agents"),
                    systemImage: "clock.arrow.circlepath"
                ) {
                    legacyAgents
                }

                Divider()

                settingsSection(
                    title: L10n.string("Local Tools"),
                    systemImage: "terminal"
                ) {
                    toolStatuses
                }

                Divider()
                MCPSettingsView()
                Divider()

                settingsSection(
                    title: L10n.string("Diagnostics"),
                    systemImage: "stethoscope"
                ) {
                    Button {
                        exportDiagnostics()
                    } label: {
                        Label(L10n.string("Export Redacted Diagnostics"), systemImage: "square.and.arrow.up")
                    }
                    if let exportStatus {
                        Text(verbatim: exportStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(22)
        }
        .frame(width: 660, height: 720)
        .background(SettingsWindowTitle(title: L10n.string("SkillSelector Settings")))
        .task { await model.detectTools() }
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

    private var authorizedRoots: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.authorizedRoots.isEmpty {
                Text(verbatim: L10n.string("No directories authorized."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            ForEach(model.authorizedRoots) { root in
                HStack(spacing: 10) {
                    Image(systemName: rootIcon(root.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: rootTitle(root.kind))
                            .fontWeight(.medium)
                        Text(verbatim: root.url.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Button {
                        reauthorize(root)
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("Re-authorize Directory"))
                    .accessibilityLabel(L10n.string("Re-authorize Directory"))
                    Button(role: .destructive) {
                        Task { await model.revokeAuthorization(id: root.id) }
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("Revoke Authorization"))
                    .accessibilityLabel(L10n.string("Revoke Authorization"))
                }
                .padding(.vertical, 7)
                Divider()
            }
        }
    }

    private var customAgents: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.customAgentDefinitions) { agent in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: agent.displayName).fontWeight(.medium)
                        Text(verbatim: agent.entryFilename)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        customAgentEditor.beginEditing(agent)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("Edit Custom Agent"))
                    .accessibilityLabel(L10n.string("Edit Custom Agent"))
                    Button(role: .destructive) {
                        do {
                            try model.removeCustomAgent(id: agent.id)
                            customAgentEditor.resetIfEditing(removedID: agent.id)
                        }
                        catch { settingsError = String(describing: error) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("Remove Custom Agent"))
                    .accessibilityLabel(L10n.string("Remove Custom Agent"))
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(verbatim: L10n.string("Name"))
                    TextField(L10n.string("Agent Name"), text: $customAgentEditor.agentName)
                }
                GridRow {
                    Text(verbatim: L10n.string("Global Roots"))
                    TextField(L10n.string("Comma-separated paths"), text: $customAgentEditor.globalRoots)
                }
                GridRow {
                    Text(verbatim: L10n.string("Project Patterns"))
                    TextField(L10n.string("Comma-separated paths"), text: $customAgentEditor.projectPatterns)
                }
                GridRow {
                    Text(verbatim: L10n.string("Entry Filename"))
                    TextField("SKILL.md", text: $customAgentEditor.entryFilename)
                }
            }
            HStack {
                Button {
                    do {
                        try customAgentEditor.save(using: model)
                    } catch {
                        settingsError = String(describing: error)
                    }
                } label: {
                    Label(
                        L10n.string(customAgentEditor.selectedAgentID == nil
                            ? "Add Custom Agent"
                            : "Update Custom Agent"),
                        systemImage: customAgentEditor.selectedAgentID == nil ? "plus" : "checkmark"
                    )
                }
                .disabled(customAgentEditor.agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if customAgentEditor.selectedAgentID != nil {
                    Button(L10n.string("Cancel Editing")) {
                        customAgentEditor.reset()
                    }
                }
            }
        }
    }

    private var legacyAgents: some View {
        let legacyDefs = model.agentDefinitions.filter(\.isLegacy)
        return VStack(alignment: .leading, spacing: 8) {
            if legacyDefs.isEmpty {
                Text(verbatim: L10n.string("No legacy agents detected."))
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: L10n.string(
                    "Legacy agents only appear in the sidebar when detected or manually enabled."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(legacyDefs) { agent in
                    Toggle(isOn: Binding(
                        get: { model.manuallyEnabledLegacyAgentIDs.contains(agent.id) },
                        set: { _ in model.toggleLegacyAgent(agent.id) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: agent.displayName).fontWeight(.medium)
                            Text(verbatim: agent.id)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var toolStatuses: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ToolKind.allCases, id: \.self) { kind in
                HStack {
                    Text(verbatim: kind.rawValue)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                    Spacer()
                    if let status = model.toolStatuses[kind] {
                        Label(toolState(status.state), systemImage: toolStateIcon(status.state))
                            .foregroundStyle(status.state == .available ? .green : .secondary)
                        if let version = status.version {
                            Text(verbatim: version)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            Button {
                Task { await model.detectTools() }
            } label: {
                Label(L10n.string("Check Tools"), systemImage: "arrow.clockwise")
            }
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage).font(.headline)
            content()
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

    private func rootTitle(_ kind: AuthorizedRootKind) -> String {
        switch kind {
        case .home: L10n.string("Home Directory")
        case .project: L10n.string("Project Directory")
        case .system: L10n.string("System Skill Directory")
        case .custom: L10n.string("Custom Skill Directory")
        }
    }

    private func rootIcon(_ kind: AuthorizedRootKind) -> String {
        switch kind {
        case .home: "house"
        case .project: "folder"
        case .system: "externaldrive"
        case .custom: "folder.badge.plus"
        }
    }

    private func toolState(_ state: ToolAvailabilityState) -> String {
        switch state {
        case .available: L10n.string("Available")
        case .unavailable: L10n.string("Not Found")
        case .unauthenticated: L10n.string("Not Authenticated")
        case .invalid: L10n.string("Invalid")
        }
    }

    private func toolStateIcon(_ state: ToolAvailabilityState) -> String {
        switch state {
        case .available: "checkmark.circle.fill"
        case .unavailable: "questionmark.circle"
        case .unauthenticated: "person.crop.circle.badge.exclamationmark"
        case .invalid: "exclamationmark.triangle"
        }
    }
}
