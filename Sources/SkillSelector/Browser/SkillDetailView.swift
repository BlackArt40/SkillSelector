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
                        if let localDesc = skill.localDescription,
                           !localDesc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let lines = MarkdownRenderer.extractBody(localDesc)
                            if let attributed = MarkdownRenderer.buildAttributedString(from: lines) {
                                Text(attributed)
                                    .textSelection(.enabled)
                                    .markdownLinkPolicy()
                            } else {
                                Text(verbatim: localDesc)
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text(verbatim: skill.name)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        if let customDesc = skill.customDescription,
                           !customDesc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Divider()
                            labeledValue(
                                L10n.string("Custom Description"),
                                value: customDesc
                            )
                        }

                        DescriptionEditor(skill: skill)
                            .id(skill.path)
                    }
                    detailSection(L10n.string("Skill Document")) {
                        MarkdownDocumentView(skill: skill)
                    }
                    detailSection(L10n.string("Associations")) {
                        labeledValue(
                            L10n.string("Agents"),
                            value: skill.agentDisplayNames(by: agentNamesByID)
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
        labeledValue(
            L10n.string(root.kind.localizedName),
            value: root.url.path,
            monospaced: true
        )
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
