import AppKit
import SkillSelectorCore
import SwiftUI

struct AuthorizationViews: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Directories")
                .font(.headline)
            authorizationButton(
                title: "Home Directory",
                systemImage: "house",
                kind: .home,
                message: "SkillSelector accesses only known Agent paths inside your home directory."
            )
            authorizationButton(
                title: "Project Directory",
                systemImage: "folder",
                kind: .project,
                message: "Choose the exact project directory to scan."
            )
            authorizationButton(
                title: "System Skill Directory",
                systemImage: "externaldrive",
                kind: .system,
                message: "Choose the exact system Skill directory to scan."
            )
            authorizationButton(
                title: "Custom Skill Directory",
                systemImage: "folder.badge.plus",
                kind: .custom,
                message: "Choose the exact custom Skill directory to scan."
            )
        }
    }

    private func authorizationButton(
        title: String,
        systemImage: String,
        kind: AuthorizedRootKind,
        message: String
    ) -> some View {
        Button {
            guard let url = chooseDirectory(title: title, message: message, kind: kind) else {
                return
            }
            Task { await model.authorize(url, as: kind) }
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseDirectory(
        title: String,
        message: String,
        kind: AuthorizedRootKind
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = "Authorize"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if kind == .home {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }
}
