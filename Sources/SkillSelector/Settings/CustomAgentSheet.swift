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
    @Environment(AppModel.self) private var model
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
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: L10n.string(editing == nil
                ? "Add Custom Agent"
                : "Edit Custom Agent"))
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)

            VStack(spacing: 12) {
                field(L10n.string("Agent Name"), text: $editor.agentName, prompt: L10n.string("Agent Name"))
                field(L10n.string("Global Roots"), text: $editor.globalRoots, prompt: L10n.string("Comma-separated paths"))
                field(L10n.string("Entry Filename"), text: $editor.entryFilename, prompt: "SKILL.md")
            }

            HStack(spacing: 8) {
                Spacer()
                Button(L10n.string("Cancel")) {
                    dismiss()
                }
                .buttonStyle(ActionButtonStyle(role: .secondary))
                .keyboardShortcut(.cancelAction)
                Button(L10n.string(editing == nil ? "Add" : "Save")) {
                    do {
                        try editor.save(using: model)
                        dismiss()
                    } catch {
                        sheetError = String(describing: error)
                    }
                }
                .buttonStyle(ActionButtonStyle(role: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(editor.agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(AppTheme.background)
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

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: label)
                .font(AppTheme.body(12.5, weight: .medium))
                .foregroundStyle(AppTheme.foregroundSecondary)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(AppTheme.body(13))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppTheme.border, lineWidth: 1)
                }
        }
    }
}
