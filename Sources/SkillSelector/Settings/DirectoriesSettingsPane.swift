import SkillSelectorCore
import SwiftUI

/// The 目录授权 pane: authorized roots (with re-authorization and revoke),
/// the add-project entry, and the custom agent directory list. Root
/// rename state lives here — the context-menu entry seeds it (the edit
/// UI is still pending, see the rename TODO in the review notes).
struct DirectoriesSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @Binding var settingsError: String?
    @Binding var customAgentSheetRequest: CustomAgentSheetRequest?
    /// Seeds the pending root-rename flow from the row context menu.
    @State private var editingRootID: String?
    @State private var editingRootName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeading(title: L10n.string("Authorized Directories"))
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

            SettingsGroupHeading(title: L10n.string("Custom Agent Directories"), spaced: true)
            SettingsGroup {
                ForEach(model.customAgentDefinitions) { agent in
                    customAgentRow(agent)
                }
                SettingsRow(
                    label: L10n.string("Custom Agent Hint"),
                    hint: true
                ) {
                    Button(L10n.string("Add…")) {
                        customAgentSheetRequest = CustomAgentSheetRequest(agent: nil)
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .help(L10n.string("Add Custom Agent"))
                }
            }
        }
    }

    // MARK: Rows

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
                    SettingsStatusDot(text: L10n.string("Project"), color: AppTheme.meta)
                }
                SettingsStatusDot(
                    text: L10n.string(isHealthy ? "Authorized" : "Needs Re-authorization"),
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
                        settingsError = error.localizedDescription
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

    // MARK: Panels

    private func reauthorize(_ root: AuthorizedRootSnapshot) {
        guard let url = DirectoryPanel.chooseSingleDirectory(
            title: L10n.string("Re-authorize Directory"),
            prompt: L10n.string("Authorize"),
            initialDirectory: root.url
        ) else { return }
        Task { await model.authorize(url, as: root.kind) }
    }

    private func importProject() {
        guard let url = DirectoryPanel.chooseSingleDirectory(
            title: L10n.string("Import Project Directory"),
            message: L10n.string("Choose a project directory to scan for all Skills."),
            prompt: L10n.string("Import")
        ) else { return }
        Task { await model.authorize(url, as: .project) }
    }
}
