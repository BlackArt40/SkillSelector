import SkillSelectorCore
import SwiftUI

@MainActor
struct CustomAgentEditorState {
    var selectedAgentID: String?
    var agentName = ""
    var globalRoots = ""
    var entryFilename = "SKILL.md"

    mutating func beginEditing(_ definition: AgentDefinition) {
        selectedAgentID = definition.id
        agentName = definition.displayName
        globalRoots = definition.globalRoots.joined(separator: ", ")
        entryFilename = definition.entryFilename
    }

    mutating func save(using model: AppModel) throws {
        try model.saveCustomAgent(
            displayName: agentName,
            globalRoots: splitPaths(globalRoots),
            entryFilename: entryFilename,
            existingID: selectedAgentID
        )
        reset()
    }

    mutating func reset() {
        selectedAgentID = nil
        agentName = ""
        globalRoots = ""
        entryFilename = "SKILL.md"
    }

    mutating func resetIfEditing(removedID: String) {
        guard selectedAgentID == removedID else { return }
        reset()
    }

    private func splitPaths(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: ",\n"))
    }
}

/// Identifiable presentation request: a fresh identity re-presents the
/// sheet even when the same agent is edited twice in a row.
struct CustomAgentSheetRequest: Identifiable {
    let id = UUID()
    let agent: AgentDefinition?
}

/// The add/edit sheet for custom Agents: the minimal field set —
/// name, global root paths, entry filename.
struct CustomAgentSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// The definition being edited, nil when adding.
    let editing: AgentDefinition?

    @State private var editor: CustomAgentEditorState
    @State private var sheetError: String?

    init(editing: AgentDefinition? = nil) {
        self.editing = editing
        var state = CustomAgentEditorState()
        if let editing {
            state.beginEditing(editing)
        }
        _editor = State(initialValue: state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "pencil")
                    .font(.system(size: 15))
                    .foregroundStyle(AppTheme.foreground)
                Text(verbatim: L10n.string(editing == nil
                    ? "Add Custom Agent"
                    : "Edit Custom Agent"))
                    .font(AppTheme.display(18, weight: .bold))
                    .kerning(-0.9)
                    .foregroundStyle(AppTheme.foreground)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(AppTheme.border)
                    .frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 20) {
                field(L10n.string("Agent Name"), text: $editor.agentName, prompt: L10n.string("Agent Name"))
                field(
                    L10n.string("Global Roots"),
                    text: $editor.globalRoots,
                    prompt: L10n.string("Comma-separated paths"),
                    trailingAction: (L10n.string("Choose…"), appendSelectedDirectory)
                )
                field(L10n.string("Entry Filename"), text: $editor.entryFilename, prompt: "SKILL.md")

                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.muted)
                        Text(verbatim: L10n.string("Custom Agent Rescan Hint"))
                            .font(AppTheme.body(12))
                            .foregroundStyle(AppTheme.muted)
                    }
                    HStack(spacing: 12) {
                        Spacer()
                        Button(L10n.string("Cancel")) {
                            dismiss()
                        }
                        .buttonStyle(ModalToolButtonStyle(kind: .secondary))
                        .keyboardShortcut(.cancelAction)
                        Button(L10n.string(editing == nil ? "Add" : "Save")) {
                            do {
                                try editor.save(using: model)
                                dismiss()
                            } catch {
                                // LocalizedError implementations (e.g.
                                // AppModelValidationError) localize through their
                                // errorDescription; String(describing:) would leak
                                // raw English case names.
                                sheetError = error.localizedDescription
                            }
                        }
                        .buttonStyle(ModalToolButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(editor.agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.top, 4)
            }
            .padding(24)
        }
        .frame(width: 480)
        .background(AppTheme.surface)
        .overlay(Rectangle().stroke(AppTheme.ink, lineWidth: 2))
        .themedAppearance()
        .alert(
            L10n.string("Settings Error"),
            isPresented: Binding(
                get: { sheetError != nil },
                set: { if !$0 { sheetError = nil } }
            )
        ) {
            Button(L10n.string("OK")) { sheetError = nil }
        } message: {
            Text(verbatim: sheetError ?? "")
        }
    }

    /// agent-editor.html's field: bold 12 pt label over a 40 pt input on
    /// the input fill behind a 1 px ink stroke; the roots field carries
    /// the attached 选择… browse button.
    private func field(
        _ label: String,
        text: Binding<String>,
        prompt: String,
        trailingAction: (title: String, action: () -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: label)
                .font(AppTheme.body(12, weight: .bold))
                .foregroundStyle(AppTheme.foreground)
            HStack(spacing: -1) {
                TextField(prompt, text: text)
                    .textFieldStyle(.plain)
                    .font(AppTheme.body(13))
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(AppTheme.inputBackground)
                    .overlay {
                        Rectangle().stroke(AppTheme.ink, lineWidth: 1)
                    }
                if let trailingAction {
                    Button {
                        trailingAction.action()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.system(size: 12))
                            Text(verbatim: trailingAction.title)
                        }
                        .font(AppTheme.body(13))
                        .foregroundStyle(AppTheme.foreground)
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(AppTheme.surfaceMuted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ModalBrowseButtonStyle())
                    .help(trailingAction.title)
                }
            }
        }
    }

    /// Appends a directory picked in the open panel to the comma-separated
    /// roots field — hand-typing absolute paths was the only entry path
    /// before. Trims parts, skips duplicates, joins with ", ".
    private func appendSelectedDirectory() {
        guard let url = DirectoryPanel.chooseSingleDirectory(
            title: L10n.string("Choose Global Root"),
            prompt: L10n.string("Choose")
        ) else { return }
        let existing = editor.globalRoots
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let path = url.path
        guard !existing.contains(path) else { return }
        editor.globalRoots = (existing + [path]).joined(separator: ", ")
    }
}

/// The attached 选择… button: hover lift / press sink like the design's
/// `transition-all` controls.
private struct ModalBrowseButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(AppTheme.ink)
                    .frame(width: 1)
            }
            .hardShadow(.rest, isActive: !configuration.isPressed)
            .offset(
                x: configuration.isPressed ? 1 : (isHovering ? -1 : 0),
                y: configuration.isPressed ? 1 : (isHovering ? -1 : 0)
            )
            .onHover { isHovering = $0 }
    }
}
