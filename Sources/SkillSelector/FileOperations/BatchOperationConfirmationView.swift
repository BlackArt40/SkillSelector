import SkillSelectorCore
import SwiftUI

/// The batch variant of the operation dialog: one summary card for the
/// whole multi-selection instead of one sheet per Skill.
struct BatchOperationConfirmationView: View {
    let batch: PendingBatchOperation
    let isOperating: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var operationTitle: String {
        let format = L10n.string(
            batch.operation == .delete
                ? "Confirm Batch Move to Trash"
                : batch.operation == .copy ? "Confirm Batch Copy" : "Confirm Batch Move"
        )
        return String.localizedStringWithFormat(format, batch.entries.count)
    }

    private var operationDescription: String {
        let format = L10n.string(
            batch.operation == .delete
                ? "Batch Delete Description"
                : batch.operation == .copy ? "Batch Copy Description" : "Batch Move Description"
        )
        return String.localizedStringWithFormat(format, batch.entries.count)
    }

    private var confirmTitle: String {
        let format = L10n.string(
            batch.operation == .delete
                ? "Move %d Items to Trash"
                : batch.operation == .copy ? "Copy %d Items" : "Move %d Items"
        )
        return String.localizedStringWithFormat(format, batch.entries.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: operationTitle)
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(1)

            Text(verbatim: operationDescription)
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
                .lineSpacing(3)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                if let destination = batch.destinationURL {
                    routeLine(L10n.string("Destination"), destination.path)
                }
                routeLine(L10n.string("Skills"), "")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(batch.entries, id: \.skill.path) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: entry.skill.name)
                                .font(AppTheme.body(12, weight: .medium))
                                .foregroundStyle(AppTheme.foreground)
                                .lineLimit(1)
                            Text(verbatim: entry.skill.path)
                                .font(AppTheme.mono(11))
                                .foregroundStyle(AppTheme.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 180)

            if batch.operation == .delete {
                disclosure(L10n.string("These Skills will be moved to Trash."), icon: "trash")
                    .padding(.top, 12)
            } else {
                disclosure(
                    L10n.string("Name conflicts keep both Skills; replacements need a single-Skill operation."),
                    icon: "exclamationmark.triangle"
                )
                .padding(.top, 12)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(L10n.string("Cancel"), role: .cancel, action: onCancel)
                    .buttonStyle(ActionButtonStyle(role: .secondary))
                    .keyboardShortcut(.cancelAction)
                    .disabled(isOperating)
                Button(action: onConfirm) {
                    if isOperating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(verbatim: confirmTitle)
                    }
                }
                .buttonStyle(ActionButtonStyle(role: batch.operation == .delete ? .dangerSolid : .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(isOperating)
                .help(L10n.string("Confirm file operation"))
                .accessibilityLabel(confirmTitle)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 520)
        .background(AppTheme.background)
        .interactiveDismissDisabled(isOperating)
    }

    private func routeLine(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: label)
                .font(AppTheme.body(11, weight: .semibold))
                .foregroundStyle(AppTheme.meta)
            if !value.isEmpty {
                Text(verbatim: value)
                    .font(AppTheme.mono(11.5))
                    .foregroundStyle(AppTheme.foregroundSecondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private func disclosure(_ text: String, icon: String) -> some View {
        Label {
            Text(verbatim: text)
                .font(AppTheme.body(13))
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.orange)
        }
    }
}
