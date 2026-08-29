import SkillSelectorCore
import SwiftUI

/// The refresh toolbar button's companion: recent refreshes that changed
/// something, each expandable to its added / changed / removed paths.
/// Purely a log view — paths are shown as-is; navigating to a Skill still
/// happens through the main browser.
struct RefreshHistoryPopover: View {
    let history: [RefreshChangeEntry]

    @State private var expandedIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: L10n.string("Change History"))
                .font(AppTheme.display(14, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            Rectangle().fill(AppTheme.borderSoft).frame(height: 1)
            if history.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 16)
                    Text(verbatim: L10n.string("No Changes Recorded"))
                        .font(AppTheme.display(13, weight: .semibold))
                        .foregroundStyle(AppTheme.foreground)
                    Text(verbatim: L10n.string("No Changes Recorded Description"))
                        .font(AppTheme.body(12))
                        .foregroundStyle(AppTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                    Spacer(minLength: 16)
                }
                .frame(width: 320, height: 180)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(history) { entry in
                            RefreshHistoryRow(
                                entry: entry,
                                isExpanded: expandedIDs.contains(entry.id),
                                onToggle: { toggle(entry.id) }
                            )
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(width: 360, height: 320)
            }
        }
        .background(AppTheme.background)
    }

    private func toggle(_ id: UUID) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }
}

private struct RefreshHistoryRow: View {
    let entry: RefreshChangeEntry
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.meta)
                    Text(verbatim: entry.date.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ))
                    .font(AppTheme.body(12, weight: .medium))
                    .foregroundStyle(AppTheme.foreground)
                    Spacer(minLength: 8)
                    countBadge(L10n.string("Added"), entry.addedPaths.count, AppTheme.success)
                    countBadge(L10n.string("Changed"), entry.changedPaths.count, AppTheme.warn)
                    countBadge(L10n.string("Removed"), entry.removedPaths.count, AppTheme.danger)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    pathList(L10n.string("Added"), entry.addedPaths, AppTheme.success)
                    pathList(L10n.string("Changed"), entry.changedPaths, AppTheme.warn)
                    pathList(L10n.string("Removed"), entry.removedPaths, AppTheme.danger)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(AppTheme.surface.opacity(0.5))
            }
            Rectangle().fill(AppTheme.borderSoft).frame(height: 1)
        }
    }

    @ViewBuilder
    private func countBadge(_ title: String, _ count: Int, _ color: Color) -> some View {
        if count > 0 {
            HStack(spacing: 3) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(verbatim: "\(count)")
                    .font(AppTheme.body(11))
                    .foregroundStyle(AppTheme.muted)
            }
            .help(title)
        }
    }

    @ViewBuilder
    private func pathList(_ title: String, _ paths: [String], _ color: Color) -> some View {
        if !paths.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(AppTheme.body(11, weight: .semibold))
                    .foregroundStyle(color)
                ForEach(paths, id: \.self) { path in
                    Text(verbatim: path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}
