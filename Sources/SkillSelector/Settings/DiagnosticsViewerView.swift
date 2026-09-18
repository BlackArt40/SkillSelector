import SkillSelectorCore
import SwiftUI

/// diagnostics.html's `#diagnostics-modal`: a 560 pt card on the card fill
/// with the 2 px ink border — header, the system-info and event blocks on
/// bordered page-tone rows, and the right-aligned action footer. The
/// payload is already sanitized by the exporter's redactor.
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
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    systemInfoSection
                    eventsSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            footer
        }
        .frame(width: 560, height: 520)
        .background(AppTheme.surface)
        .overlay(Rectangle().stroke(AppTheme.ink, lineWidth: 2))
        .themedAppearance()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: L10n.string("Diagnostics Viewer Title"))
                .font(AppTheme.display(18, weight: .bold))
                .kerning(-0.9)
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: L10n.string("Diagnostics Viewer Sub"))
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)
        }
    }

    // MARK: System info

    private var systemInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(L10n.string("Diagnostics System Info"))
            VStack(spacing: 0) {
                infoRow(L10n.string("Version"), value: input.appVersion)
                infoRow("macOS", value: input.macOSVersion)
                infoRow(
                    L10n.string("Diagnostics Authorized Roots"),
                    value: String.localizedStringWithFormat(
                        L10n.string("Diagnostics Roots Count"),
                        input.roots.filter(\.isAvailable).count,
                        input.roots.count
                    )
                )
            }
            .overlay(Rectangle().stroke(AppTheme.border, lineWidth: 1))
            if input.roots.contains(where: { !$0.isAvailable }) {
                Label {
                    Text(verbatim: L10n.string("Diagnostics Unavailable Roots"))
                        .font(AppTheme.body(12))
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(AppTheme.warn)
                }
            }
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(verbatim: label)
                .font(AppTheme.body(12))
                .foregroundStyle(AppTheme.muted)
            Spacer(minLength: 16)
            Text(verbatim: value)
                .font(AppTheme.mono(12))
                .foregroundStyle(AppTheme.foreground)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)
        }
    }

    // MARK: Events

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(L10n.string("Diagnostics Events"))
            if input.diagnostics.isEmpty {
                Text(verbatim: L10n.string("Diagnostics Empty"))
                    .font(AppTheme.body(13))
                    .foregroundStyle(AppTheme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(AppTheme.background)
                    .overlay(Rectangle().stroke(AppTheme.border, lineWidth: 1))
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(input.diagnostics.enumerated()), id: \.offset) { _, event in
                        eventRow(event)
                    }
                }
            }
        }
    }

    /// One event row: timestamp, category chip, mono event code, message.
    private func eventRow(_ event: AppDiagnostic) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: Self.timestampFormatter.string(from: event.timestamp))
                .font(AppTheme.mono(12))
                .foregroundStyle(AppTheme.muted)
            Text(verbatim: Self.categoryLabel(event.category))
                .font(AppTheme.body(11))
                .foregroundStyle(AppTheme.foreground)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(AppTheme.surface)
                .overlay(Rectangle().stroke(AppTheme.ink, lineWidth: 1))
            Text(verbatim: event.code)
                .font(AppTheme.mono(12, weight: .bold))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(1)
            Text(verbatim: event.message)
                .font(AppTheme.body(12))
                .foregroundStyle(AppTheme.foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.background)
        .overlay(Rectangle().stroke(AppTheme.border, lineWidth: 1))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            Button(L10n.string("Close"), role: .cancel) {
                dismiss()
            }
            .buttonStyle(ModalToolButtonStyle(kind: .secondary))
            .keyboardShortcut(.cancelAction)
            Button(L10n.string("Export…"), action: onExport)
                .buttonStyle(ModalToolButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .help(L10n.string("Export Redacted Diagnostics"))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)
        }
    }

    // MARK: Helpers

    private func sectionHeading(_ title: String) -> some View {
        Text(verbatim: title)
            .font(AppTheme.body(13, weight: .bold))
            .foregroundStyle(AppTheme.foreground)
    }

    /// Localized category labels — the raw enum cases are internal
    /// identifiers, not user-facing copy.
    private static func categoryLabel(_ category: AppLogCategory) -> String {
        switch category {
        case .scanning: L10n.string("Diagnostics Category Scanning")
        case .persistence: L10n.string("Diagnostics Category Persistence")
        case .operations: L10n.string("Diagnostics Category Operations")
        }
    }
}
