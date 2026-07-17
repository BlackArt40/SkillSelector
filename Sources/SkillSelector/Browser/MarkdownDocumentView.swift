import SkillSelectorCore
import SwiftUI

struct MarkdownDocumentView: View {
    private enum LoadState {
        case loading
        case rendered(AttributedString)
        case raw(String)
        case tooLarge
        case unavailable
        case failed(String)
    }

    @Environment(AppModel.self) private var model
    let skill: SkillSnapshot

    @State private var state: LoadState = .loading
    @State private var actionErrorDetail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Spacer()
                iconButton(
                    systemName: "folder",
                    label: L10n.string("Reveal Skill Document in Finder"),
                    action: reveal
                )
                iconButton(
                    systemName: "arrow.up.forward.app",
                    label: L10n.string("Open Skill Document in Default Editor"),
                    action: open
                )
            }

            if let actionErrorDetail {
                errorShell(
                    title: L10n.string("Unable to Open Skill Document"),
                    detail: actionErrorDetail
                )
            }

            content
        }
        .task(id: skill.path) {
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: L10n.string("Loading Skill document"))
                    .foregroundStyle(.secondary)
            }
        case .rendered(let attributed):
            Text(attributed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .raw(let source):
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: L10n.string("Raw Markdown"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: source)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        case .tooLarge:
            messageShell(
                title: L10n.string("Document Too Large to Render"),
                detail: L10n.string("Documents larger than 1 MiB can be opened in the default editor.")
            )
        case .unavailable:
            messageShell(
                title: L10n.string("Skill Document Unavailable"),
                detail: L10n.string("The document is unavailable until its authorized folder can be accessed.")
            )
        case .failed(let detail):
            errorShell(title: L10n.string("Unable to Load Skill Document"), detail: detail)
        }
    }

    @MainActor
    private func load() async {
        actionErrorDetail = nil
        guard skill.availability == .available else {
            state = .unavailable
            return
        }
        state = .loading
        do {
            let document = try await model.loadDocument(for: skill)
            try Task.checkCancellation()
            let source = document.source
            let renderTask = Task.detached(priority: .userInitiated) {
                try? AttributedString(markdown: source)
            }
            let attributed = await withTaskCancellationHandler {
                await renderTask.value
            } onCancel: {
                renderTask.cancel()
            }
            try Task.checkCancellation()
            if let attributed {
                state = .rendered(attributed)
            } else {
                state = .raw(document.source)
            }
        } catch SkillDocumentReaderError.tooLarge {
            guard !Task.isCancelled else { return }
            state = .tooLarge
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(localizedDocumentError(error))
        }
    }

    private func reveal() {
        performAction { try model.revealDocumentInFinder(for: skill) }
    }

    private func open() {
        performAction { try model.openDocumentInDefaultEditor(for: skill) }
    }

    private func performAction(_ action: () throws -> Void) {
        do {
            try action()
            actionErrorDetail = nil
        } catch {
            actionErrorDetail = localizedDocumentError(error)
        }
    }

    private func iconButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(skill.availability != .available)
        .help(label)
        .accessibilityLabel(label)
    }

    private func messageShell(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title)
                .font(.callout.weight(.medium))
            Text(verbatim: detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func errorShell(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func localizedDocumentError(_ error: Error) -> String {
        switch error {
        case SkillDocumentReaderError.invalidEntryFilename:
            L10n.string("The entry filename is invalid.")
        case SkillDocumentReaderError.unauthorizedInstallationPath,
             SkillDocumentReaderError.invalidResolvedTarget,
             SkillDocumentReaderError.entryEscapesAuthorizedRoot:
            L10n.string("The document is outside its authorized folder.")
        case SkillDocumentReaderError.notRegularFile:
            L10n.string("The Skill document is not a regular file.")
        case SkillDocumentReaderError.unreadableFile:
            L10n.string("The Skill document cannot be read.")
        case SkillDocumentReaderError.invalidUTF8:
            L10n.string("The Skill document is not valid UTF-8 text.")
        case SkillDocumentReaderError.tooLarge:
            L10n.string("The Skill document is larger than the 1 MiB render limit.")
        case AppModelDocumentError.authorizationStorageUnavailable:
            L10n.string("Authorization storage is unavailable")
        case AppModelDocumentError.noAuthorizedRoot:
            L10n.string("No authorized folder is associated with this Skill.")
        case AppModelDocumentError.externalOpenFailed:
            L10n.string("The default editor could not open the Skill document.")
        default:
            String(describing: error)
        }
    }
}
