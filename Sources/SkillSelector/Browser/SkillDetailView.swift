import AppKit
import SkillSelectorCore
import SwiftUI

/// The right `.detail` column from the design: hero, action bar, and the
/// 核心作用 / Skill 文档 / 关联 Agents / 位置 sections, capped at 720 pt.
struct SkillDetailView: View {
    let skill: SkillSnapshot?
    let rootsByID: [String: AuthorizedRootSnapshot]
    let agentNamesByID: [String: String]
    var onRevealInFinder: ((SkillSnapshot) -> Void)?
    var onOpenInEditor: ((SkillSnapshot) -> Void)?

    /// Dynamic Type scaling for the hero title (28 → ~34) and the core /
    /// document section bodies (14 → ~17 at the largest supported size).
    @ScaledMetric(relativeTo: .largeTitle) private var heroTitleSize: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 14

    var body: some View {
        Group {
            if let skill {
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        hero(skill)
                        actionBar(skill)
                        coreSection(skill)
                        documentSection(skill)
                        agentsSection(skill)
                        locationsSection(skill)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 32)
                    .padding(.bottom, 48)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .background(AppTheme.background)
                .navigationTitle(skill.name)
            } else {
                emptyState
                    .background(AppTheme.background)
            }
        }
    }

    // MARK: Hero

    private func hero(_ skill: SkillSnapshot) -> some View {
        HStack(alignment: .top, spacing: 20) {
            SkillTileView(
                title: skillTileLetter(for: skill.name),
                size: 72,
                cornerRadius: 18,
                active: false
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: skill.name)
                    .font(AppTheme.display(heroTitleSize, weight: .semibold))
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(verbatim: skill.path)
                    .font(AppTheme.mono(12))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.top, 3)
                if heroBadges(skill) {
                    HStack(spacing: 8) {
                        if skill.resolvedTarget != nil {
                            PillBadge(text: L10n.string("Symbolic Link Pill"), style: .link)
                        }
                        if !skill.parseDiagnostics.isEmpty {
                            PillBadge(text: L10n.string("Frontmatter Warning Pill"), style: .warn)
                        }
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    private func heroBadges(_ skill: SkillSnapshot) -> Bool {
        skill.resolvedTarget != nil || !skill.parseDiagnostics.isEmpty
    }

    // MARK: Action bar

    private func actionBar(_ skill: SkillSnapshot) -> some View {
        HStack(spacing: 8) {
            actionButton(
                icon: Image(systemName: "folder"),
                title: L10n.string("Reveal in Finder"),
                role: .secondary
            ) {
                onRevealInFinder?(skill)
            }
            actionButton(
                icon: nil,
                title: L10n.string("Open in Default Editor"),
                role: .secondary
            ) {
                onOpenInEditor?(skill)
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Core role

    private func coreSection(_ skill: SkillSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                DetailViewSupport.sectionHeading(
                    L10n.string("Core Role"),
                    badge: srcBadge(skill)
                )
                Spacer(minLength: 8)
            }
            Text(verbatim: descriptionText(skill))
                .font(AppTheme.body(bodySize))
                .foregroundStyle(AppTheme.foregroundSecondary)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func descriptionText(_ skill: SkillSnapshot) -> String {
        skill.localDescription ?? skill.name
    }

    private func srcBadge(_ skill: SkillSnapshot) -> Text? {
        Text(verbatim: L10n.string("Source Badge", skill.entryFilename))
    }

    // MARK: Skill document

    private func documentSection(_ skill: SkillSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailViewSupport.sectionHeading(L10n.string("Skill Document"))
            MarkdownDocumentView(skill: skill)
                .id(skill.path)
        }
    }

    // MARK: Agents

    private func agentsSection(_ skill: SkillSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailViewSupport.sectionHeading(L10n.string("Associated Agents"))
            let names = skill.agentDisplayNames(by: agentNamesByID)
            if names.isEmpty {
                Text(verbatim: L10n.string("None"))
                    .font(AppTheme.body(13))
                    .foregroundStyle(AppTheme.muted)
            } else {
                FlowChips(names: names)
            }
        }
    }

    // MARK: Locations

    private func locationsSection(_ skill: SkillSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailViewSupport.sectionHeading(L10n.string("Locations"))
            VStack(alignment: .leading, spacing: 10) {
                DetailViewSupport.keyValueRow(L10n.string("Level"), value: scopeLabel(skill), monospaced: false)
                DetailViewSupport.keyValueRow(L10n.string("Root"), value: rootLabel(skill), monospaced: true)
                DetailViewSupport.keyValueRow(L10n.string("Installation Path"), value: skill.path, monospaced: true)
                if let target = skill.resolvedTarget {
                    DetailViewSupport.keyValueRow(L10n.string("Link Target"), value: target, monospaced: true)
                }
                DetailViewSupport.keyValueRow(L10n.string("Entry File"), value: skill.entryFilename, monospaced: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scopeLabel(_ skill: SkillSnapshot) -> String {
        let kinds = skill.rootIDs.compactMap { rootsByID[$0]?.kind }
        let isProjectLevel = kinds.contains { $0 == .project || $0 == .custom }
        return isProjectLevel
            ? L10n.string("Project Scope")
            : L10n.string("Global User Scope")
    }

    private func rootLabel(_ skill: SkillSnapshot) -> String {
        guard let rootID = skill.rootIDs.first, let root = rootsByID[rootID] else {
            return skill.rootIDs.joined(separator: ", ")
        }
        return root.url.path
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            AppIconView(size: 96)
                .opacity(0.9)
            Text(verbatim: L10n.string("Select a Skill"))
                .font(AppTheme.display(heroTitleSize, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: L10n.string("Select a Skill Description"))
                .font(AppTheme.body(bodySize))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
