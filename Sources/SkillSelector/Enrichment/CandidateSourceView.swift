import SkillSelectorCore
import SwiftUI

struct CandidateSourceView: View {
    let group: EnrichmentCandidateGroup
    let position: (current: Int, total: Int)
    let onCancel: () -> Void
    let onSkip: () -> Void
    let onApply: (MetadataCandidate, Bool) -> Void

    @State private var selectedIndex = 0
    @State private var bindAsUpdateSource = false
    @State private var confirmsSourceBinding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            List(selection: $selectedIndex) {
                ForEach(Array(group.candidates.enumerated()), id: \.offset) { index, candidate in
                    candidateRow(candidate)
                        .tag(index)
                }
            }
            .listStyle(.inset)
            Divider()
            controls
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 470, idealHeight: 540)
        .onChange(of: selectedIndex) { _, _ in
            bindAsUpdateSource = false
            confirmsSourceBinding = false
        }
        .confirmationDialog(
            L10n.string("Confirm Update Source"),
            isPresented: $confirmsSourceBinding,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Apply and Bind Source")) {
                apply(bindSource: true)
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: L10n.string(
                "This candidate will also become the confirmed update source for this Skill."
            ))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: L10n.string("Review Metadata Candidates"))
                    .font(.headline)
                Text(verbatim: group.skillName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if position.total > 1 {
                Text(verbatim: String.localizedStringWithFormat(
                    L10n.string("Skill %lld of %lld"),
                    Int64(position.current),
                    Int64(position.total)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private func candidateRow(_ candidate: MetadataCandidate) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: candidate.sourceIdentifier)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(verbatim: providerName(candidate.provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let subdirectory = candidate.skillSubdirectory {
                Label {
                    Text(verbatim: subdirectory)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(verbatim: candidate.description)
                .lineLimit(4)
                .textSelection(.enabled)
            Link(destination: candidate.evidenceURL) {
                Label {
                    Text(verbatim: candidate.evidenceURL.absoluteString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if selectedCandidate?.sourceBinding != nil {
                Toggle(
                    L10n.string("Bind as Update Source"),
                    isOn: $bindAsUpdateSource
                )
                .help(L10n.string("Require separate confirmation before binding the selected source."))
            }

            HStack {
                Button(L10n.string("Cancel"), role: .cancel, action: onCancel)
                if position.total > 1 {
                    Button(L10n.string("Skip"), action: onSkip)
                }
                Spacer()
                Button(L10n.string("Apply Metadata")) {
                    if SourceBindingDecision.shouldRequestConfirmation(
                        bindAsUpdateSource: bindAsUpdateSource,
                        sourceBinding: selectedCandidate?.sourceBinding
                    ) {
                        confirmsSourceBinding = true
                    } else {
                        apply(bindSource: false)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    group.candidates.indices.contains(selectedIndex) == false
                        || (bindAsUpdateSource && selectedCandidate?.sourceBinding == nil)
                )
            }
        }
        .padding(20)
    }

    private func apply(bindSource: Bool) {
        guard group.candidates.indices.contains(selectedIndex) else { return }
        let candidate = group.candidates[selectedIndex]
        onApply(candidate, bindSource && candidate.sourceBinding != nil)
    }

    private var selectedCandidate: MetadataCandidate? {
        guard group.candidates.indices.contains(selectedIndex) else { return nil }
        return group.candidates[selectedIndex]
    }

    private func providerName(_ provider: MetadataProviderKind) -> String {
        switch provider {
        case .github: "GitHub"
        case .npm: "npm"
        case .mcp: "MCP"
        }
    }
}
