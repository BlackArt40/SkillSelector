import SkillSelectorCore
import SwiftUI

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
        VStack(alignment: .leading, spacing: 18) {
            Label(operationTitle, systemImage: operationIcon)
                .font(.title3)
                .fontWeight(.semibold)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                valueRow(L10n.string("Source"), plan.logicalSourceURL.path)
                if plan.resolvedSourceURL != plan.logicalSourceURL {
                    valueRow(L10n.string("Resolved Target"), plan.resolvedSourceURL.path)
                }
                if let destination = plan.destinationURL {
                    valueRow(L10n.string("Destination"), destination.path)
                }
                if let linkTarget = plan.linkTarget {
                    valueRow(L10n.string("Symbolic Link Target"), linkTarget)
                }
            }

            if plan.operation != .delete, plan.hadDestinationConflict {
                Picker(L10n.string("Name Conflict"), selection: $selectedConflict) {
                    Text(verbatim: L10n.string("Keep Both")).tag(FileConflictPolicy.keepBoth)
                    Text(verbatim: L10n.string("Replace")).tag(FileConflictPolicy.replace)
                    Text(verbatim: L10n.string("Cancel")).tag(FileConflictPolicy.cancel)
                }
                .pickerStyle(.segmented)
                .disabled(isOperating)
                .onChange(of: selectedConflict) { _, newValue in
                    replacementConfirmed = false
                    onConflictChange(newValue)
                }
            }

            if plan.operation == .delete {
                disclosure(
                    L10n.string("This Skill will be moved to Trash."),
                    icon: "trash"
                )
            }
            if plan.movesExistingDestinationToTrash {
                disclosure(
                    L10n.string("The existing destination will be moved to Trash before replacement."),
                    icon: "exclamationmark.triangle"
                )
                Toggle(
                    L10n.string("I confirm replacing the existing Skill."),
                    isOn: $replacementConfirmed
                )
                .accessibilityLabel(L10n.string("Confirm replacement"))
            }
            if !plan.affectedIndexedAliases.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: L10n.string("Affected Installations"))
                        .font(.headline)
                    ForEach(plan.affectedIndexedAliases, id: \.self) { path in
                        Text(verbatim: path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            HStack {
                Spacer()
                Button(L10n.string("Cancel"), role: .cancel, action: onCancel)
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
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isOperating
                        || selectedConflict == .cancel
                        || (plan.movesExistingDestinationToTrash && !replacementConfirmed)
                )
                .help(L10n.string("Confirm file operation"))
                .accessibilityLabel(confirmTitle)
            }
        }
        .padding(22)
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 720)
        .interactiveDismissDisabled(isOperating)
    }

    @ViewBuilder
    private func valueRow(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(verbatim: label)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }

    private func disclosure(_ text: String, icon: String) -> some View {
        Label {
            Text(verbatim: text)
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

    private var confirmTitle: String {
        switch plan.operation {
        case .copy: L10n.string("Copy")
        case .move: L10n.string("Move")
        case .delete: L10n.string("Move to Trash")
        case .createSymbolicLink: L10n.string("Create Link")
        }
    }

    private var operationIcon: String {
        switch plan.operation {
        case .copy: "document.on.document"
        case .move: "folder"
        case .delete: "trash"
        case .createSymbolicLink: "link"
        }
    }
}
