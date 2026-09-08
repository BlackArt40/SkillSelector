import AppKit

/// Shared single-directory picker for the four call sites (re-authorize in
/// the sidebar + Settings, import project/system root, Settings import):
/// one place for the can-choose-directories / no-files / no-multiple
/// configuration. Before this helper the four builds had drifted — only
/// some standardized the returned URL or disabled directory creation.
@MainActor
enum DirectoryPanel {
    /// Shows the panel and returns the chosen directory, standardized.
    /// `message` is the explanatory line (nil for the re-authorize panel);
    /// `initialDirectory` pre-selects a folder (re-authorize).
    static func chooseSingleDirectory(
        title: String,
        message: String? = nil,
        prompt: String,
        initialDirectory: URL? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        if let message { panel.message = message }
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let initialDirectory { panel.directoryURL = initialDirectory }
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.standardizedFileURL
    }
}
