import SkillSelectorCore
import SwiftUI

enum BrowserDestination: Hashable {
    case all
    case global
    case system(rootID: String)
    case project(rootID: String)
    case agent(id: String)

    var queryScope: SkillQuery.Scope {
        switch self {
        case .all, .agent:
            .all
        case .global:
            .global
        case .system(let rootID):
            .root(rootID: rootID)
        case .project(let rootID):
            .project(rootID: rootID)
        }
    }

    var agentID: String? {
        guard case .agent(let id) = self else { return nil }
        return id
    }

    var showsFolderGroups: Bool {
        switch self {
        case .all, .system:
            true
        case .global, .project, .agent:
            false
        }
    }
}

struct BrowserSidebar: View {
    @Binding var destination: BrowserDestination?
    let roots: [AuthorizedRootSnapshot]
    let definitions: [AgentDefinition]
    let detectedAgentIDs: Set<String>
    var onDrop: ((SkillDragPayload, URL) -> Void)?

    private var systemRoots: [AuthorizedRootSnapshot] {
        roots
            .filter { $0.kind == .home || $0.kind == .system }
            .sorted {
                let lhsName = $0.url.lastPathComponent.lowercased()
                let rhsName = $1.url.lastPathComponent.lowercased()
                return lhsName == rhsName ? $0.url.path < $1.url.path : lhsName < rhsName
            }
    }

    private var projects: [AuthorizedRootSnapshot] {
        roots
            .filter { $0.kind == .project }
            .sorted {
                let lhsName = $0.url.lastPathComponent.lowercased()
                let rhsName = $1.url.lastPathComponent.lowercased()
                return lhsName == rhsName ? $0.url.path < $1.url.path : lhsName < rhsName
            }
    }

    private var agents: [AgentDefinition] {
        Self.visibleAgentDefinitions(
            definitions: definitions,
            detectedAgentIDs: detectedAgentIDs
        )
    }

    /// Agent IDs detected from the current scan: only available, indexed
    /// Skills count, and nothing shows until an authorized root has been
    /// imported. Stale records (revoked roots, missing directories) and the
    /// never-imported state therefore keep the sidebar's Agents section empty.
    static func detectedAgentIDs(
        from snapshots: [SkillSnapshot],
        hasAuthorization: Bool
    ) -> Set<String> {
        guard hasAuthorization else { return [] }
        return Set(
            snapshots
                .filter { $0.availability == .available }
                .flatMap(\.agentIDs)
        )
    }

    static func visibleAgentDefinitions(
        definitions: [AgentDefinition],
        detectedAgentIDs: Set<String>
    ) -> [AgentDefinition] {
        definitions
            .filter { detectedAgentIDs.contains($0.id) && $0.id != "system" && $0.id != "custom" }
            .sorted {
                let lhsName = $0.displayName.lowercased()
                let rhsName = $1.displayName.lowercased()
                return lhsName == rhsName ? $0.id < $1.id : lhsName < rhsName
            }
    }

    private var duplicateProjectNames: Set<String> {
        let groups = Dictionary(grouping: projects, by: { $0.url.lastPathComponent.lowercased() })
        return Set(groups.compactMap { $0.value.count > 1 ? $0.key : nil })
    }

    var body: some View {
        List(selection: $destination) {
            Section {
                Label(L10n.string("All Skills"), systemImage: "square.stack.3d.up")
                    .tag(BrowserDestination.all)
                Label(L10n.string("Global Skills"), systemImage: "globe")
                    .tag(BrowserDestination.global)
            }

            if !systemRoots.isEmpty {
                Section(L10n.string("System")) {
                    ForEach(systemRoots) { root in
                        Label(L10n.string(root.kind.localizedName), systemImage: root.kind.systemImage)
                            .tag(BrowserDestination.system(rootID: root.id))
                            .dropDestination(for: SkillDragPayload.self) { items, _ in
                                guard let item = items.first,
                                      let onDrop else { return false }
                                onDrop(item, root.url)
                                return true
                            }
                    }
                }
            }

            if !projects.isEmpty {
                Section(L10n.string("Projects")) {
                    ForEach(projects) { project in
                        projectLabel(project)
                            .tag(BrowserDestination.project(rootID: project.id))
                            .dropDestination(for: SkillDragPayload.self) { items, _ in
                                guard let item = items.first,
                                      let onDrop else { return false }
                                onDrop(item, project.url)
                                return true
                            }
                    }
                }
            }

            if !agents.isEmpty {
                Section(L10n.string("Agents")) {
                    ForEach(agents) { agent in
                        Label(agent.displayName, systemImage: "terminal")
                            .tag(BrowserDestination.agent(id: agent.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(L10n.string("SkillSelector"))
    }

    @ViewBuilder
    private func projectLabel(_ project: AuthorizedRootSnapshot) -> some View {
        if duplicateProjectNames.contains(project.url.lastPathComponent.lowercased()) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: project.displayName)
                    Text(verbatim: project.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            Label(project.displayName, systemImage: "folder")
        }
    }
}
