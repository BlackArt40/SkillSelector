import SkillSelectorCore
import SwiftUI

struct DescriptionEditor: View {
    @Environment(AppModel.self) private var model
    let skill: SkillSnapshot

    @State private var isEditing = false
    @State private var draft = ""
    @State private var errorDetail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isEditing {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 86, maxHeight: 150)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.separator, lineWidth: 1)
                    }
                    .accessibilityLabel(L10n.string("Custom Description"))

                HStack(spacing: 8) {
                    Button(L10n.string("Save"), action: save)
                        .keyboardShortcut(.defaultAction)
                    Button(L10n.string("Cancel"), action: cancel)
                    if skill.customDescription != nil {
                        Button(L10n.string("Delete Custom Description"), role: .destructive, action: restore)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Button {
                        draft = skill.customDescription ?? ""
                        errorDetail = nil
                        isEditing = true
                    } label: {
                        Label(L10n.string("Edit Custom Description"), systemImage: "pencil")
                    }
                    if skill.customDescription != nil {
                        Button(L10n.string("Delete Custom Description"), role: .destructive, action: restore)
                    }
                }
            }

            if let errorDetail {
                errorShell(errorDetail)
            }
        }
    }

    private func save() {
        do {
            try model.saveCustomDescription(path: skill.path, value: draft)
            errorDetail = nil
            isEditing = false
        } catch {
            errorDetail = localizedDescriptionError(error)
        }
    }

    private func cancel() {
        draft = skill.customDescription ?? ""
        errorDetail = nil
        isEditing = false
    }

    private func restore() {
        do {
            try model.restoreDefaultDescription(path: skill.path)
            draft = ""
            errorDetail = nil
            isEditing = false
        } catch {
            errorDetail = localizedDescriptionError(error)
        }
    }

    private func errorShell(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(L10n.string("Unable to Save Description"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func localizedDescriptionError(_ error: Error) -> String {
        if case SkillIndexError.skillNotFound = error {
            return L10n.string("The selected Skill is no longer indexed.")
        }
        return String(describing: error)
    }
}
