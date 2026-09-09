import AppKit
import SkillSelectorCore
import SwiftUI

/// The rename sheet for an authorized root: edits the display name that
/// overrides the folder name in the sidebar and the directories pane.
/// An empty name restores the folder-name default. Project-level roots
/// only — system rows always show their kind label, so renaming those
/// would have no visible effect.
struct RootRenameSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let root: AuthorizedRootSnapshot
    @State private var name: String

    init(root: AuthorizedRootSnapshot) {
        self.root = root
        _name = State(initialValue: root.customName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: L10n.string("Rename Directory"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: L10n.string("Display Name"))
                    .font(AppTheme.body(12.5, weight: .medium))
                    .foregroundStyle(AppTheme.foregroundSecondary)
                TextField(L10n.string("Display Name"), text: $name)
                    .textFieldStyle(.plain)
                    .font(AppTheme.body(13))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppTheme.border, lineWidth: 1)
                    }
                Text(verbatim: L10n.string("Rename Directory Sub"))
                    .font(AppTheme.body(11.5))
                    .foregroundStyle(AppTheme.muted)
            }

            Text(verbatim: root.url.path)
                .font(AppTheme.mono(11.5))
                .foregroundStyle(AppTheme.muted)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Spacer()
                Button(L10n.string("Cancel")) {
                    dismiss()
                }
                .buttonStyle(ActionButtonStyle(role: .secondary))
                .keyboardShortcut(.cancelAction)
                Button(L10n.string("Save")) {
                    model.renameRoot(id: root.id, to: name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .buttonStyle(ActionButtonStyle(role: .primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(AppTheme.background)
    }
}
