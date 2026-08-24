import SkillSelectorCore
import SwiftUI

/// A `.skill-row` from the design: gradient tile, name line with badges,
/// one-line description, and agent chips.
struct SkillRow: View {
    let skill: SkillSnapshot
    let agentNamesByID: [String: String]
    let isActive: Bool
    var onSelect: () -> Void
    var onRevealInFinder: ((SkillSnapshot) -> Void)?
    var onOpenInEditor: ((SkillSnapshot) -> Void)?

    private var descriptionText: String {
        skill.localDescription ?? skill.name
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                SkillTileView(
                    title: skillTileLetter(for: skill.name),
                    size: 34,
                    cornerRadius: 9,
                    active: isActive
                )
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(verbatim: skill.name)
                            .font(AppTheme.display(13.5, weight: .semibold))
                            .foregroundStyle(AppTheme.foreground)
                            .lineLimit(1)
                        if !skill.parseDiagnostics.isEmpty {
                            BadgeDot(
                                text: L10n.string("Diagnostics Badge"),
                                color: AppTheme.badgeWarnText,
                                dot: AnyView(Circle().fill(AppTheme.warn).frame(width: 6, height: 6))
                            )
                        }
                        if let target = skill.resolvedTarget {
                            BadgeDot(
                                text: L10n.string("Link Badge"),
                                color: AppTheme.muted,
                                dot: AnyView(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(AppTheme.meta, lineWidth: 1.5)
                                        .frame(width: 5, height: 5)
                                )
                            )
                            .help(target)
                        }
                    }
                    Text(verbatim: descriptionText)
                        .font(AppTheme.body(12))
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(1)
                        .padding(.top, 1)
                    if !agentNames.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(agentNames, id: \.self) { name in
                                AgentChip(text: name, onActiveRow: isActive)
                            }
                        }
                        .padding(.top, 5)
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
        .buttonStyle(RowHoverStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .contextMenu {
            Button {
                onRevealInFinder?(skill)
            } label: {
                Label(L10n.string("Reveal Skill Document in Finder"), systemImage: "folder")
            }
            Button {
                onOpenInEditor?(skill)
            } label: {
                Label(L10n.string("Open in Default Editor"), systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
    }

    private var agentNames: [String] {
        skill.agentDisplayNames(by: agentNamesByID)
    }

    private var rowBackground: Color {
        isActive ? AppTheme.accentTint : .clear
    }
}

/// `.badge-dot`: 10.5 pt semibold label with a leading status dot.
struct BadgeDot: View {
    let text: String
    let color: Color
    let dot: AnyView

    var body: some View {
        HStack(spacing: 4) {
            dot
            Text(verbatim: text)
        }
        .font(AppTheme.body(10.5, weight: .semibold))
        .foregroundStyle(color)
        .lineLimit(1)
        .accessibilityHidden(true)
    }
}

/// `.agent-chip`: 10.5 pt pill on a surface background.
struct AgentChip: View {
    let text: String
    var onActiveRow = false

    var body: some View {
        Text(verbatim: text)
            .font(AppTheme.body(10.5, weight: .medium))
            .foregroundStyle(AppTheme.foregroundSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(onActiveRow ? AppTheme.accentChip : AppTheme.surface, in: Capsule())
            .overlay {
                if !onActiveRow {
                    Capsule().stroke(AppTheme.borderSoft, lineWidth: 1)
                }
            }
            .lineLimit(1)
            .accessibilityHidden(true)
    }
}

/// `.skill-row:hover:not(.active)` — surface fill on hover.
private struct RowHoverStyle: ButtonStyle {
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
