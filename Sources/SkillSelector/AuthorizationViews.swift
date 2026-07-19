import AppKit
import SkillSelectorCore
import SwiftUI

struct AuthorizationViews: View {
    @Environment(AppModel.self) private var model
    var showsHeading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeading {
                Text(verbatim: L10n.string("Directories"))
                    .font(.headline)
            }
            Button {
                guard let url = chooseDirectory(
                    title: L10n.string("Import System Directory"),
                    message: L10n.string("Choose a home directory containing Agent Skills (e.g. ~/.claude, ~/.codex).")
                ) else { return }
                Task { await model.authorize(url, as: .home) }
            } label: {
                Label(L10n.string("Import System Directory"), systemImage: "house")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                guard let url = chooseDirectory(
                    title: L10n.string("Import Project Directory"),
                    message: L10n.string("Choose a project directory to scan for all Skills.")
                ) else { return }
                Task { await model.authorize(url, as: .project) }
            } label: {
                Label(L10n.string("Import Project Directory"), systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func chooseDirectory(title: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = L10n.string("Import")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }
}
