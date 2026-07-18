import SkillSelectorCore
import SwiftUI

enum BrowserDestination: Hashable {
    case all
    case global
    case project(rootID: String)
    case agent(id: String)

    var queryScope: SkillQuery.Scope {
        switch self {
        case .all, .agent:
            .all
        case .global:
            .global
        case .project(let rootID):
            .project(rootID: rootID)
        }
    }

    var agentID: String? {
        guard case .agent(let id) = self else { return nil }
        return id
    }
}

struct BrowserSidebar: View {
    @Binding var destination: BrowserDestination?
    let roots: [AuthorizedRootSnapshot]
    let definitions: [AgentDefinition]
    let detectedAgentIDs: Set<String>

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
        definitions
            .filter { detectedAgentIDs.contains($0.id) && $0.id != "system" && $0.id != "custom" }
            .sorted { lhs, rhs in
                let lhsName = lhs.displayName.lowercased()
                let rhsName = rhs.displayName.lowercased()
                return lhsName == rhsName ? lhs.id < rhs.id : lhsName < rhsName
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

            if !projects.isEmpty {
                Section(L10n.string("Projects")) {
                    ForEach(projects) { project in
                        projectLabel(project)
                            .tag(BrowserDestination.project(rootID: project.id))
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

            Section(L10n.string("Manage")) {
                SettingsLink {
                    Label(L10n.string("Directories"), systemImage: "folder.badge.gearshape")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("SkillSelector")
    }

    @ViewBuilder
    private func projectLabel(_ project: AuthorizedRootSnapshot) -> some View {
        if duplicateProjectNames.contains(project.url.lastPathComponent.lowercased()) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: project.url.lastPathComponent)
                    Text(verbatim: project.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            Label(project.url.lastPathComponent, systemImage: "folder")
        }
    }
}
