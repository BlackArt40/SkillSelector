import SkillSelectorCore
import SwiftUI

/// The 目录授权 pane as settings.html lays it out: a bold count-titled
/// section of bordered root cards (path, state dots, the destructive
/// remove button), a dashed full-width add row, then the custom agent
/// directory section. Renaming a project root opens `RootRenameSheet`.
struct DirectoriesSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @Binding var settingsError: String?
    @Binding var customAgentSheetRequest: CustomAgentSheetRequest?
    /// Root whose rename sheet is presented (project-level roots only).
    @State private var renamingRoot: AuthorizedRootSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeading(
                title: L10n.string("Authorized Directories"),
                count: model.authorizedRoots.count
            )
            if model.authorizedRoots.isEmpty {
                SettingsGroup {
                    SettingsRow(label: L10n.string("No directories authorized."))
                }
                .padding(.bottom, 12)
            } else {
                VStack(spacing: 12) {
                    ForEach(model.authorizedRoots) { root in
                        authorizedRootCard(root)
                    }
                }
                .padding(.bottom, 12)
            }

            dashedAddButton(
                title: L10n.string("Add Project Folder…"),
                icon: "plus.circle",
                help: L10n.string("Import Project Directory")
            ) {
                importProject()
            }

            SettingsGroupHeading(
                title: L10n.string("Custom Agent Directories"),
                count: model.customAgentDefinitions.count,
                spaced: true
            )
            VStack(spacing: 12) {
                ForEach(model.customAgentDefinitions) { agent in
                    customAgentCard(agent)
                }
            }
            .padding(.bottom, 12)

            dashedAddButton(
                title: L10n.string("Add…"),
                icon: "plus.circle",
                help: L10n.string("Add Custom Agent")
            ) {
                customAgentSheetRequest = CustomAgentSheetRequest(agent: nil)
            }
        }
        .sheet(item: $renamingRoot) { root in
            RootRenameSheet(root: root)
        }
    }

    // MARK: Cards

    /// settings.html's root card: the mono path behind a folder icon, then
    /// the state row — dots + caption, with the destructive remove button
    /// on the trailing edge.
    private func authorizedRootCard(_ root: AuthorizedRootSnapshot) -> some View {
        let isHome = root.kind == .home
        let isHealthy = !model.unhealthyRootIDs.contains(root.id)
        let isRenameable = root.kind == .project || root.kind == .custom
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.foregroundSecondary)
                Text(verbatim: isHome
                    ? L10n.string("User Home Directory")
                    : root.displayName)
                    .font(AppTheme.mono(13, weight: .bold))
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    statusDot(color: isHealthy ? AppTheme.ink : AppTheme.border)
                    if !isHome {
                        Text(verbatim: L10n.string("Project"))
                            .font(AppTheme.body(12))
                            .foregroundStyle(AppTheme.muted)
                    }
                    Text(verbatim: L10n.string(
                        isHealthy ? "Authorized" : "Needs Re-authorization"
                    ))
                    .font(AppTheme.body(12))
                    .foregroundStyle(AppTheme.muted)
                    if !isHealthy {
                        Button(L10n.string("Re-authorize…")) {
                            reauthorize(root)
                        }
                        .buttonStyle(SettingsButtonStyle())
                        .accessibilityLabel(L10n.string("Re-authorize Directory"))
                    }
                }
                Spacer(minLength: 8)
                if !isHome {
                    removeButton {
                        Task { await model.revokeAuthorization(id: root.id) }
                    }
                    .accessibilityLabel(L10n.string("Revoke Authorization"))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface)
        .overlay(Rectangle().stroke(AppTheme.border, lineWidth: 1))
        .hardShadow(.rest)
        .contextMenu {
            if isRenameable {
                Button(L10n.string("Rename")) {
                    renamingRoot = root
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

    private func customAgentCard(_ agent: AgentDefinition) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.foregroundSecondary)
                Text(verbatim: agent.displayName)
                    .font(AppTheme.body(13, weight: .bold))
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(1)
                Text(verbatim: agent.globalRoots.joined(separator: ", "))
                    .font(AppTheme.mono(13))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 12) {
                Text(verbatim: String.localizedStringWithFormat(
                    L10n.string("Custom Agent Entry Meta"), agent.entryFilename
                ))
                .font(AppTheme.body(12))
                .foregroundStyle(AppTheme.muted)
                Spacer(minLength: 8)
                removeButton {
                    do {
                        try model.removeCustomAgent(id: agent.id)
                    } catch {
                        settingsError = error.localizedDescription
                    }
                }
                .accessibilityLabel(L10n.string("Remove Custom Agent"))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface)
        .overlay(Rectangle().stroke(AppTheme.border, lineWidth: 1))
        .hardShadow(.rest)
        .contextMenu {
            Button(L10n.string("Edit Custom Agent")) {
                customAgentSheetRequest = CustomAgentSheetRequest(agent: agent)
            }
        }
    }

    private func removeButton(action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                Text(verbatim: L10n.string("Remove"))
            }
        }
        .buttonStyle(SettingsDangerButtonStyle())
    }

    /// settings.html's dashed full-width add row: 2 px dashed ink border,
    /// 40 pt tall, hover lift.
    private func dashedAddButton(
        title: String,
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(verbatim: title)
            }
            .font(AppTheme.body(13))
            .foregroundStyle(AppTheme.foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(DashedAddButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private func statusDot(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
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

/// Hover lift / press sink for the dashed add rows. The row has no opaque
/// fill of its own, so the page tone goes on *before* the hard shadow —
/// otherwise the shadow projects the text's own silhouette and the label
/// reads double-struck.
private struct DashedAddButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(AppTheme.background)
            .overlay {
                Rectangle()
                    .stroke(AppTheme.ink, style: StrokeStyle(lineWidth: 2, dash: [6]))
            }
            .hardShadow(.rest, isActive: !configuration.isPressed)
            .offset(
                x: configuration.isPressed ? 1 : (isHovering ? -1 : 0),
                y: configuration.isPressed ? 1 : (isHovering ? -1 : 0)
            )
            .onHover { isHovering = $0 }
    }
}
