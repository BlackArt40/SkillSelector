import SkillSelectorCore
import SwiftUI

/// Read-only in-app view of the redacted diagnostics the JSON export
/// carries: environment header, root availability, and the recent event
/// log. The payload is already sanitized by the exporter's redactor.
struct DiagnosticsViewerView: View {
    let input: DiagnosticExportInput
    let onExport: () -> Void

    @Environment(\.dismiss) private var dismiss

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: L10n.string("Diagnostics Viewer Title"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: L10n.string("Diagnostics Viewer Sub"))
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 6) {
                infoLine(L10n.string("Version Line", input.appVersion))
                infoLine("macOS \(input.macOSVersion)")
                infoLine(String.localizedStringWithFormat(
                    L10n.string("Diagnostics Roots Count"),
                    input.roots.filter(\.isAvailable).count,
                    input.roots.count
                ))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 14)

            if input.roots.contains(where: { !$0.isAvailable }) {
                Label {
                    Text(verbatim: L10n.string("Diagnostics Unavailable Roots"))
                        .font(AppTheme.body(12.5))
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                .padding(.top, 10)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: L10n.string("Diagnostics Events"))
                    .font(AppTheme.body(12, weight: .semibold))
                    .foregroundStyle(AppTheme.muted)
                    .padding(.bottom, 8)
                if input.diagnostics.isEmpty {
                    Text(verbatim: L10n.string("Diagnostics Empty"))
                        .font(AppTheme.body(13))
                        .foregroundStyle(AppTheme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(input.diagnostics.enumerated()), id: \.offset) { _, event in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(verbatim: Self.timestampFormatter.string(from: event.timestamp))
                                            .font(AppTheme.mono(10.5))
                                            .foregroundStyle(AppTheme.meta)
                                        Text(verbatim: event.category.rawValue)
                                            .font(AppTheme.body(10.5, weight: .semibold))
                                            .foregroundStyle(AppTheme.muted)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(AppTheme.surfaceWarm, in: Capsule())
                                        Text(verbatim: event.code)
                                            .font(AppTheme.mono(11))
                                            .foregroundStyle(AppTheme.foregroundSecondary)
                                            .lineLimit(1)
                                    }
                                    Text(verbatim: event.message)
                                        .font(AppTheme.body(12))
                                        .foregroundStyle(AppTheme.foregroundSecondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal, 2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(.top, 16)

            HStack(spacing: 8) {
                Spacer()
                Button(L10n.string("Close"), role: .cancel) {
                    dismiss()
                }
                .buttonStyle(ActionButtonStyle(role: .secondary))
                .keyboardShortcut(.cancelAction)
                Button(L10n.string("Export…"), action: onExport)
                    .buttonStyle(ActionButtonStyle(role: .primary))
                    .keyboardShortcut(.defaultAction)
                    .help(L10n.string("Export Redacted Diagnostics"))
            }
            .padding(.top, 18)
        }
        .padding(24)
        .frame(width: 560, height: 520)
        .background(AppTheme.background)
    }

    private func infoLine(_ text: String) -> some View {
        Text(verbatim: text)
            .font(AppTheme.body(12.5))
            .foregroundStyle(AppTheme.foregroundSecondary)
    }
}
