import AppKit
import SkillSelectorCore
import SwiftUI

struct SkillDetailView: View {
    @Environment(AppModel.self) private var model
    let skill: SkillSnapshot?
    let rootsByID: [String: AuthorizedRootSnapshot]
    let agentNamesByID: [String: String]

    var body: some View {
        if let skill {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    summary(skill)
                    detailSection(L10n.string("Description")) {
                        let effective = DescriptionResolver.resolve(
                            DescriptionCandidates(snapshot: skill)
                        )
                        Text(verbatim: effective.text)
                            .textSelection(.enabled)
                        Text(verbatim: String.localizedStringWithFormat(
                            L10n.string("Description source: %@"),
                            provenanceName(effective.source)
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Divider()
                        labeledValue(
                            L10n.string("Custom Description"),
                            value: candidateValue(skill.customDescription)
                        )
                        labeledValue(
                            L10n.string("Local Skill Document"),
                            value: candidateValue(skill.localDescription)
                        )
                        labeledValue(
                            L10n.string("Remote Metadata"),
                            value: candidateValue(skill.enrichedDescription)
                        )
                        if let provenance = skill.enrichedDescriptionProvenance {
                            labeledValue(
                                L10n.string("Remote Provenance"),
                                value: provenance,
                                monospaced: true
                            )
                        }
                        labeledValue(L10n.string("Local Fallback"), value: skill.name)
                        DescriptionEditor(skill: skill)
                            .id(skill.path)
                    }
                    detailSection(L10n.string("Skill Document")) {
                        MarkdownDocumentView(skill: skill)
                    }
                    detailSection(L10n.string("Associations")) {
                        labeledValue(
                            L10n.string("Agents"),
                            value: skill.agentIDs
                                .filter { $0 != "system" && $0 != "custom" }
                                .map { agentNamesByID[$0] ?? $0 }
                                .sorted()
                                .joined(separator: ", ")
                                .nilIfEmpty ?? L10n.string("None")
                        )
                    }
                    detailSection(L10n.string("Locations")) {
                        ForEach(skill.rootIDs, id: \.self) { rootID in
                            if let root = rootsByID[rootID] {
                                rootRow(root)
                            } else {
                                labeledValue(L10n.string("Root"), value: rootID)
                            }
                        }
                        labeledValue(L10n.string("Installation Path"), value: skill.path, monospaced: true)
                        if let target = skill.resolvedTarget {
                            labeledValue(L10n.string("Resolved Target"), value: target, monospaced: true)
                        }
                        labeledValue(L10n.string("Entry File"), value: skill.entryFilename, monospaced: true)
                    }
                    detailSection(L10n.string("Source")) {
                        labeledValue(
                            L10n.string("Update Source"),
                            value: skill.sourceBinding ?? L10n.string("Not configured")
                        )
                        if let digest = skill.digest {
                            labeledValue(L10n.string("Content Digest"), value: digest, monospaced: true)
                        }
                    }
                    detailSection(L10n.string("Trusted Metadata")) {
                        Button {
                            Task { await model.enrich([skill]) }
                        } label: {
                            Label(
                                L10n.string("Find Metadata"),
                                systemImage: "text.magnifyingglass"
                            )
                        }
                        .controlSize(.small)
                        .disabled(
                            model.enrichmentCommandsDisabled
                                || skill.availability != .available
                        )
                        .help(L10n.string(
                            "Find trusted metadata with local gh, npm, and enabled read-only MCP tools"
                        ))
                    }
                    detailSection(L10n.string("File Operations")) {
                        fileOperationControls(skill)
                    }
                    detailSection(L10n.string("Diagnostics")) {
                        if skill.parseDiagnostics.isEmpty {
                            Text(verbatim: L10n.string("No diagnostics"))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(skill.parseDiagnostics.enumerated()), id: \.offset) { _, issue in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "exclamationmark.circle")
                                        .foregroundStyle(.orange)
                                    Text(verbatim: diagnosticText(issue))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(skill.name)
        } else {
            ContentUnavailableView(
                L10n.string("Select a Skill"),
                systemImage: "doc.text.magnifyingglass",
                description: Text(verbatim: L10n.string("Choose a Skill from the list to inspect its local details."))
            )
        }
    }

    private func summary(_ skill: SkillSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: skill.name)
                .font(.title2)
                .fontWeight(.semibold)
                .textSelection(.enabled)
            Label {
                Text(verbatim: skill.availability == .available
                    ? L10n.string("Available")
                    : L10n.string("Unavailable"))
            } icon: {
                Image(systemName: skill.availability == .available
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill")
            }
            .foregroundStyle(skill.availability == .available ? Color.secondary : Color.orange)

            if let reason = skill.unavailableReason {
                Text(verbatim: skill.unavailableDiagnostic.map(L10n.diagnostic) ?? reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func fileOperationControls(_ skill: SkillSnapshot) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            operationButton(
                L10n.string("Copy"),
                icon: "document.on.document",
                help: L10n.string("Copy Skill"),
                operation: .copy,
                skill: skill
            )
            operationButton(
                L10n.string("Move"),
                icon: "folder",
                help: L10n.string("Move Skill"),
                operation: .move,
                skill: skill
            )
            operationButton(
                L10n.string("Create Link"),
                icon: "link",
                help: L10n.string("Create Symbolic Link"),
                operation: .createSymbolicLink,
                skill: skill
            )
            Button(role: .destructive) {
                Task { await model.planFileOperation(.delete, for: skill) }
            } label: {
                Label(L10n.string("Trash"), systemImage: "trash")
            }
            .disabled(model.fileOperationCommandsDisabled || skill.availability != .available)
            .help(L10n.string("Move Skill to Trash"))
            .accessibilityLabel(L10n.string("Move Skill to Trash"))
        }
        .controlSize(.small)
    }

    private func operationButton(
        _ title: String,
        icon: String,
        help: String,
        operation: FileOperationKind,
        skill: SkillSnapshot
    ) -> some View {
        Button {
            chooseDestination(for: operation, skill: skill)
        } label: {
            Label(title, systemImage: icon)
        }
        .disabled(model.fileOperationCommandsDisabled || skill.availability != .available)
        .help(help)
        .accessibilityLabel(help)
    }

    private func chooseDestination(for operation: FileOperationKind, skill: SkillSnapshot) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = L10n.string("Choose Skill Root")
        panel.prompt = L10n.string("Choose Skill Root")
        panel.message = L10n.string("Choose a registered Skill root")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await model.planFileOperation(
                operation,
                for: skill,
                destinationRootURL: url,
                conflictPolicy: .keepBoth
            )
        }
    }

    private func detailSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title)
                .font(.headline)
            content()
            Divider()
        }
    }

    private func labeledValue(
        _ label: String,
        value: String,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
        }
    }

    private func rootRow(_ root: AuthorizedRootSnapshot) -> some View {
        labeledValue(rootKindName(root.kind), value: root.url.path, monospaced: true)
    }

    private func rootKindName(_ kind: AuthorizedRootKind) -> String {
        switch kind {
        case .home: L10n.string("Home Root")
        case .project: L10n.string("Project Root")
        case .system: L10n.string("System Root")
        case .custom: L10n.string("Custom Root")
        }
    }

    private func diagnosticText(_ issue: ParseIssue) -> String {
        let message = issue.diagnostic.map(L10n.diagnostic) ?? issue.message
        guard let line = issue.line else { return message }
        return String.localizedStringWithFormat(
            L10n.string("Line %lld: %@"),
            Int64(line),
            message
        )
    }

    private func provenanceName(_ source: EffectiveDescription.Source) -> String {
        switch source {
        case .custom: L10n.string("Custom")
        case .local: L10n.string("Local Document")
        case .remote: L10n.string("Remote")
        case .fallback: L10n.string("Fallback")
        }
    }

    private func candidateValue(_ value: String?) -> String {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.string("Not available")
        }
        return value
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
