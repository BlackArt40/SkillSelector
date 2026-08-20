import SkillSelectorCore
import SwiftUI

@MainActor
struct CustomAgentEditorState {
    var selectedAgentID: String?
    var agentName = ""
    var globalRoots = ""
    var projectPatterns = ""
    var entryFilename = "SKILL.md"

    mutating func beginEditing(_ definition: AgentDefinition) {
        selectedAgentID = definition.id
        agentName = definition.displayName
        globalRoots = definition.globalRoots.joined(separator: ", ")
        projectPatterns = definition.projectPatterns.joined(separator: ", ")
        entryFilename = definition.entryFilename
    }

    mutating func save(using model: AppModel) throws {
        try model.saveCustomAgent(
            displayName: agentName,
            globalRoots: splitPaths(globalRoots),
            projectPatterns: splitPaths(projectPatterns),
            entryFilename: entryFilename,
            existingID: selectedAgentID
        )
        reset()
    }

    mutating func reset() {
        selectedAgentID = nil
        agentName = ""
        globalRoots = ""
        projectPatterns = ""
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

/// The add/edit sheet for custom Agents: form fields plus the
/// project-pattern dry run that previews matches before saving.
struct CustomAgentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The definition being edited, nil when adding.
    let editing: AgentDefinition?
    /// Screenshot seeding: run the pattern dry run once on appear so the
    /// preview panel is populated.
    var runsDryRunOnAppear = false

    @State private var editor: CustomAgentEditorState
    @State private var patternDryRunResult: PatternDryRunReport?
    @State private var isPatternDryRunning = false
    @State private var sheetError: String?

    init(editing: AgentDefinition? = nil, runsDryRunOnAppear: Bool = false) {
        self.editing = editing
        self.runsDryRunOnAppear = runsDryRunOnAppear
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
                field(L10n.string("Project Patterns"), text: $editor.projectPatterns, prompt: L10n.string("Comma-separated paths"))
                field(L10n.string("Entry Filename"), text: $editor.entryFilename, prompt: "SKILL.md")
            }
            .onChange(of: editor.projectPatterns) { _, _ in
                patternDryRunResult = nil
            }
            .onChange(of: editor.entryFilename) { _, _ in
                patternDryRunResult = nil
            }

            patternDryRunSection

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
        .task {
            if runsDryRunOnAppear {
                runPatternDryRun()
            }
        }
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

    // MARK: Pattern dry run

    private var draftPatterns: [String] {
        editor.projectPatterns
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
    }

    private var hasDraftPatterns: Bool {
        !draftPatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .allSatisfy(\.isEmpty)
    }

    private var patternDryRunSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: L10n.string("Pattern Preview"))
                    .font(AppTheme.body(12.5, weight: .medium))
                    .foregroundStyle(AppTheme.foregroundSecondary)
                Spacer()
                Button {
                    runPatternDryRun()
                } label: {
                    HStack(spacing: 6) {
                        if isPatternDryRunning {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(verbatim: L10n.string("Dry Run…"))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(SettingsButtonStyle())
                .disabled(!hasDraftPatterns || isPatternDryRunning)
                .help(L10n.string("Dry Run Help"))
            }
            if let patternDryRunResult {
                patternDryRunResultView(patternDryRunResult)
            }
        }
    }

    private func patternDryRunResultView(_ report: PatternDryRunReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if report.matches.isEmpty {
                Text(verbatim: hasProjectRoots
                    ? L10n.string("Dry Run No Matches")
                    : L10n.string("Dry Run No Project Roots"))
                    .font(AppTheme.body(12))
                    .foregroundStyle(AppTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: L10n.string("Dry Run Matches", report.matches.count))
                    .font(AppTheme.body(12, weight: .medium))
                    .foregroundStyle(AppTheme.foregroundSecondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.matches) { match in
                            patternDryRunMatchRow(match)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !report.skippedRootPaths.isEmpty {
                Text(verbatim: L10n.string("Dry Run Skipped Roots", report.skippedRootPaths.count))
                    .font(AppTheme.body(11.5))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.borderSoft, lineWidth: 1)
        }
    }

    private func patternDryRunMatchRow(_ match: PatternDryRunMatch) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: match.url.path)
                .font(AppTheme.mono(11.5))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(match.url.path)
            HStack(spacing: 10) {
                if match.skillNames.isEmpty {
                    Text(verbatim: L10n.string("Dry Run No Skills", editor.entryFilename.isEmpty ? "SKILL.md" : editor.entryFilename))
                        .foregroundStyle(AppTheme.warn)
                } else {
                    Text(verbatim: L10n.string("Dry Run Skill Count", match.skillNames.count))
                        .foregroundStyle(AppTheme.muted)
                }
                ForEach(match.bindings.keys.sorted(), id: \.self) { name in
                    Text(verbatim: "{\(name)} = \(match.bindings[name] ?? "")")
                        .foregroundStyle(AppTheme.muted)
                }
            }
            .font(AppTheme.body(11.5))
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var hasProjectRoots: Bool {
        model.authorizedRoots.contains { $0.kind == .project }
    }

    private func runPatternDryRun() {
        let entry = editor.entryFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        isPatternDryRunning = true
        Task {
            patternDryRunResult = await model.dryRunProjectPatterns(
                patterns: draftPatterns,
                entryFilename: entry.isEmpty ? "SKILL.md" : entry
            )
            isPatternDryRunning = false
        }
    }
}
