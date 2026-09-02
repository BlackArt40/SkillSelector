import SkillSelectorCore
import SwiftUI

/// A `.skill-row` from the design: gradient tile, name line with badges,
/// one-line description, and agent chips.
struct SkillRow: View {
    let skill: SkillSnapshot
    let agentNamesByID: [String: String]
    let isActive: Bool
    /// Active search text; hits in the name/description are highlighted.
    var highlightQuery: String = ""
    /// Folded body text of this skill (from the in-memory body index). When
    /// the row matched only through the body — neither the name nor the
    /// description contains the query — the description line shows the
    /// body's hit snippet instead, so the match stays visible.
    var bodyText: String? = nil
    var onSelect: () -> Void
    var onRevealInFinder: ((SkillSnapshot) -> Void)?
    var onOpenInEditor: ((SkillSnapshot) -> Void)?

    /// Dynamic Type scaling: name 13.5 → ~16, description 12 → ~14 at the
    /// largest supported size, while rows keep their visual hierarchy.
    @ScaledMetric(relativeTo: .body) private var nameSize: CGFloat = 13.5
    @ScaledMetric(relativeTo: .body) private var descriptionSize: CGFloat = 12

    private var descriptionText: String {
        skill.localDescription ?? skill.name
    }

    /// The description line. When the query hits the name, the full
    /// description shows as usual. Otherwise — if the query is not already
    /// visible in the first ~40 characters of the description (descriptions
    /// are long and `lineLimit(1)` truncates the rest) — a one-line snippet
    /// around the hit (description or body) is shown instead, so the match
    /// and its highlight stay visible.
    @ViewBuilder
    private var descriptionLine: some View {
        let query = highlightQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = descriptionText
        if !query.isEmpty, !skill.name.localizedCaseInsensitiveContains(query),
           let displayed = matchDisplay(query: query, description: description) {
            HighlightedText(
                text: displayed,
                query: highlightQuery,
                font: AppTheme.body(descriptionSize),
                baseColor: AppTheme.muted
            )
            .lineLimit(1)
        } else {
            HighlightedText(
                text: description,
                query: highlightQuery,
                font: AppTheme.body(descriptionSize),
                baseColor: AppTheme.muted
            )
            .lineLimit(1)
        }
    }

    /// The text to show for the description line, or nil when the whole
    /// description is fine as-is. Hits beyond the visible window are
    /// replaced by a flattened snippet around the hit.
    private func matchDisplay(query: String, description: String) -> String? {
        if let range = description.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            let offset = description.distance(from: description.startIndex, to: range.lowerBound)
            return offset <= 40 ? nil : snippet(query, in: description)
        }
        guard let bodyText,
              let range = bodyText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let offset = bodyText.distance(from: bodyText.startIndex, to: range.lowerBound)
        return offset <= 40 ? nil : snippet(query, in: bodyText)
    }

    /// A short window of `text` around its first hit of `query`, flattened
    /// to one line (multi-line bodies would otherwise render only the
    /// fragment before the first newline).
    private func snippet(_ query: String, in text: String) -> String {
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return text
        }
        let radius = 24
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex)
            ?? text.endIndex
        var snippet = String(text[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
        if start > text.startIndex { snippet = "…" + snippet }
        if end < text.endIndex { snippet += "…" }
        return snippet
    }

    /// The avatar tile; for symlink skills, hovering the visible link
    /// hint shows the target path (spec §符号链接展示).
    @ViewBuilder
    private var skillTile: some View {
        let tile = SkillTileView(
            title: skillTileLetter(for: skill.name),
            size: 34,
            cornerRadius: 9,
            active: isActive,
            // Symlink hint sits on the avatar's top-right (spec §5.2
            // + visual baseline: a 9 pt triangle, matching the
            // design's "link" affordance).
            symbolLink: skill.resolvedTarget != nil
        )
        if let target = skill.resolvedTarget {
            tile.help(target)
        } else {
            tile
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                skillTile
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        HighlightedText(
                            text: skill.name,
                            query: highlightQuery,
                            font: AppTheme.display(nameSize, weight: .semibold),
                            baseColor: AppTheme.foreground
                        )
                        .lineLimit(1)
                        if !skill.parseDiagnostics.isEmpty {
                            BadgeDot(
                                text: L10n.string("Diagnostics Badge"),
                                color: AppTheme.badgeWarnText,
                                dot: AnyView(Circle().fill(AppTheme.warn).frame(width: 6, height: 6))
                            )
                        }
                        if let target = skill.resolvedTarget {
                            // The visual hint now lives on the avatar (see
                            // SkillTileView's symbolLink overlay); keep the
                            // small link icon in the name row — hover shows
                            // the target path (spec §符号链接展示), VoiceOver
                            // announces it as the value.
                            Image(systemName: "link")
                                .font(.system(size: 9))
                                .foregroundStyle(AppTheme.muted)
                                .help(target)
                                .accessibilityLabel(L10n.string("Link Badge"))
                                .accessibilityValue(target)
                                .accessibilityHidden(false)
                        }
                    }
                    descriptionLine
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
            // Spec §2 motion: the selection background fades in over 120 ms
            // with the system curve — no pop, no easing bounce.
            .animation(.smooth(duration: 0.12), value: isActive)
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

/// `.agent-chip`: 10.5 pt pill on a surface background. On an active row
/// the pill background is light in both appearances, so its label uses the
/// fixed light-mode foreground — identical, readable chips across themes.
struct AgentChip: View {
    let text: String
    var onActiveRow = false

    var body: some View {
        Text(verbatim: text)
            .font(AppTheme.body(10.5, weight: .medium))
            .foregroundStyle(onActiveRow ? AppTheme.accentChipText : AppTheme.foregroundSecondary)
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
