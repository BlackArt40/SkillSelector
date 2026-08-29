import SkillSelectorCore
import SwiftUI

/// The middle `.list-col` column for the read-only marketplace catalog:
/// a header with title, count and refresh, then one row per remote skill
/// grouped under its declared source. Read-only — rows open the detail
/// pane; installation stays with the ecosystem's tooling.
struct CatalogListView: View {
    let state: CatalogState
    var selection: String?
    var sourceNamesByID: [String: String] = [:]
    var onSelect: ((CatalogSkill) -> Void)?
    var onRefresh: (() -> Void)?

    private var skills: [CatalogSkill] {
        if case .loaded(let skills, _) = state { return skills }
        return []
    }

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
            Text(verbatim: L10n.string("Catalog"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(1)
            if !skills.isEmpty {
                Text(verbatim: "\(skills.count)")
                    .font(AppTheme.body(12))
                    .foregroundStyle(AppTheme.muted)
            }
            Spacer(minLength: 8)
            Button {
                onRefresh?()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .help(L10n.string("Refresh Catalog"))
            .accessibilityLabel(L10n.string("Refresh Catalog"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 46)
        .background(AppTheme.background)
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            loadingState
        case .loaded(let skills, let truncated):
            if skills.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if truncated {
                            truncatedBanner
                        }
                        ForEach(skills) { skill in
                            CatalogSkillRow(
                                skill: skill,
                                sourceName: sourceNamesByID[skill.sourceID] ?? skill.sourceID,
                                isActive: selection == skill.id,
                                onSelect: { onSelect?(skill) }
                            )
                            .padding(.horizontal, 8)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        case .failed(let failure):
            failedState(failure)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 48)
            ProgressView()
                .controlSize(.small)
            Text(verbatim: L10n.string("Catalog Loading"))
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 48)
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundStyle(AppTheme.meta)
            Text(verbatim: L10n.string("No Catalog Skills"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: L10n.string("No Catalog Skills Description"))
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var truncatedBanner: some View {
        Label(L10n.string("Catalog Truncated"), systemImage: "exclamationmark.triangle")
            .font(AppTheme.body(12))
            .foregroundStyle(AppTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 8)
    }

    private func failedState(_ failure: CatalogLoadFailure) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 48)
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundStyle(AppTheme.meta)
            Text(verbatim: L10n.string("Catalog Failed"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: CatalogFailureMessage.text(for: failure))
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(L10n.string("Retry")) {
                onRefresh?()
            }
            .controlSize(.small)
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One catalog row: skill name, source badge, and the repo-relative path.
struct CatalogSkillRow: View {
    let skill: CatalogSkill
    let sourceName: String
    let isActive: Bool
    var onSelect: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(isActive ? AppTheme.accentActive : AppTheme.muted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: skill.name)
                    .font(AppTheme.body(13, weight: .medium))
                    .foregroundStyle(isActive ? AppTheme.accentActive : AppTheme.foreground)
                    .lineLimit(1)
                Text(verbatim: skill.skillPath)
                    .font(AppTheme.mono(11))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            PillBadge(text: sourceName, style: .link)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 46)
        .background(isActive ? AppTheme.accentTint : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect?()
        }
    }
}

/// Localized failure text, shared by the list and detail panes.
enum CatalogFailureMessage {
    static func text(for failure: CatalogLoadFailure) -> String {
        switch failure {
        case .rateLimited:
            L10n.string("Catalog Failure Rate Limited")
        case .network:
            L10n.string("Catalog Failure Network")
        case .invalidResponse:
            L10n.string("Catalog Failure Invalid Response")
        case .http(let status):
            L10n.string("Catalog Failure HTTP", status)
        }
    }
}
