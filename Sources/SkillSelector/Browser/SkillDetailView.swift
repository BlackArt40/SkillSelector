import AppKit
import SkillSelectorCore
import SwiftUI

/// The right `.detail` column from the design: hero, action bar, and the
/// 核心作用 / Skill 文档 / 关联 Agents / 位置 sections, capped at 720 pt.
struct SkillDetailView: View {
    @Environment(AppModel.self) private var model
    let skill: SkillSnapshot?
    let rootsByID: [String: AuthorizedRootSnapshot]
    let agentNamesByID: [String: String]
    var onOperation: ((FileOperationKind, SkillSnapshot) -> Void)?
    var onRevealInFinder: ((SkillSnapshot) -> Void)?

    var body: some View {
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
                    .font(AppTheme.display(28, weight: .semibold))
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
                title: L10n.string("Copy To…"),
                role: .secondary
            ) {
                onOperation?(.copy, skill)
            }
            actionButton(
                icon: nil,
                title: L10n.string("Move To…"),
                role: .secondary
            ) {
                onOperation?(.move, skill)
            }
            actionButton(
                icon: nil,
                title: L10n.string("Create Link…"),
                role: .secondary
            ) {
                onOperation?(.createSymbolicLink, skill)
            }
            Spacer(minLength: 8)
            actionButton(
                icon: Image(systemName: "trash"),
                title: L10n.string("Move to Trash"),
                role: .destructive
            ) {
                onOperation?(.delete, skill)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Core role

    private func coreSection(_ skill: SkillSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(
                L10n.string("Core Role"),
                badge: srcBadge(skill)
            )
            Text(verbatim: descriptionText(skill))
                .font(AppTheme.body(14))
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
            sectionHeading(L10n.string("Skill Document"))
            MarkdownDocumentView(skill: skill)
                .id(skill.path)
        }
    }

    // MARK: Agents

    private func agentsSection(_ skill: SkillSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(L10n.string("Associated Agents"))
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
            sectionHeading(L10n.string("Locations"))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                keyValue(L10n.string("Level"), value: scopeLabel(skill), monospaced: false)
                keyValue(L10n.string("Root"), value: rootLabel(skill), monospaced: true)
                keyValue(L10n.string("Installation Path"), value: skill.path, monospaced: true)
                if let target = skill.resolvedTarget {
                    keyValue(L10n.string("Link Target"), value: target, monospaced: true)
                }
                keyValue(L10n.string("Entry File"), value: skill.entryFilename, monospaced: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func keyValue(_ label: String, value: String, monospaced: Bool) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(verbatim: label)
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
                .frame(width: 108, alignment: .leading)
            Text(verbatim: value)
                .font(monospaced ? AppTheme.mono(12) : AppTheme.body(13))
                .foregroundStyle(AppTheme.foreground)
                .textSelection(.enabled)
                .lineLimit(3)
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

    // MARK: Shared

    private func sectionHeading(_ title: String, badge: Text? = nil) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title)
                .font(AppTheme.display(14, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            if let badge {
                badge
                    .font(AppTheme.body(10.5, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(AppTheme.surface, in: Capsule())
                    .overlay(Capsule().stroke(AppTheme.borderSoft, lineWidth: 1))
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            AppIconView(size: 96)
                .opacity(0.9)
            Text(verbatim: L10n.string("Select a Skill"))
                .font(AppTheme.display(28, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: L10n.string("Select a Skill Description"))
                .font(AppTheme.body(14))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
