import SkillSelectorCore
import SwiftUI

/// The middle column for the links destination: every symbolic-link Skill
/// as a "source → target" row. Clicking a row opens the source Skill's
/// detail pane in the normal way.
struct SymlinkListView: View {
    let links: [SkillSnapshot]
    let selection: SkillSelection?
    let agentNamesByID: [String: String]
    var onRevealInFinder: ((SkillSnapshot) -> Void)?
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(height: 1)
            content
        }
        .background(AppTheme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(L10n.string("Symbolic Links"))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(verbatim: L10n.string("Symbolic Links"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(1)
            Text(verbatim: String.localizedStringWithFormat(
                L10n.string("Symbolic Links Count"), links.count
            ))
            .font(AppTheme.body(12))
            .foregroundStyle(AppTheme.muted)
            Spacer(minLength: 8)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 46)
        .background(AppTheme.background)
    }

    @ViewBuilder
    private var content: some View {
        if links.isEmpty {
            VStack(spacing: 8) {
                Spacer(minLength: 48)
                Text(verbatim: L10n.string("No Symbolic Links"))
                    .font(AppTheme.display(17, weight: .semibold))
                    .foregroundStyle(AppTheme.foreground)
                Text(verbatim: L10n.string("No Symbolic Links Description"))
                    .font(AppTheme.body(13))
                    .foregroundStyle(AppTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                Spacer(minLength: 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(links) { skill in
                        SymlinkRow(
                            skill: skill,
                            agentNamesByID: agentNamesByID,
                            isActive: selection?.path == skill.path,
                            onSelect: { onSelect(skill.path) },
                            onRevealInFinder: onRevealInFinder
                        )
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

/// One source → target row. A target that no longer resolves (moved or
/// deleted) is highlighted as a warning — the app never touches the file
/// system, so the user handles the break in Finder.
private struct SymlinkRow: View {
    let skill: SkillSnapshot
    let agentNamesByID: [String: String]
    let isActive: Bool
    let onSelect: () -> Void
    var onRevealInFinder: ((SkillSnapshot) -> Void)?

    @State private var isHovering = false

    private var isBroken: Bool {
        skill.linkTargetIsUnreachable
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundStyle(isBroken ? AppTheme.warn : AppTheme.meta)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: skill.name)
                            .font(AppTheme.display(13, weight: .semibold))
                            .foregroundStyle(AppTheme.foreground)
                            .lineLimit(1)
                        if isBroken {
                            BadgeDot(
                                text: L10n.string("Unreachable Target"),
                                color: AppTheme.warn,
                                dot: AnyView(
                                    Circle().fill(AppTheme.warn).frame(width: 6, height: 6)
                                )
                            )
                        }
                    }
                    HStack(spacing: 6) {
                        Text(verbatim: skill.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundStyle(AppTheme.meta)
                        Text(verbatim: skill.resolvedTarget ?? "")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(AppTheme.mono(11))
                    .foregroundStyle(isBroken ? AppTheme.warn : AppTheme.muted)
                    .help(skill.resolvedTarget ?? "")
                    if !agentNames.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(agentNames, id: \.self) { name in
                                AgentChip(text: name, onActiveRow: isActive)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isActive ? AppTheme.accentTintBorder : Color.clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SymlinkRowHoverStyle())
        .contextMenu {
            Button {
                onRevealInFinder?(skill)
            } label: {
                Label(L10n.string("Reveal Skill Document in Finder"), systemImage: "folder")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var agentNames: [String] {
        skill.agentDisplayNames(by: agentNamesByID)
    }

    private var rowBackground: Color {
        isActive ? AppTheme.accentTint : (isHovering ? AppTheme.surface : .clear)
    }
}

private struct SymlinkRowHoverStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if isHovering && !configuration.isPressed {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(AppTheme.surface)
                }
            }
            .onHover { hovering in
                isHovering = hovering
            }
    }
}
