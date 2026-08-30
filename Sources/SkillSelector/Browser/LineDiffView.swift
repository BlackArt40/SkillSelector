import SkillSelectorCore
import SwiftUI

/// A collapsed line-diff view: long runs of identical lines shrink to a few
/// context lines plus an "N identical lines hidden" marker, so a small edit
/// inside a long body stays visible without scrolling through hundreds of
/// unchanged lines. Shared by the copy-comparison sheet and the rules-file
/// same-name comparison.
struct LineDiffView: View {
    struct Row: Identifiable {
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
            case .same, .ellipses: " "
            case .added: "+"
            case .removed: "-"
            }
        }

        var markerColor: Color {
            switch kind {
            case .same, .ellipses: AppTheme.meta
            case .added: AppTheme.success
            case .removed: AppTheme.danger
            }
        }

        var textColor: Color {
            switch kind {
            case .same, .ellipses: AppTheme.meta
            case .added, .removed: AppTheme.foreground
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

    let diff: LineDiff
    var context: Int = 3

    var body: some View {
        let rows = Self.collapsedRows(diff.rows, context: context)
        VStack(spacing: 0) {
            ForEach(rows) { row in
                rowView(row)
            }
        }
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppTheme.borderSoft, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func rowView(_ row: Row) -> some View {
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

    /// Collapses runs of identical lines longer than `context * 2 + 1` to
    /// `context` lines on each side plus an "N identical lines hidden" marker.
    static func collapsedRows(_ rows: [LineDiff.Row], context: Int) -> [Row] {
        var result: [Row] = []
        var index = 0
        var nextID = 0
        while index < rows.count {
            guard rows[index].kind == .same else {
                result.append(Row(id: nextID, kind: kind(of: rows[index]), text: rows[index].text))
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
                result.append(Row(id: nextID, kind: .same, text: rows[index + offset].text))
                nextID += 1
            }
            let hidden = runLength - keepHead - keepTail
            if hidden > 0 {
                result.append(Row(
                    id: nextID,
                    kind: .ellipses,
                    text: String.localizedStringWithFormat(
                        L10n.string("Identical Lines Hidden"), hidden
                    )
                ))
                nextID += 1
            }
            for offset in 0..<keepTail {
                result.append(Row(
                    id: nextID, kind: .same, text: rows[runEnd - keepTail + offset].text
                ))
                nextID += 1
            }
            index = runEnd
        }
        return result
    }

    private static func kind(of row: LineDiff.Row) -> Row.Kind {
        switch row.kind {
        case .same: .same
        case .added: .added
        case .removed: .removed
        }
    }
}
