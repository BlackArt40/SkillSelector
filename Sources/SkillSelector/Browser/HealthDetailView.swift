import SkillSelectorCore
import SwiftUI

/// The right column for the Health destination: why one entry is listed, and
/// what is known about each copy of it.
///
/// This is where the duplicate criteria are laid out side by side. There is
/// no recommended copy and no combined score — and the section says so in
/// words, because a table of numbers otherwise invites the reader to assume
/// a verdict is hidden somewhere in them.
struct HealthDetailView: View {
    let item: SkillHealthItem?
    var agentNamesByID: [String: String] = [:]
    var onRevealInFinder: ((SkillSnapshot) -> Void)?

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header(item)
                    reasonSection(item)
                    if item.snapshots.count > 1 {
                        copiesSection(item)
                    }
                    revealSection(item)
                }
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 48)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(AppTheme.background)
            .navigationTitle(HealthExplanations.categoryTitle(item.category))
        } else {
            emptyState
                .background(AppTheme.background)
        }
    }

    // MARK: Header

    private func header(_ item: SkillHealthItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: HealthExplanations.categoryTitle(item.category))
                .font(AppTheme.display(28, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(2)
            Text(verbatim: HealthExplanations.itemSummary(item))
                .font(AppTheme.mono(12))
                .foregroundStyle(AppTheme.muted)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    // MARK: Why

    private func reasonSection(_ item: SkillHealthItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailViewSupport.sectionHeading(L10n.string("Health Why"))
            Text(verbatim: HealthExplanations.categoryReason(item.category))
                .font(AppTheme.body(14))
                .foregroundStyle(AppTheme.foregroundSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // MARK: Copies and their criteria

    private func copiesSection(_ item: SkillHealthItem) -> some View {
        let facts = DuplicateAuthorityFacts.facts(for: item.snapshots)
        let totalCriteria = DuplicateCriterion.allCases.count

        return VStack(alignment: .leading, spacing: 12) {
            DetailViewSupport.sectionHeading(L10n.string("Health Copies Heading"))
            VStack(alignment: .leading, spacing: 16) {
                ForEach(facts) { copy in
                    copyCard(copy, totalCriteria: totalCriteria)
                }
            }
            Text(verbatim: L10n.string("Health Authority Note"))
                .font(AppTheme.body(12))
                .foregroundStyle(AppTheme.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyCard(_ facts: DuplicateMemberFacts, totalCriteria: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: facts.snapshot.name)
                    .font(AppTheme.body(14, weight: .medium))
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(1)
                Text(verbatim: facts.snapshot.path)
                    .font(AppTheme.mono(11))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 8) {
                DetailViewSupport.keyValueRow(
                    HealthExplanations.criterionTitle(.pathDepth),
                    value: "\(facts.pathDepth)",
                    monospaced: true
                )
                DetailViewSupport.keyValueRow(
                    HealthExplanations.criterionTitle(.modificationDate),
                    value: HealthExplanations.modificationDate(facts.modificationDate),
                    monospaced: false
                )
                DetailViewSupport.keyValueRow(
                    HealthExplanations.criterionTitle(.referencingAgents),
                    value: "\(facts.referencingAgentCount)",
                    monospaced: true
                )
            }

            HStack(spacing: 8) {
                Text(verbatim: HealthExplanations.winSummary(facts, totalCriteria: totalCriteria))
                    .font(AppTheme.body(12))
                    .foregroundStyle(facts.winCount > 0 ? AppTheme.foregroundSecondary : AppTheme.muted)
                Spacer(minLength: 8)
                Button {
                    onRevealInFinder?(facts.snapshot)
                } label: {
                    Text(verbatim: L10n.string("Reveal in Finder"))
                        .contentShape(Rectangle())
                }
                .buttonStyle(ActionButtonStyle(role: .secondary))
                .help(L10n.string("Reveal in Finder"))
                .accessibilityLabel(L10n.string("Reveal in Finder"))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Single-snapshot entries

    /// Duplicate groups get their members listed above; a broken link is a
    /// single path, so it just gets the reveal action.
    @ViewBuilder
    private func revealSection(_ item: SkillHealthItem) -> some View {
        if item.snapshots.count == 1, let snapshot = item.snapshots.first {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(verbatim: snapshot.path)
                        .font(AppTheme.mono(12))
                        .foregroundStyle(AppTheme.foregroundSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button {
                        onRevealInFinder?(snapshot)
                    } label: {
                        Text(verbatim: L10n.string("Reveal in Finder"))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ActionButtonStyle(role: .secondary))
                    .help(L10n.string("Reveal in Finder"))
                    .accessibilityLabel(L10n.string("Reveal in Finder"))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            AppIconView(size: 96)
                .opacity(0.9)
            Text(verbatim: L10n.string("Health Select Item"))
                .font(AppTheme.display(28, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: L10n.string("Health Select Item Detail"))
                .font(AppTheme.body(14))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
