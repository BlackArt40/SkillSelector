import SkillSelectorCore
import SwiftUI

/// The middle `.list-col` column for the read-only marketplace catalog:
/// a header with title, count and refresh, then one row per remote skill
/// grouped under its declared source. Read-only — rows open the detail
/// pane; installation stays with the ecosystem's tooling.
///
/// Descriptions are read from the model directly (not flowed through the
/// parent): prefetch flushes then invalidate only this list, not the
/// whole browser, so scrolling stays smooth while they stream in.
struct CatalogListView: View {
    @Environment(AppModel.self) private var model
    let state: CatalogState
    var selection: String?
    var onSelect: ((CatalogSkill) -> Void)?
    var onRefresh: (() -> Void)?

    /// Repository filter from the column header; nil shows every source.
    @State private var selectedSourceID: String?
    @State private var showingAddSheet = false
    /// Marketplace-local text filter (name + prefetched description).
    @State private var searchText = ""

    private var skills: [CatalogSkill] {
        if case .loaded(let skills, _) = state { return skills }
        return []
    }

    private var filteredSkills: [CatalogSkill] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return skills }
        return skills
            .filter { Self.matches($0, description: model.catalog.descriptions[$0.id], query: trimmed) }
            .sorted { Self.nameMatchComesFirst(lhs: $0, rhs: $1, query: trimmed) }
    }

    private var displayedSections: [CatalogSection] {
        Self.sections(
            of: filteredSkills,
            sources: model.catalog.sources,
            sourceID: selectedSourceID
        )
    }

    private var displayedCount: Int {
        displayedSections.reduce(0) { $0 + $1.skills.count }
    }

    /// A skill matches the query when its name or its prefetched
    /// description contains it, case-insensitive. A blank query matches all.
    static func matches(
        _ skill: CatalogSkill,
        description: String?,
        query: String
    ) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return skill.name.localizedCaseInsensitiveContains(trimmed)
            || (description?.localizedCaseInsensitiveContains(trimmed) ?? false)
    }

    /// Name hits sort ahead of description-only hits; ties keep their
    /// declared (name-sorted) order — `sorted` is stable.
    static func nameMatchComesFirst(
        lhs: CatalogSkill,
        rhs: CatalogSkill,
        query: String
    ) -> Bool {
        let lhsHit = lhs.name.localizedCaseInsensitiveContains(query)
        let rhsHit = rhs.name.localizedCaseInsensitiveContains(query)
        if lhsHit != rhsHit { return lhsHit }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(height: 1)
            if case .loaded = state {
                searchBar
            }
            content
        }
        .background(AppTheme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showingAddSheet) {
            AddCatalogSourceSheet(
                onImport: { custom in
                    let added = model.catalog.addSource(custom)
                    showingAddSheet = false
                    if added {
                        selectedSourceID = nil
                        Task { await model.catalog.refresh() }
                    }
                    return added
                },
                onCancel: { showingAddSheet = false }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(verbatim: L10n.string("Marketplace"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(1)
            if displayedCount > 0 {
                Text(verbatim: "\(displayedCount)")
                    .font(AppTheme.body(12))
                    .foregroundStyle(AppTheme.muted)
            }
            sourceFilterPicker
            addSourceButton
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
            .help(L10n.string("Refresh Marketplace"))
            .accessibilityLabel(L10n.string("Refresh Marketplace"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 46)
        .background(AppTheme.background)
    }

    /// Repository category filter: every declared source plus the
    /// everything option, rendered as a compact pull-down menu.
    private var sourceFilterPicker: some View {
        Picker("Marketplace Source Filter", selection: $selectedSourceID) {
            Text(verbatim: L10n.string("All Sources")).tag(String?.none)
            ForEach(model.catalog.sources) { source in
                Text(verbatim: source.displayName).tag(Optional(source.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel(L10n.string("Marketplace Source Filter"))
    }

    /// 「导入市场」: block button with a label — opens the import sheet
    /// for a user-declared GitHub source.
    private var addSourceButton: some View {
        Button {
            showingAddSheet = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                Text(verbatim: L10n.string("Import Source"))
                    .font(AppTheme.body(12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(L10n.string("Import Source"))
        .accessibilityLabel(L10n.string("Import Source"))
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        // Built once per render so per-row lookups stay O(1).
        let installed = LocalInstallationMatcher.installedNames(in: model.snapshots)
        switch state {
        case .idle, .loading:
            loadingState
        case .loaded(_, let truncated):
            if skills.isEmpty {
                emptyState
            } else if displayedSections.isEmpty {
                noMatchesState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2, pinnedViews: [.sectionHeaders]) {
                        if truncated {
                            truncatedBanner
                        }
                        if !model.catalog.failedSourceIDs.isEmpty {
                            partialFailureBanner
                        }
                        ForEach(displayedSections) { section in
                            Section {
                                ForEach(section.skills) { skill in
                                    CatalogSkillRow(
                                        skill: skill,
                                        sourceName: section.source.displayName,
                                        description: model.catalog.descriptions[skill.id],
                                        isActive: selection == skill.id,
                                        isInstalled: LocalInstallationMatcher.isInstalled(
                                            name: skill.name,
                                            installedNames: installed
                                        ),
                                        highlightQuery: searchText,
                                        onSelect: { onSelect?(skill) }
                                    )
                                    .padding(.horizontal, 8)
                                }
                            } header: {
                                sectionHeader(section)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        case .failed(let failure):
            failedState(failure)
        }
    }

    /// One repository category: its declared display name, skill count,
    /// and the skills themselves (already sorted within the source).
    struct CatalogSection: Identifiable, Equatable {
        let source: CatalogSource
        let skills: [CatalogSkill]
        var id: String { source.id }
    }

    /// Groups the flat listing by the effective sources (built-in plus
    /// imported), keeping the declared order and dropping empty sources.
    /// With `sourceID` set, only that repository's section is produced.
    static func sections(
        of skills: [CatalogSkill],
        sources: [CatalogSource],
        sourceID: String? = nil
    ) -> [CatalogSection] {
        sources.compactMap { source in
            if let sourceID, source.id != sourceID { return nil }
            let group = skills.filter { $0.sourceID == source.id }
            guard !group.isEmpty else { return nil }
            return CatalogSection(source: source, skills: group)
        }
    }

    private func sectionHeader(_ section: CatalogSection) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: section.source.displayName)
                .font(AppTheme.display(12, weight: .semibold))
                .foregroundStyle(AppTheme.muted)
            Text(verbatim: "\(section.skills.count)")
                .font(AppTheme.body(11))
                .foregroundStyle(AppTheme.meta)
            Spacer(minLength: 0)
            if section.source.isCustom {
                Button {
                    model.catalog.removeSource(id: section.source.id)
                    Task { await model.catalog.refresh() }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.muted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.string("Remove Imported Source"))
                .accessibilityLabel(L10n.string("Remove Imported Source"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.background)
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 48)
            ProgressView()
                .controlSize(.small)
            Text(verbatim: L10n.string("Marketplace Loading"))
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
            Text(verbatim: L10n.string("No Marketplace Skills"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: L10n.string("No Marketplace Skills Description"))
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchBar: some View {
        ListSearchBar(placeholderKey: "Search Names Or Descriptions", text: $searchText)
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 48)
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(AppTheme.meta)
            Text(verbatim: L10n.string("No Marketplace Matches"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: L10n.string("No Marketplace Matches Description"))
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var truncatedBanner: some View {
        Label(L10n.string("Marketplace Truncated"), systemImage: "exclamationmark.triangle")
            .font(AppTheme.body(12))
            .foregroundStyle(AppTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 8)
    }

    private var partialFailureBanner: some View {
        Label(L10n.string("Marketplace Partial Failure"), systemImage: "exclamationmark.triangle")
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
            Text(verbatim: L10n.string("Marketplace Failed"))
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

/// One catalog row: skill name, its frontmatter description once the
/// prefetch lands (path until then), and the source badge. Equatable so
/// parent invalidations skip re-rendering unchanged realized rows, and
/// fixed-height so LazyVStack's scroll geometry stays cheap.
struct CatalogSkillRow: View, Equatable {
    let skill: CatalogSkill
    let sourceName: String
    var description: String?
    let isActive: Bool
    /// True when the local index already holds a skill of the same name;
    /// only then does the row show the「已安装」badge (not-installed rows
    /// stay clean).
    var isInstalled: Bool = false
    /// Active search text; hits in the name/description are highlighted.
    var highlightQuery: String = ""
    var onSelect: (() -> Void)?

    nonisolated static func == (lhs: CatalogSkillRow, rhs: CatalogSkillRow) -> Bool {
        lhs.skill == rhs.skill
            && lhs.sourceName == rhs.sourceName
            && lhs.description == rhs.description
            && lhs.isActive == rhs.isActive
            && lhs.isInstalled == rhs.isInstalled
            && lhs.highlightQuery == rhs.highlightQuery
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(isActive ? AppTheme.accentActive : AppTheme.muted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    HighlightedText(
                        text: skill.name,
                        query: highlightQuery,
                        font: AppTheme.body(13, weight: .medium),
                        baseColor: isActive ? AppTheme.accentActive : AppTheme.foreground
                    )
                    .lineLimit(1)
                    if isInstalled {
                        installedBadge
                    }
                }
                if let description, !description.isEmpty {
                    HighlightedText(
                        text: description,
                        query: highlightQuery,
                        font: AppTheme.body(12),
                        baseColor: AppTheme.muted
                    )
                    .lineLimit(1)
                } else {
                    Text(verbatim: skill.skillPath)
                        .font(AppTheme.mono(11))
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            PillBadge(text: sourceName, style: .link)
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(isActive ? AppTheme.accentTint : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect?()
        }
    }

    /// Compact「已安装」pill next to the name — shown only when the local
    /// index has this skill.
    private var installedBadge: some View {
        Text(verbatim: L10n.string("Installed Locally"))
            .font(AppTheme.body(10, weight: .medium))
            .foregroundStyle(AppTheme.success)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(AppTheme.success.opacity(0.12), in: Capsule())
            .lineLimit(1)
            .help(L10n.string("Installed Locally"))
    }
}

/// Localized failure text, shared by the list and detail panes.
enum CatalogFailureMessage {
    static func text(for failure: CatalogLoadFailure) -> String {
        switch failure {
        case .rateLimited:
            L10n.string("Marketplace Failure Rate Limited")
        case .network:
            L10n.string("Marketplace Failure Network")
        case .invalidResponse:
            L10n.string("Marketplace Failure Invalid Response")
        case .http(let status):
            L10n.string("Marketplace Failure HTTP", status)
        }
    }
}

/// 「导入市场」sheet: one text field accepting owner/repo, a GitHub URL,
/// or owner/repo@branch. Import refreshes the catalog with the new
/// source; duplicates and malformed input surface inline.
struct AddCatalogSourceSheet: View {
    var onImport: (CustomCatalogSource) -> Bool
    var onCancel: () -> Void

    @State private var input = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: L10n.string("Import Source"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            TextField(
                L10n.string("Market Source Placeholder"),
                text: $input
            )
            .textFieldStyle(.roundedBorder)
            .font(AppTheme.mono(13))
            Text(verbatim: L10n.string("Market Source Hint"))
                .font(AppTheme.body(12))
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let errorText {
                Text(verbatim: errorText)
                    .font(AppTheme.body(12))
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer(minLength: 0)
                Button(L10n.string("Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.string("Import")) {
                    importSource()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func importSource() {
        guard let custom = CustomCatalogSource.parsing(input) else {
            errorText = L10n.string("Market Source Invalid")
            return
        }
        if onImport(custom) {
            return
        }
        errorText = L10n.string("Market Source Duplicate")
    }
}

extension CustomCatalogSource: Identifiable {
    public var id: String { "\(owner)/\(repo)" }
}

/// 编辑已导入来源（改分支重导）：owner / repo / branch 三个字段，预填当前
/// 值，保存替换原条目并刷新市场。校验规则与导入表单一致。
struct EditCatalogSourceSheet: View {
    let original: CustomCatalogSource
    var onSave: (CustomCatalogSource) -> Bool
    var onCancel: () -> Void

    @State private var owner: String
    @State private var repo: String
    @State private var branch: String
    @State private var errorText: String?

    init(
        original: CustomCatalogSource,
        onSave: @escaping (CustomCatalogSource) -> Bool,
        onCancel: @escaping () -> Void
    ) {
        self.original = original
        self.onSave = onSave
        self.onCancel = onCancel
        _owner = State(initialValue: original.owner)
        _repo = State(initialValue: original.repo)
        _branch = State(initialValue: original.branch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: L10n.string("Edit Imported Source"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            field(L10n.string("Owner"), text: $owner)
            field(L10n.string("Repo"), text: $repo)
            field(L10n.string("Branch"), text: $branch)
            Text(verbatim: L10n.string("Market Source Hint"))
                .font(AppTheme.body(12))
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let errorText {
                Text(verbatim: errorText)
                    .font(AppTheme.body(12))
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer(minLength: 0)
                Button(L10n.string("Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.string("Save")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    owner.trimmingCharacters(in: .whitespaces).isEmpty
                        || repo.trimmingCharacters(in: .whitespaces).isEmpty
                        || branch.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: title)
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
                .frame(width: 56, alignment: .leading)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .font(AppTheme.mono(13))
        }
    }

    private func save() {
        let trimmedOwner = owner.trimmingCharacters(in: .whitespaces)
        let trimmedRepo = repo.trimmingCharacters(in: .whitespaces)
        let trimmedBranch = branch.trimmingCharacters(in: .whitespaces)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !trimmedOwner.isEmpty, trimmedOwner.allSatisfy({ allowed.contains($0) }),
              !trimmedRepo.isEmpty, trimmedRepo.allSatisfy({ allowed.contains($0) }),
              !trimmedBranch.isEmpty, trimmedBranch.allSatisfy({ allowed.contains($0) }) else {
            errorText = L10n.string("Market Source Invalid")
            return
        }
        let custom = CustomCatalogSource(owner: trimmedOwner, repo: trimmedRepo, branch: trimmedBranch)
        if onSave(custom) {
            return
        }
        errorText = L10n.string("Market Source Duplicate")
    }
}
