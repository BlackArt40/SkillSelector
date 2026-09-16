import SkillSelectorCore
import SwiftUI

/// The middle column for the Health destination: one section per category,
/// each listing what it found.
///
/// Read-only by construction — there is no repair affordance anywhere in
/// this screen, not even a disabled one. The app presents and explains; the
/// file operations belong to Finder.
struct HealthListView: View {
    let sections: [SkillHealthSection]
    var selection: String?
    var onSelect: ((SkillHealthItem) -> Void)?

    private var total: Int { SkillHealthReport.totalItemCount(in: sections) }

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
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(verbatim: L10n.string("Consistency Health"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(1)
            if total > 0 {
                Text(verbatim: L10n.string("Health Items To Review", total))
                    .font(AppTheme.body(12))
                    .foregroundStyle(AppTheme.muted)
            }
            Spacer(minLength: 8)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 46)
        .background(AppTheme.background)
    }

    @ViewBuilder
    private var content: some View {
        if total == 0 {
            // Neutral, not celebratory: the app cannot tell "genuinely
            // clean" from "nothing was scanned", so it does not congratulate.
            EmptyState(
                icon: "checkmark.circle",
                title: L10n.string("Health Nothing To Review"),
                message: L10n.string("Health Nothing To Review Detail")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }

    private func sectionView(_ section: SkillHealthSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: HealthExplanations.categoryTitle(section.category))
                    .font(AppTheme.body(12, weight: .semibold))
                    .foregroundStyle(AppTheme.foregroundSecondary)
                Text(verbatim: "\(section.count)")
                    .font(AppTheme.body(11))
                    .foregroundStyle(AppTheme.muted)
            }
            .padding(.horizontal, 16)

            if section.items.isEmpty {
                // A clean class still gets a line. Hiding it would make
                // "nothing here" read the same as "not checked".
                Text(verbatim: HealthExplanations.categoryReason(section.category))
                    .font(AppTheme.body(11))
                    .foregroundStyle(AppTheme.muted)
                    .padding(.horizontal, 16)
            } else {
                ForEach(section.items) { item in
                    HealthItemRow(
                        item: item,
                        isActive: selection == item.id,
                        onSelect: { onSelect?(item) }
                    )
                    .padding(.horizontal, 8)
                }
            }
        }
    }
}

/// One entry in the list. Shows the summary and the reason it is here — the
/// "why" the list promises without making the user open anything.
private struct HealthItemRow: View {
    let item: SkillHealthItem
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: Self.glyph(item.category))
                    .font(.system(size: 11))
                    .foregroundStyle(glyphColor)
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: HealthExplanations.itemSummary(item))
                        .font(AppTheme.body(13, weight: .medium))
                        .foregroundStyle(isActive ? AppTheme.accentActive : AppTheme.foreground)
                        .lineLimit(2)
                    Text(verbatim: HealthExplanations.categoryReason(item.category))
                        .font(AppTheme.body(11))
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 44, alignment: .leading)
            .background(
                isActive ? AppTheme.accentTint : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Only the unreachable-link class is unambiguously broken; duplicate
    /// copies are worth a look, not an error, so they stay muted.
    private var glyphColor: Color {
        if isActive { return AppTheme.accentActive }
        return item.category == .unreachableLinks ? AppTheme.warn : AppTheme.meta
    }

    private static func glyph(_ category: SkillHealthCategory) -> String {
        switch category {
        case .exactDuplicates: return "doc.on.doc"
        case .nearDuplicates: return "square.on.square"
        case .unreachableLinks: return "link"
        }
    }
}
