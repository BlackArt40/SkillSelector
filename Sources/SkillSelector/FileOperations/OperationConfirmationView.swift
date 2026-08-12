import SkillSelectorCore
import SwiftUI

/// The `.dialog` from the design: 460 pt card with a route block showing
/// the source and destination paths in mono, and 取消 + confirm actions.
struct OperationConfirmationView: View {
    let plan: FileOperationPlan
    let isOperating: Bool
    let onConflictChange: (FileConflictPolicy) -> Void
    let onCancel: () -> Void
    let onConfirm: (Bool) -> Void

    @State private var selectedConflict: FileConflictPolicy
    @State private var replacementConfirmed = false

    init(
        plan: FileOperationPlan,
        isOperating: Bool,
        onConflictChange: @escaping (FileConflictPolicy) -> Void,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (Bool) -> Void
    ) {
        self.plan = plan
        self.isOperating = isOperating
        self.onConflictChange = onConflictChange
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _selectedConflict = State(initialValue: plan.conflictPolicy)
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

            routeBlock
                .padding(.top, 16)

            if plan.operation != .delete, plan.hadDestinationConflict {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: L10n.string("Name Conflict"))
                        .font(AppTheme.body(12, weight: .medium))
                        .foregroundStyle(AppTheme.muted)
                    Picker(L10n.string("Name Conflict"), selection: $selectedConflict) {
                        Text(verbatim: L10n.string("Keep Both")).tag(FileConflictPolicy.keepBoth)
                        Text(verbatim: L10n.string("Replace")).tag(FileConflictPolicy.replace)
                        Text(verbatim: L10n.string("Cancel")).tag(FileConflictPolicy.cancel)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(isOperating)
                    .onChange(of: selectedConflict) { _, newValue in
                        replacementConfirmed = false
                        onConflictChange(newValue)
                    }
                }
                .padding(.top, 16)
            }

            if plan.operation == .delete {
                disclosure(
                    L10n.string("This Skill will be moved to Trash."),
                    icon: "trash"
                )
                .padding(.top, 16)
            }
            if plan.movesExistingDestinationToTrash {
                disclosure(
                    L10n.string("The existing destination will be moved to Trash before replacement."),
                    icon: "exclamationmark.triangle"
                )
                .padding(.top, 16)
                Toggle(
                    L10n.string("I confirm replacing the existing Skill."),
                    isOn: $replacementConfirmed
                )
                .font(AppTheme.body(13))
                .toggleStyle(.checkbox)
                .padding(.top, 8)
                .accessibilityLabel(L10n.string("Confirm replacement"))
            }
            if !plan.affectedIndexedAliases.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: L10n.string("Affected Installations"))
                        .font(AppTheme.body(13, weight: .semibold))
                    ForEach(plan.affectedIndexedAliases, id: \.self) { path in
                        Text(verbatim: path)
                            .font(AppTheme.mono(11.5))
                            .foregroundStyle(AppTheme.foregroundSecondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 16)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(L10n.string("Cancel"), role: .cancel, action: onCancel)
                    .buttonStyle(ActionButtonStyle(role: .secondary))
                    .keyboardShortcut(.cancelAction)
                    .disabled(isOperating)
                Button(action: { onConfirm(replacementConfirmed) }) {
                    if isOperating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(verbatim: confirmTitle)
                    }
                }
                .buttonStyle(ActionButtonStyle(role: plan.operation == .delete ? .dangerSolid : .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isOperating
                        || selectedConflict == .cancel
                        || (plan.movesExistingDestinationToTrash && !replacementConfirmed)
                )
                .help(L10n.string("Confirm file operation"))
                .accessibilityLabel(confirmTitle)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 460)
        .background(AppTheme.background)
        .interactiveDismissDisabled(isOperating)
    }

    /// `.op-route` — surface block with route labels and mono paths.
    private var routeBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            routeLine(L10n.string("Source"), plan.logicalSourceURL.path)
            if plan.resolvedSourceURL != plan.logicalSourceURL {
                routeLine(L10n.string("Resolved Target"), plan.resolvedSourceURL.path)
            }
            if let destination = plan.destinationURL {
                routeLine(L10n.string("Destination"), destination.path)
            }
            if let linkTarget = plan.linkTarget {
                routeLine(L10n.string("Symbolic Link Target"), linkTarget)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func routeLine(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: label)
                .font(AppTheme.body(11, weight: .semibold))
                .foregroundStyle(AppTheme.meta)
            Text(verbatim: value)
                .font(AppTheme.mono(11.5))
                .foregroundStyle(AppTheme.foregroundSecondary)
                .textSelection(.enabled)
                .lineLimit(4)
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

    private var operationTitle: String {
        switch plan.operation {
        case .copy: L10n.string("Confirm Copy")
        case .move: L10n.string("Confirm Move")
        case .delete: L10n.string("Confirm Move to Trash")
        case .createSymbolicLink: L10n.string("Confirm Create Link")
        }
    }

    private var operationDescription: String {
        switch plan.operation {
        case .copy: L10n.string("Copy Description")
        case .move: L10n.string("Move Description")
        case .delete: L10n.string("Delete Description")
        case .createSymbolicLink: L10n.string("Link Description")
        }
    }

    private var confirmTitle: String {
        switch plan.operation {
        case .copy: L10n.string("Copy To Current Folder")
        case .move: L10n.string("Move To Current Folder")
        case .delete: L10n.string("Move to Trash")
        case .createSymbolicLink: L10n.string("Create Link")
        }
    }
}
