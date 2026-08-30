import SwiftUI

/// Shared building blocks for the right-pane detail views (Skill / MCP /
/// Rules / Catalog / Markdown document). Kept in one place so the five
/// views don't each re-declare the same label/value rows, section headings
/// and informational shells.
enum DetailViewSupport {
    /// A label/value row for use inside a `Grid`: fixed-width label, value
    /// is selectable and right-flexible, mono typeface opt-in.
    static func keyValueRow(
        _ label: String,
        value: String,
        monospaced: Bool
    ) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(verbatim: label)
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
                .frame(width: 108, alignment: .leading)
            Text(verbatim: value)
                .font(monospaced ? AppTheme.mono(12) : AppTheme.body(13))
                .foregroundStyle(AppTheme.foreground)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A section heading, optionally with a trailing badge capsule (e.g. a
    /// source tag). A single-text `HStack` renders identically to a bare
    /// `Text`, so one shape covers both plain and badged headings.
    static func sectionHeading(
        _ title: String,
        badge: Text? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title)
                .font(AppTheme.display(14, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            if let badge {
                badge
                    .font(AppTheme.body(10.5, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(AppTheme.surface, in: Capsule())
                    .overlay(Capsule().stroke(AppTheme.borderSoft, lineWidth: 1))
            }
        }
    }

    /// A neutral informational shell: bold-ish title over secondary detail.
    static func messageShell(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title)
                .font(.callout.weight(.medium))
            Text(verbatim: detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// An error shell: warning icon + title over a selectable detail line.
    static func errorShell(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
