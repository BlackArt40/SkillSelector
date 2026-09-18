import SwiftUI

/// Shared building blocks for the right-pane detail views (Skill / MCP /
/// Rules / Catalog / Markdown document). Kept in one place so the five
/// views don't each re-declare the same label/value rows, section headings
/// and informational shells.
enum DetailViewSupport {
    /// A label/value row for use inside the detail views' label/value stacks
    /// (a `VStack` of these rows): fixed-width label, value is selectable and
    /// right-flexible, mono typeface opt-in.
    static func keyValueRow(
        _ label: String,
        value: String,
        monospaced: Bool
    ) -> some View {
        // catalog.html's metadata grid (`text-xs`): muted 12 pt key over a
        // fixed 96 px key column, bold 12 pt value.
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: label)
                .font(AppTheme.body(12))
                .foregroundStyle(AppTheme.muted)
                .frame(width: 96, alignment: .leading)
            Text(verbatim: value)
                .font(monospaced ? AppTheme.mono(12, weight: .bold) : AppTheme.body(12, weight: .bold))
                .foregroundStyle(AppTheme.foreground)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A section heading, optionally with a trailing badge tag (e.g. a
    /// source tag). A single-text `HStack` renders identically to a bare
    /// `Text`, so one shape covers both plain and badged headings.
    static func sectionHeading(
        _ title: String,
        badge: Text? = nil
    ) -> some View {
        HStack(spacing: 8) {
            // catalog.html's card headings: `text-xs uppercase
            // tracking-wider text-muted-foreground` — tracking-wider nets
            // zero against the design's negative tracking-normal, so no
            // explicit kerning here.
            Text(verbatim: title)
                .font(AppTheme.body(12, weight: .medium))
                .textCase(.uppercase)
                .foregroundStyle(AppTheme.muted)
            if let badge {
                badge
                    .font(AppTheme.body(11, weight: .bold))
                    .foregroundStyle(AppTheme.foreground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(AppTheme.surfaceMuted)
                    .overlay(Rectangle().stroke(AppTheme.border, lineWidth: 1))
            }
        }
    }

    /// A neutral informational shell: bold-ish title over secondary detail.
    static func messageShell(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title)
                .font(AppTheme.body(13, weight: .medium))
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: detail)
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.foregroundSecondary)
        }
    }

    /// An error shell: warning icon + title over a selectable detail line.
    static func errorShell(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.warn)
            Text(verbatim: detail)
                .font(AppTheme.body(11.5))
                .foregroundStyle(AppTheme.foregroundSecondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
