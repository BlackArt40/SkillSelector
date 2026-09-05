import SkillSelectorCore
import SwiftUI

enum BrowserDestination: Hashable {
    case all
    case global
    case duplicates
    case links
    case rules
    case mcp
    case catalog
    case system(rootID: String)
    case project(rootID: String)
    case agent(id: String)

    var queryScope: SkillQuery.Scope {
        switch self {
        case .all, .agent, .duplicates, .links, .rules, .mcp, .catalog:
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

    /// Where browsing should land after an authorized root is removed:
    /// removing the root currently being browsed falls back to the
    /// All Skills list, anything else stays put.
    static func fallback(afterRemoving rootID: String, from destination: BrowserDestination) -> BrowserDestination {
        switch destination {
        case .system(let id), .project(let id):
            return id == rootID ? .all : destination
        default:
            return destination
        }
    }
}

/// Sidebar mirroring the design's `.sidebar` column: 240 pt, surface
/// background, section headings, icon rows with trailing counts, and a
/// footer with 设置 / 添加项目 links.
struct BrowserSidebar: View {
    @Binding var destination: BrowserDestination
    let roots: [AuthorizedRootSnapshot]
    let definitions: [AgentDefinition]
    let detectedAgentIDs: Set<String>
    var manuallyEnabledAgentIDs: Set<String> = []
    var unhealthyRootIDs: Set<String> = []
    let counts: [BrowserDestination: Int]
    /// True while a scan runs — the sidebar footer shows a quiet one-line
    /// "Scanning…" progress (spec §06 loading), no blocking overlay.
    var isScanning: Bool = false
    var onAddProject: () -> Void
    var onReauthorize: ((AuthorizedRootSnapshot) -> Void)?
    var onRemoveRoot: ((AuthorizedRootSnapshot) -> Void)?

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
            detectedAgentIDs: detectedAgentIDs,
            manuallyEnabledAgentIDs: manuallyEnabledAgentIDs
        )
    }

    /// Agent IDs detected from the current scan. Nothing shows until an
    /// authorized root has been imported; the index only holds Skills that
    /// exist on disk right now, so no availability filter is needed.
    static func detectedAgentIDs(
        from snapshots: [SkillSnapshot],
        hasAuthorization: Bool
    ) -> Set<String> {
        guard hasAuthorization else { return [] }
        return Set(snapshots.flatMap(\.agentIDs))
    }

    /// Agent IDs that declared MCP servers in the scanned configs. A sidebar
    /// Agent row appears when the Agent is detected from either Skills or
    /// MCP — a Codex that only wires MCP servers still gets a row.
    static func mcpAgentIDs(from mcpServers: [McpServerDescriptor]) -> Set<String> {
        Set(mcpServers.compactMap(\.agentID))
    }

    /// Legacy agents stay hidden until detected or manually enabled; the
    /// synthetic owners never appear as sidebar agents.
    static func visibleAgentDefinitions(
        definitions: [AgentDefinition],
        detectedAgentIDs: Set<String>,
        manuallyEnabledAgentIDs: Set<String> = []
    ) -> [AgentDefinition] {
        definitions
            .filter {
                detectedAgentIDs.contains($0.id)
                    || ($0.isLegacy && manuallyEnabledAgentIDs.contains($0.id))
            }
            .filter { !SyntheticAgentID.all.contains($0.id) }
            .sorted {
                let lhsName = $0.displayName.lowercased()
                let rhsName = $1.displayName.lowercased()
                return lhsName == rhsName ? $0.id < $1.id : lhsName < rhsName
            }
    }

    private var duplicateProjectNames: Set<String> {
        Self.duplicateNameRoots(projects)
    }

    private var duplicateSystemNames: Set<String> {
        Self.duplicateNameRoots(systemRoots)
    }

    /// Root display names that appear more than once, so their rows can
    /// disambiguate by showing the full path.
    private static func duplicateNameRoots(_ roots: [AuthorizedRootSnapshot]) -> Set<String> {
        let groups = Dictionary(grouping: roots, by: { $0.url.lastPathComponent.lowercased() })
        return Set(groups.compactMap { $0.value.count > 1 ? $0.key : nil })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    mainSection
                    unhealthySection
                    systemSection
                    projectsSection
                    agentsSection
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
            if isScanning {
                scanningFooter
            }
        }
        .background(AppTheme.surface)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(width: 1)
        }
    }

    // MARK: Sections

    /// Quiet one-line scan progress at the sidebar's foot (spec §06):
    /// caption text + small spinner, no blocking overlay. Shown only while
    /// a refresh is in flight.
    private var scanningFooter: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(verbatim: L10n.string("Scanning"))
                .font(AppTheme.body(11))
                .foregroundStyle(AppTheme.muted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(height: 1)
        }
    }

    private var mainSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarItem(
                title: L10n.string("All Skills"),
                glyph: Image(systemName: "square.stack.3d.up"),
                count: counts[.all],
                isActive: destination == .all
            ) {
                destination = .all
            }
            SidebarItem(
                title: L10n.string("Global Skills"),
                glyph: Image(systemName: "globe"),
                count: counts[.global],
                isActive: destination == .global
            ) {
                destination = .global
            }
            SidebarItem(
                title: L10n.string("Duplicate Skills"),
                glyph: Image(systemName: "doc.on.doc"),
                count: counts[.duplicates],
                isActive: destination == .duplicates
            ) {
                destination = .duplicates
            }
            SidebarItem(
                title: L10n.string("Symbolic Links"),
                glyph: Image(systemName: "link"),
                count: counts[.links],
                isActive: destination == .links
            ) {
                destination = .links
            }
            SidebarItem(
                title: L10n.string("Rules"),
                glyph: Image(systemName: "text.document"),
                count: counts[.rules],
                isActive: destination == .rules
            ) {
                destination = .rules
            }
            SidebarItem(
                title: L10n.string("MCP"),
                glyph: Image(systemName: "rectangle.connected.to.line.below"),
                count: counts[.mcp],
                isActive: destination == .mcp
            ) {
                destination = .mcp
            }
            SidebarItem(
                title: L10n.string("Marketplace"),
                glyph: Image(systemName: "sparkles"),
                count: counts[.catalog],
                isActive: destination == .catalog
            ) {
                destination = .catalog
            }
        }
    }

    /// Roots whose bookmark no longer resolves: moved directory, restored
    /// backup, reinstalled system. Shown with a warning glyph and a direct
    /// re-authorization action — the scan cannot heal these on its own.
    @ViewBuilder
    private var unhealthySection: some View {
        let unhealthy = roots.filter { unhealthyRootIDs.contains($0.id) }
        if !unhealthy.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sideHeading(L10n.string("Needs Re-authorization"))
                ForEach(unhealthy) { root in
                    SidebarItem(
                        title: root.displayName,
                        subtitle: root.url.path,
                        glyph: Image(systemName: "exclamationmark.triangle.fill"),
                        count: nil,
                        isActive: false
                    ) {
                        onReauthorize?(root)
                    }
                    .help(L10n.string("Re-authorize Directory"))
                }
            }
        }
    }

    /// System directories (the home root and declared system roots) appear
    /// only when their scan actually found Skills — the sidebar shows
    /// nothing for empty directories.
    static func visibleSystemRoots(
        _ roots: [AuthorizedRootSnapshot],
        counts: [BrowserDestination: Int]
    ) -> [AuthorizedRootSnapshot] {
        roots.filter { (counts[.system(rootID: $0.id)] ?? 0) > 0 }
    }

    /// Project directories likewise appear only when they hold Skills.
    static func visibleProjectRoots(
        _ roots: [AuthorizedRootSnapshot],
        counts: [BrowserDestination: Int]
    ) -> [AuthorizedRootSnapshot] {
        roots.filter { (counts[.project(rootID: $0.id)] ?? 0) > 0 }
    }

    @ViewBuilder
    private var systemSection: some View {
        let visible = Self.visibleSystemRoots(systemRoots, counts: counts)
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sideHeading(L10n.string("System Directories"))
                ForEach(visible) { root in
                    systemRow(root)
                }
            }
        }
    }

    /// Project directories appear only when they hold Skills; the section
    /// header itself always shows, with a + button to import a project.
    @ViewBuilder
    private var projectsSection: some View {
        let visible = Self.visibleProjectRoots(projects, counts: counts)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                sideHeading(L10n.string("Projects"))
                Spacer(minLength: 4)
                Button(action: onAddProject) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.muted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.string("Add Project"))
                .accessibilityLabel(L10n.string("Add Project"))
            }
            .padding(.trailing, 4)
            if visible.isEmpty {
                Text(verbatim: L10n.string("No Projects"))
                    .font(AppTheme.body(12))
                    .foregroundStyle(AppTheme.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                ForEach(visible) { project in
                    projectRow(project)
                }
            }
        }
    }

    @ViewBuilder
    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sideHeading(L10n.string("Agents"))
            if agents.isEmpty {
                Text(verbatim: L10n.string("No Agents Detected"))
                    .font(AppTheme.body(12))
                    .foregroundStyle(AppTheme.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                ForEach(agents) { agent in
                    SidebarItem(
                        title: agent.displayName,
                        glyph: AgentIconView(agentID: agent.id, displayName: agent.displayName),
                        count: counts[.agent(id: agent.id)],
                        isActive: destination == .agent(id: agent.id)
                    ) {
                        destination = .agent(id: agent.id)
                    }
                }
            }
        }
    }

    private func sideHeading(_ text: String) -> some View {
        Text(verbatim: text)
            .font(AppTheme.body(11, weight: .semibold))
            .kerning(0.2)
            .foregroundStyle(AppTheme.muted)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
    }

    // MARK: Root rows

    private func systemRow(_ root: AuthorizedRootSnapshot) -> some View {
        let showsPath = duplicateSystemNames.contains(root.url.lastPathComponent.lowercased())
        return SidebarItem(
            title: L10n.string(root.kind.localizedName),
            subtitle: showsPath ? root.url.path : nil,
            glyph: Image(systemName: root.kind.systemImage),
            count: counts[.system(rootID: root.id)],
            isActive: destination == .system(rootID: root.id)
        ) {
            destination = .system(rootID: root.id)
        }
        .contextMenu {
            Button(L10n.string("Remove Directory"), role: .destructive) {
                onRemoveRoot?(root)
            }
        }
    }

    private func projectRow(_ project: AuthorizedRootSnapshot) -> some View {
        let showsPath = duplicateProjectNames.contains(project.url.lastPathComponent.lowercased())
        return SidebarItem(
            title: project.displayName,
            subtitle: showsPath ? project.url.path : nil,
            glyph: Image(systemName: "folder"),
            count: counts[.project(rootID: project.id)],
            isActive: destination == .project(rootID: project.id)
        ) {
            destination = .project(rootID: project.id)
        }
        .contextMenu {
            Button(L10n.string("Remove Directory"), role: .destructive) {
                onRemoveRoot?(project)
            }
        }
    }
}

/// A single `.side-item`: 32 pt tall, 13 pt label, 11 pt trailing count.
struct SidebarItem: View {
    let title: String
    var subtitle: String? = nil
    let glyph: AnyView
    let count: Int?
    let isActive: Bool
    let action: () -> Void

    init<G: View>(
        title: String,
        subtitle: String? = nil,
        glyph: G,
        count: Int?,
        isActive: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.glyph = AnyView(glyph)
        self.count = count
        self.isActive = isActive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                glyph
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(isActive ? AppTheme.accentActive : AppTheme.muted)
                if let subtitle {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: title)
                            .lineLimit(1)
                        Text(verbatim: subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Text(verbatim: title)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let count {
                    Text(verbatim: "\(count)")
                        .foregroundStyle(AppTheme.muted)
                        .font(AppTheme.mono(11, weight: isActive ? .medium : .regular))
                }
            }
            .font(AppTheme.body(13, weight: isActive ? .medium : .regular))
            .foregroundStyle(isActive ? AppTheme.accentActive : AppTheme.foreground)
            .frame(height: 32)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? AppTheme.accentTint : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle())
    }
}

/// Hover background for `.side-item:hover` (border-soft fill).
private struct SidebarButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if isHovering && !configuration.isPressed {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(AppTheme.borderSoft)
                }
            }
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

extension BrowserDestination {
    /// The column title for the current destination ("全部 Skill",
    /// "全局 Skill", the root label, or the agent name).
    func title(rootsByID: [String: AuthorizedRootSnapshot], definitions: [AgentDefinition]) -> String {
        switch self {
        case .all: L10n.string("All Skills")
        case .global: L10n.string("Global Skills")
        case .duplicates: L10n.string("Duplicate Skills")
        case .links: L10n.string("Symbolic Links")
        case .rules: L10n.string("Rules")
        case .mcp: L10n.string("MCP")
        case .catalog: L10n.string("Marketplace")
        case .system(let rootID), .project(let rootID):
            rootsByID[rootID]?.displayName ?? rootID
        case .agent(let id):
            definitions.first { $0.id == id }?.displayName ?? id
        }
    }
}
