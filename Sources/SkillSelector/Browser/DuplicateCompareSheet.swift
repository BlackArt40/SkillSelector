import SkillSelectorCore
import SwiftUI

/// Identifiable presentation request for the copy-comparison sheet: a
/// fresh identity re-presents the sheet even when the same group is
/// compared twice in a row.
struct DuplicateCompareRequest: Identifiable {
    let id = UUID()
    let members: [SkillSnapshot]
}

/// The read-only copy comparison: two member pickers over the group, then
/// frontmatter / body / sibling-file deltas. Purely informational — the
/// tidying itself still happens in Finder.
struct DuplicateCompareSheet: View {
    @Environment(\.dismiss) private var dismiss

    let members: [SkillSnapshot]
    let agentNamesByID: [String: String]
    let loadComparison: (SkillSnapshot, SkillSnapshot) async throws -> SkillComparison

    @State private var leftPath: String
    @State private var rightPath: String
    @State private var comparison: SkillComparison?
    @State private var loadError: String?
    @State private var isLoading = false

    init(
        request: DuplicateCompareRequest,
        agentNamesByID: [String: String],
        loadComparison: @escaping (SkillSnapshot, SkillSnapshot) async throws -> SkillComparison
    ) {
        members = request.members
        self.agentNamesByID = agentNamesByID
        self.loadComparison = loadComparison
        _leftPath = State(initialValue: request.members.first?.path ?? "")
        _rightPath = State(initialValue: request.members.count > 1
            ? request.members[1].path
            : request.members.first?.path ?? "")
    }

    private var left: SkillSnapshot? {
        members.first { $0.path == leftPath }
    }

    private var right: SkillSnapshot? {
        members.first { $0.path == rightPath }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(AppTheme.borderSoft).frame(height: 1)
            pickerBar
            Rectangle().fill(AppTheme.borderSoft).frame(height: 1)
            content
        }
        .frame(width: 760, height: 600)
        .background(AppTheme.background)
        .themedAppearance()
        .task(id: "\(leftPath)|\(rightPath)") {
            await reload()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: L10n.string("Compare Copies"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            Spacer(minLength: 8)
            Button(L10n.string("Close")) {
                dismiss()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var pickerBar: some View {
        HStack(spacing: 12) {
            copyPicker(
                title: L10n.string("Left Copy"),
                selection: $leftPath,
                color: AppTheme.muted
            )
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.meta)
            copyPicker(
                title: L10n.string("Right Copy"),
                selection: $rightPath,
                color: AppTheme.muted
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func copyPicker(title: String, selection: Binding<String>, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
                .font(AppTheme.body(12, weight: .medium))
                .foregroundStyle(color)
            Picker(title, selection: selection) {
                ForEach(members) { member in
                    Text(verbatim: member.name)
                        .tag(member.path)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: L10n.string("Loading Comparison"))
                    .font(AppTheme.body(13))
                    .foregroundStyle(AppTheme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 8) {
                Text(verbatim: L10n.string("Comparison Failed"))
                    .font(AppTheme.display(15, weight: .semibold))
                    .foregroundStyle(AppTheme.foreground)
                Text(verbatim: loadError)
                    .font(AppTheme.body(12))
                    .foregroundStyle(AppTheme.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let comparison {
            comparisonSections(comparison)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func comparisonSections(_ comparison: SkillComparison) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                frontmatterSection(comparison)
                bodySection(comparison)
                filesSection(comparison)
            }
            .padding(16)
        }
    }

    // MARK: Frontmatter

    @ViewBuilder
    private func frontmatterSection(_ comparison: SkillComparison) -> some View {
        section(title: L10n.string("Frontmatter Differences")) {
            if comparison.frontmatter.isEmpty {
                emptyNote(L10n.string("No Frontmatter"))
            } else {
                VStack(spacing: 0) {
                    ForEach(
                        Array(comparison.frontmatter.enumerated()),
                        id: \.element.id
                    ) { index, field in
                        frontmatterRow(field, isLast: index == comparison.frontmatter.count - 1)
                    }
                }
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(AppTheme.borderSoft, lineWidth: 1)
                }
            }
        }
    }

    private func frontmatterRow(
        _ field: SkillComparison.FrontmatterField,
        isLast: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: field.key)
                    .font(AppTheme.body(12, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
                    .frame(width: 130, alignment: .leading)
                Text(verbatim: field.left ?? L10n.string("Missing Value"))
                    .font(AppTheme.body(12))
                    .foregroundStyle(field.isDifferent ? AppTheme.foreground : AppTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                Rectangle().fill(AppTheme.borderSoft).frame(width: 1)
                    .padding(.vertical, 0)
                Text(verbatim: field.right ?? L10n.string("Missing Value"))
                    .font(AppTheme.body(12))
                    .foregroundStyle(field.isDifferent ? AppTheme.foreground : AppTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                    .padding(.leading, 12)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                field.isDifferent
                    ? AppTheme.accentTintFaint.opacity(0.5)
                    : Color.clear
            )
            if !isLast {
                Rectangle().fill(AppTheme.borderSoft).frame(height: 1)
            }
        }
    }

    // MARK: Body

    @ViewBuilder
    private func bodySection(_ comparison: SkillComparison) -> some View {
        section(title: L10n.string("Body Differences")) {
            if comparison.bodiesAreIdentical {
                emptyNote(L10n.string("Bodies Are Identical"))
            } else {
                diffRows(comparison.bodyDiff)
            }
        }
    }

    /// Diff rows with long identical runs collapsed to context markers, so
    /// a small edit inside a long body stays visible without scrolling
    /// through hundreds of unchanged lines.
    private func diffRows(_ diff: LineDiff) -> some View {
        let display = Self.collapsedRows(diff.rows, context: 3)
        return VStack(spacing: 0) {
            ForEach(display) { row in
                diffRow(row)
            }
        }
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppTheme.borderSoft, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func diffRow(_ row: CollapsedDiffRow) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(verbatim: row.marker)
                .font(AppTheme.body(11, weight: .semibold))
                .foregroundStyle(row.markerColor)
                .frame(width: 24, alignment: .center)
            Text(verbatim: row.text.isEmpty ? " " : row.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(row.textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1.5)
        .background(row.background)
    }

    // MARK: Files

    @ViewBuilder
    private func filesSection(_ comparison: SkillComparison) -> some View {
        section(title: L10n.string("File Differences")) {
            let differing = comparison.files.filter { $0.difference != .identical }
            let identical = comparison.files.count - differing.count
            if differing.isEmpty {
                emptyNote(L10n.string("All Files Identical"))
            } else {
                VStack(spacing: 2) {
                    ForEach(differing) { entry in
                        fileRow(entry)
                    }
                    if identical > 0 {
                        Text(verbatim: String.localizedStringWithFormat(
                            L10n.string("Identical Files Omitted"), identical
                        ))
                        .font(AppTheme.body(11))
                        .foregroundStyle(AppTheme.meta)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                    }
                }
            }
        }
    }

    private func fileRow(_ entry: SkillComparison.FileEntry) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: entry.relativePath)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(verbatim: fileDifferenceLabel(entry.difference))
                .font(AppTheme.body(11, weight: .medium))
                .foregroundStyle(fileDifferenceColor(entry.difference))
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(AppTheme.surface, in: Capsule())
                .overlay {
                    Capsule().stroke(AppTheme.borderSoft, lineWidth: 1)
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(AppTheme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func fileDifferenceLabel(_ difference: SkillComparison.FileDifference) -> String {
        switch difference {
        case .leftOnly: L10n.string("Left Only")
        case .rightOnly: L10n.string("Right Only")
        case .kindMismatch: L10n.string("Kind Mismatch")
        case .sizeDiffers: L10n.string("Size Differs")
        case .identical: L10n.string("Identical")
        }
    }

    private func fileDifferenceColor(_ difference: SkillComparison.FileDifference) -> Color {
        switch difference {
        case .leftOnly, .rightOnly, .kindMismatch: AppTheme.danger
        case .sizeDiffers: AppTheme.warn
        case .identical: AppTheme.muted
        }
    }

    // MARK: Helpers

    private func section(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(AppTheme.display(13, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(verbatim: text)
            .font(AppTheme.body(12))
            .foregroundStyle(AppTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func reload() async {
        guard let left, let right, left.path != right.path, !isLoading else { return }
        isLoading = true
        loadError = nil
        comparison = nil
        do {
            comparison = try await loadComparison(left, right)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        isLoading = false
    }

    // MARK: Diff collapsing

    struct CollapsedDiffRow: Identifiable {
        enum Kind {
            case same
            case added
            case removed
            case ellipses
        }

        let id: Int
        let kind: Kind
        let text: String

        var marker: String {
            switch kind {
            case .same: " "
            case .added: "+"
            case .removed: "-"
            case .ellipses: " "
            }
        }

        var markerColor: Color {
            switch kind {
            case .same: AppTheme.meta
            case .added: AppTheme.success
            case .removed: AppTheme.danger
            case .ellipses: AppTheme.meta
            }
        }

        var textColor: Color {
            switch kind {
            case .same: AppTheme.muted
            case .added, .removed: AppTheme.foreground
            case .ellipses: AppTheme.meta
            }
        }

        var background: Color {
            switch kind {
            case .same: .clear
            case .added: AppTheme.success.opacity(0.09)
            case .removed: AppTheme.danger.opacity(0.08)
            case .ellipses: AppTheme.surface.opacity(0.6)
            }
        }
    }

    /// Collapses runs of identical lines longer than `context * 2 + 1` to
    /// `context` lines on each side plus an "N identical lines hidden"
    /// marker.
    static func collapsedRows(
        _ rows: [LineDiff.Row],
        context: Int
    ) -> [CollapsedDiffRow] {
        var result: [CollapsedDiffRow] = []
        var index = 0
        var nextID = 0
        while index < rows.count {
            guard rows[index].kind == .same else {
                result.append(CollapsedDiffRow(
                    id: nextID, kind: kind(of: rows[index]), text: rows[index].text
                ))
                nextID += 1
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < rows.count, rows[runEnd].kind == .same {
                runEnd += 1
            }
            let runLength = runEnd - index
            let keepHead = index == 0 ? 0 : min(context, runLength)
            let keepTail = runEnd == rows.count ? 0 : min(context, runLength - keepHead)
            for offset in 0..<keepHead {
                result.append(CollapsedDiffRow(
                    id: nextID, kind: .same, text: rows[index + offset].text
                ))
                nextID += 1
            }
            let hidden = runLength - keepHead - keepTail
            if hidden > 0 {
                result.append(CollapsedDiffRow(
                    id: nextID,
                    kind: .ellipses,
                    text: String.localizedStringWithFormat(
                        L10n.string("Identical Lines Hidden"), hidden
                    )
                ))
                nextID += 1
            }
            for offset in 0..<keepTail {
                result.append(CollapsedDiffRow(
                    id: nextID, kind: .same, text: rows[runEnd - keepTail + offset].text
                ))
                nextID += 1
            }
            index = runEnd
        }
        return result
    }

    private static func kind(of row: LineDiff.Row) -> CollapsedDiffRow.Kind {
        switch row.kind {
        case .same: .same
        case .added: .added
        case .removed: .removed
        }
    }
}
