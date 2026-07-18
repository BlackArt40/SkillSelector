import SkillSelectorCore
import SwiftUI

struct UpdateReviewView: View {
    let proposal: UpdateProposal
    let isUpdating: Bool
    let onCancel: () -> Void
    let onConfirm: (_ allowLocalChanges: Bool) -> Void

    @State private var warningConfirmed = false

    private var requiresWarningConfirmation: Bool {
        proposal.hasIndexedLocalChanges
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: L10n.string("Review Skill Update"))
                        .font(.headline)
                    Text(verbatim: proposal.actualTargetURL.lastPathComponent)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailSection(L10n.string("Source")) {
                        labeledValue(L10n.string("Update Source"), proposal.source.binding)
                        labeledValue(
                            L10n.string("Selected Reference"),
                            proposal.source.reference.map(referenceLabel) ?? L10n.string("Not available")
                        )
                        labeledValue(
                            L10n.string("Resolved Commit"),
                            proposal.resolvedReference ?? L10n.string("Not available"),
                            monospaced: true
                        )
                        labeledValue(L10n.string("Content Digest"), proposal.remoteDigest.value, monospaced: true)
                    }

                    if !proposal.affectedAliases.isEmpty {
                        detailSection(L10n.string("Linked Installations")) {
                            labeledValue(
                                L10n.string("Actual Update Target"),
                                proposal.actualTargetURL.path,
                                monospaced: true
                            )
                            ForEach(proposal.affectedAliases, id: \.path) { alias in
                                Label {
                                    Text(verbatim: alias.path)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                } icon: {
                                    Image(systemName: "link")
                                }
                            }
                        }
                    }

                    detailSection(L10n.string("File Changes")) {
                        if proposal.changes.isEmpty {
                            Label(L10n.string("No content changes"), systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(proposal.changes, id: \.self) { change in
                                HStack(spacing: 8) {
                                    Image(systemName: icon(for: change.kind))
                                        .foregroundStyle(color(for: change.kind))
                                        .frame(width: 16)
                                    Text(verbatim: change.path)
                                        .font(.callout.monospaced())
                                        .textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    Text(verbatim: label(for: change.kind))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if requiresWarningConfirmation {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(
                                L10n.string("Local changes were detected after the indexed version."),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                            Toggle(
                                L10n.string("I understand that the local changes will be replaced."),
                                isOn: $warningConfirmed
                            )
                            .toggleStyle(.checkbox)
                        }
                        .padding(12)
                        .background(Color.orange.opacity(0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.orange.opacity(0.3))
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button(L10n.string("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isUpdating)
                Spacer()
                Button {
                    onConfirm(warningConfirmed)
                } label: {
                    if isUpdating {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Label(L10n.string("Install Update"), systemImage: "arrow.down.doc")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isUpdating || (requiresWarningConfirmation && !warningConfirmed))
            }
            .padding(16)
        }
        .frame(width: 600, height: 620)
        .interactiveDismissDisabled(isUpdating)
    }

    private func detailSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labeledValue(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
        }
    }

    private func icon(for kind: UpdateChangeKind) -> String {
        switch kind {
        case .added: "plus.circle"
        case .changed: "pencil.circle"
        case .deleted: "minus.circle"
        }
    }

    private func color(for kind: UpdateChangeKind) -> Color {
        switch kind {
        case .added: .green
        case .changed: .orange
        case .deleted: .red
        }
    }

    private func label(for kind: UpdateChangeKind) -> String {
        switch kind {
        case .added: L10n.string("Added")
        case .changed: L10n.string("Changed")
        case .deleted: L10n.string("Deleted")
        }
    }

    private func referenceLabel(_ reference: UpdateReference) -> String {
        switch reference {
        case .branch(let value): "\(L10n.string("Branch")): \(value)"
        case .tag(let value): "\(L10n.string("Tag")): \(value)"
        case .commit(let value): "\(L10n.string("Commit")): \(value)"
        }
    }
}
