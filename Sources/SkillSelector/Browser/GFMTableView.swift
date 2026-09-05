import SkillSelectorCore
import SwiftUI

/// The app's own GFM table renderer, used on every supported macOS version in
/// place of MarkdownUI's `TableView` — that one is gated behind macOS 13 with
/// no fallback, so at a macOS 12 deployment target it would render tables
/// empty. Styling mirrors the fenced code panel: `AppTheme.border` outline,
/// 6pt corner radius, 8/12 cell padding.
///
/// Layout is row-major — a `VStack` of row `HStack`s inside a horizontal
/// `ScrollView` — with each column sized to its widest cell. `Grid` needs
/// macOS 13, so cell widths are measured through a preference key and applied
/// as a fixed frame, with content aligned inside the column per the
/// delimiter row's alignment. Cells render inline markdown through
/// `AttributedString` (a macOS 12 API) with a verbatim fallback; links fall
/// through to the surrounding `markdownLinkPolicy()` environment.
struct GFMTableView: View {
    let table: GFMTable

    /// Measured width of each column's widest cell, keyed by column index.
    /// Empty until the first measurement pass lands; cells then render at
    /// their natural width and re-render into equalized columns.
    @State private var columnWidths: [Int: CGFloat] = [:]

    init(table: GFMTable) {
        self.table = table
    }

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                ForEach(table.rows.indices, id: \.self) { rowIndex in
                    dataRow(at: rowIndex)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(AppTheme.border, lineWidth: 1)
        )
        // A changed table must not inherit the previous table's measured
        // column widths.
        .id(table)
        .onPreferenceChange(ColumnWidthKey.self) { widths in
            columnWidths = widths
        }
    }

    // MARK: Rows

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(table.header.indices, id: \.self) { column in
                headerCell(for: column)
            }
        }
        .background(AppTheme.surfaceWarm)
    }

    private func dataRow(at index: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(table.header.indices, id: \.self) { column in
                dataCell(row: index, column: column)
            }
        }
        .background(index.isMultiple(of: 2) ? AppTheme.surface : Color.clear)
    }

    // MARK: Cells

    private func headerCell(for column: Int) -> some View {
        cellText(table.header[column])
            .fontWeight(.semibold)
            .foregroundColor(AppTheme.foreground)
            .fixedSize(horizontal: true, vertical: false)
            .background(ColumnWidthReader(column: column))
            .frame(width: columnWidths[column], alignment: alignment(for: column))
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
    }

    private func dataCell(row: Int, column: Int) -> some View {
        let cells = table.rows[row]
        let value = column < cells.count ? cells[column] : ""
        return cellText(value)
            .foregroundColor(AppTheme.foregroundSecondary)
            .fixedSize(horizontal: true, vertical: false)
            .background(ColumnWidthReader(column: column))
            .frame(width: columnWidths[column], alignment: alignment(for: column))
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
    }

    /// Inline-only markdown cell text with a verbatim fallback for cells
    /// whose markdown cannot be parsed inline.
    private func cellText(_ cell: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: cell,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return Text(attributed)
        }
        return Text(verbatim: cell)
    }

    private func alignment(for column: Int) -> HorizontalAlignment {
        guard table.alignments.indices.contains(column) else { return .leading }
        switch table.alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// Reports the natural width of one cell so the table can equalize every
/// column to its widest cell. Placed behind the cell text, before the fixed
/// column frame, so the measured size is always the natural text width.
private struct ColumnWidthReader: View {
    let column: Int

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ColumnWidthKey.self,
                value: [column: proxy.size.width]
            )
        }
    }
}

private struct ColumnWidthKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}
