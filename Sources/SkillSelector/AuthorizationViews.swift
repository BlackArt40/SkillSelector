import AppKit
import SkillSelectorCore
import SwiftUI

struct AuthorizationViews: View {
    @Environment(AppModel.self) private var model
    var kinds: [AuthorizedRootKind] = AuthorizedRootKind.allCases
    var showsHeading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeading {
                Text(verbatim: L10n.string("Directories"))
                    .font(.headline)
            }
            ForEach(kinds, id: \.self) { kind in
                authorizationButton(systemImage: systemImage(for: kind), kind: kind)
            }
        }
    }

    private func authorizationButton(
        systemImage: String,
        kind: AuthorizedRootKind
    ) -> some View {
        Button {
            guard let url = chooseDirectory(kind: kind) else {
                return
            }
            Task { await model.authorize(url, as: kind) }
        } label: {
            Label(title(for: kind), systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseDirectory(kind: AuthorizedRootKind) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title(for: kind)
        panel.message = message(for: kind)
        panel.prompt = L10n.string("Authorize")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if kind == .home {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }

    private func title(for kind: AuthorizedRootKind) -> String {
        switch kind {
        case .home:
            L10n.string("Home Directory")
        case .project:
            L10n.string("Project Directory")
        case .system:
            L10n.string("System Skill Directory")
        case .custom:
            L10n.string("Custom Skill Directory")
        }
    }

    private func message(for kind: AuthorizedRootKind) -> String {
        switch kind {
        case .home:
            L10n.string("SkillSelector accesses only known Agent paths inside your home directory.")
        case .project:
            L10n.string("Choose the exact project directory to scan.")
        case .system:
            L10n.string("Choose the exact system Skill directory to scan.")
        case .custom:
            L10n.string("Choose the exact custom Skill directory to scan.")
        }
    }

    private func systemImage(for kind: AuthorizedRootKind) -> String {
        switch kind {
        case .home: "house"
        case .project: "folder"
        case .system: "externaldrive"
        case .custom: "folder.badge.plus"
        }
    }
}
