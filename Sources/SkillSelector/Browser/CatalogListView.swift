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
    @EnvironmentObject private var model: AppModel
    let state: CatalogState
    var selection: String?
    var onSelect: ((CatalogSkill) -> Void)?
    var onRefresh: (() -> Void)?

    /// Repository filter from the column header; nil shows every source.
    @State private var selectedSourceID: String?
    @State private var showingAddSheet = false
    /// Lift state for the ink-chrome source pull-down label.
    @State private var filterHovering = false
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

    /// catalog.html's market toolbar (`space-y-3 border-b-2 border-ring
    /// p-4`): 18 pt bold title with an ink count badge, the source
    /// pull-down and 导入市场 ink buttons, then the 2 px ink search field —
    /// a 16 pt padded block closed by a full-width 2 px ink rule.
    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(verbatim: L10n.string("Marketplace"))
                    .font(AppTheme.display(18, weight: .bold))
                    .kerning(-0.9)
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(1)
                if displayedCount > 0 {
                    InkBadge(text: "\(displayedCount)")
                }
                Spacer(minLength: 8)
                sourceFilterPicker
                addSourceButton
                refreshButton
            }
            if case .loaded = state {
                ListSearchBar(
                    placeholderKey: "Search Names Or Descriptions",
                    text: $searchText,
                    style: .ink
                )
            }
        }
        .padding(16)
        .background(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.ink)
                .frame(height: 2)
        }
        .background(AppTheme.background)
    }

    /// Repository category filter: every declared source plus the
    /// everything option, pulled down from an ink button label
    /// (`border-2 border-ring … chevron-down` in the design).
    private var sourceFilterPicker: some View {
        Menu {
            Picker("Marketplace Source Filter", selection: $selectedSourceID) {
                Text(verbatim: L10n.string("All Sources")).tag(String?.none)
                ForEach(model.catalog.sources) { source in
                    Text(verbatim: source.displayName).tag(Optional(source.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: sourceFilterTitle)
                    .font(AppTheme.body(14, weight: .bold))
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.muted)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(AppTheme.surface)
            .overlay {
                Rectangle().stroke(AppTheme.ink, lineWidth: 2)
            }
            .hardShadow(.rest)
            .offset(x: filterHovering ? -1 : 0, y: filterHovering ? -1 : 0)
            .onHover { filterHovering = $0 }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L10n.string("Marketplace Source Filter"))
    }

    private var sourceFilterTitle: String {
        guard let id = selectedSourceID,
              let source = model.catalog.sources.first(where: { $0.id == id }) else {
            return L10n.string("All Sources")
        }
        return source.displayName
    }

    /// 「导入市场」: primary ink button — opens the import sheet for a
    /// user-declared GitHub source.
    private var addSourceButton: some View {
        Button {
            showingAddSheet = true
        } label: {
            Text(verbatim: L10n.string("Import Source"))
        }
        .buttonStyle(InkButtonStyle())
        .help(L10n.string("Import Source"))
        .accessibilityLabel(L10n.string("Import Source"))
    }

    /// Not in catalog.html, but refresh is core catalog functionality —
    /// rendered as an ink icon button so it matches the toolbar chrome.
    private var refreshButton: some View {
        Button {
            onRefresh?()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .bold))
        }
        .buttonStyle(InkButtonStyle())
        .disabled(isLoading)
        .help(L10n.string("Refresh Marketplace"))
        .accessibilityLabel(L10n.string("Refresh Marketplace"))
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
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
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
                                }
                            } header: {
                                sectionHeader(section)
                            }
                        }
                    }
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

    /// catalog.html's source banner (`text-xs uppercase tracking-wider
    /// text-muted-foreground`): the per-source sticky header keeps the
    /// functional remove action and count on the right.
    private func sectionHeader(_ section: CatalogSection) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: section.source.displayName)
                .font(AppTheme.body(12, weight: .medium))
                .textCase(.uppercase)
                .foregroundStyle(AppTheme.muted)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: "\(section.skills.count)")
                .font(AppTheme.body(12))
                .foregroundStyle(AppTheme.muted)
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
        MarketplaceSkeleton()
    }

    private var emptyState: some View {
        EmptyState(
            icon: "sparkles",
            title: L10n.string("No Marketplace Skills"),
            message: L10n.string("No Marketplace Skills Description")
        )
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
                .font(AppTheme.display(18, weight: .bold))
                .kerning(-0.9)
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
            .background(AppTheme.surfaceWarm, in: Rectangle())
            .overlay {
                Rectangle().stroke(AppTheme.warn, lineWidth: 1)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
    }

    private var partialFailureBanner: some View {
        Label(L10n.string("Marketplace Partial Failure"), systemImage: "exclamationmark.triangle")
            .font(AppTheme.body(12))
            .foregroundStyle(AppTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(AppTheme.surfaceWarm, in: Rectangle())
            .overlay {
                Rectangle().stroke(AppTheme.warn, lineWidth: 1)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
    }

    private func failedState(_ failure: CatalogLoadFailure) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 48)
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundStyle(AppTheme.meta)
            Text(verbatim: L10n.string("Marketplace Failed"))
                .font(AppTheme.display(18, weight: .bold))
                .kerning(-0.9)
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: CatalogFailureMessage.text(for: failure))
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(L10n.string("Retry")) {
                onRefresh?()
            }
            .buttonStyle(InkButtonStyle())
            .padding(.top, 4)
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One catalog row (catalog.html `h-14 … border-b px-4`): ink-chrome
/// avatar tile, skill name, its frontmatter description once the
/// prefetch lands (path until then), and the installed chip. Equatable
/// so parent invalidations skip re-rendering unchanged realized rows,
/// and fixed-height so LazyVStack's scroll geometry stays cheap.
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
        HStack(spacing: 12) {
            SkillTileView(title: skill.name, size: 32, inkBorder: true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    HighlightedText(
                        text: skill.name,
                        query: highlightQuery,
                        font: AppTheme.body(14, weight: .bold),
                        baseColor: isActive ? AppTheme.accentForeground : AppTheme.foreground
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
                        baseColor: isActive ? AppTheme.accentForeground.opacity(0.8) : AppTheme.muted
                    )
                    .lineLimit(1)
                } else {
                    Text(verbatim: skill.skillPath)
                        .font(AppTheme.mono(11))
                        .foregroundStyle(isActive ? AppTheme.accentForeground.opacity(0.8) : AppTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(isActive ? AppTheme.accent : Color.clear)
        .background(alignment: .bottom) {
            Rectangle().fill(AppTheme.border).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect?()
        }
    }

    /// Rectangular「已安装」chip next to the name — catalog.html's
    /// `border-2 border-ring bg-sidebar-accent … text-[11px] font-bold`
    /// badge, shown only when the local index has this skill.
    private var installedBadge: some View {
        InkBadge(text: L10n.string("Installed Locally"))
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
                    .foregroundStyle(AppTheme.warn)
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
                    .foregroundStyle(AppTheme.warn)
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
