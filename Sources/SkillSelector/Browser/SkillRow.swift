import SkillSelectorCore
import SwiftUI

struct SkillRow: View {
    let skill: SkillSnapshot
    let agentNamesByID: [String: String]

    private var agentNames: String {
        skill.agentIDs
            .filter { $0 != "system" && $0 != "custom" }
            .map { agentNamesByID[$0] ?? $0 }
            .sorted()
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(verbatim: skill.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if skill.availability == .unavailable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(L10n.string("Unavailable"))
                        .accessibilityLabel(L10n.string("Unavailable"))
                } else if !skill.parseDiagnostics.isEmpty {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                        .help(L10n.string("Has diagnostics"))
                        .accessibilityLabel(L10n.string("Has diagnostics"))
                }
            }

            if !agentNames.isEmpty {
                Text(verbatim: agentNames)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(verbatim: skill.path)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
