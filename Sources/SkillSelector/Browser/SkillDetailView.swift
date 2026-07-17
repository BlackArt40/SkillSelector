import SkillSelectorCore
import SwiftUI

struct SkillDetailView: View {
    let skill: SkillSnapshot?
    let rootsByID: [String: AuthorizedRootSnapshot]
    let agentNamesByID: [String: String]

    var body: some View {
        if let skill {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    summary(skill)
                    detailSection(L10n.string("Description")) {
                        Text(verbatim: SkillQuery.effectiveDescription(for: skill))
                            .textSelection(.enabled)
                    }
                    detailSection(L10n.string("Associations")) {
                        labeledValue(
                            L10n.string("Agents"),
                            value: skill.agentIDs
                                .map { agentNamesByID[$0] ?? $0 }
                                .sorted()
                                .joined(separator: ", ")
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
                Text(verbatim: reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
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
        guard let line = issue.line else { return issue.message }
        return String.localizedStringWithFormat(
            L10n.string("Line %lld: %@"),
            Int64(line),
            issue.message
        )
    }
}
