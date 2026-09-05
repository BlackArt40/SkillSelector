// ScreenshotMode is a development tool: it must never ship in a release
// build. It is compiled only under DEBUG, so the packaged binary has no
// --screenshots entry point at all (audit F-06 / R11).
#if DEBUG
import AppKit
import SkillSelectorCore
import GRDB
import SwiftUI

/// `--screenshots <dir> [--screenshot-language en|zh-Hans]`: renders every
/// README page against a throwaway fixture tree of fake Skills and writes
/// @2x PNGs. Nothing from the real home directory is read — every path,
/// name, and description in the captures is fabricated. The language and
/// theme preferences are borrowed from UserDefaults.standard for the run
/// and restored before exit.
@MainActor
enum ScreenshotMode {
    static var outputDirectory: URL?
    static var language = "en"
    static var model: AppModel?

    private static var savedLanguage: String?
    private static var savedTheme: String?
    private static var savedMainWindowFrame: String?
    private static var mainWindow: NSWindow?

    static var isActive: Bool {
        outputDirectory != nil
    }

    /// File-name tag for the capture set ("en" / "zh").
    private static var languageTag: String {
        language == "zh-Hans" ? "zh" : "en"
    }

    @discardableResult
    static func configureFromCommandLine() -> Bool {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--screenshots"),
              arguments.indices.contains(flag + 1) else {
            return false
        }
        outputDirectory = URL(fileURLWithPath: arguments[flag + 1])
        if let languageIndex = arguments.firstIndex(of: "--screenshot-language"),
           arguments.indices.contains(languageIndex + 1) {
            language = arguments[languageIndex + 1]
        }
        // L10n, languageReloading, and the theme @AppStorage all read
        // UserDefaults.standard; borrow it for the run, restore after.
        savedLanguage = UserDefaults.standard.string(forKey: "SkillSelector.preferredLanguage")
        savedTheme = UserDefaults.standard.string(forKey: ThemePreference.storageKey)
        // MainWindowFrame (frame autosave in RootView) reads the saved
        // "MainWindow" frame and would resize every capture window to the
        // host's stale frame; borrow-and-remove it so captures stay at the
        // seeded 1440x900 regardless of how the real app was last sized.
        savedMainWindowFrame = UserDefaults.standard.string(forKey: "NSWindow Frame MainWindow")
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame MainWindow")
        UserDefaults.standard.set(language, forKey: "SkillSelector.preferredLanguage")
        UserDefaults.standard.set("light", forKey: ThemePreference.storageKey)
        do {
            model = try makeModel()
        } catch {
            fatalError("Screenshot fixtures could not be built: \(error)")
        }
        return true
    }

    // MARK: Capture sequence

    static func run() async {
        guard let model, let outputDirectory else { return }
        try? FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        await model.refresh()
        model.selectOnly(
            model.snapshots.first { $0.name == "code-reviewer" }?.path
        )

        // 1. Main window — the real WindowGroup window with its toolbar.
        await settle()
        mainWindow = NSApp.windows.first { $0.isVisible }
        if let mainWindow {
            capture(mainWindow, name: "main-\(languageTag).png", chrome: true)
        }

        // 2. Duplicates page, hosted full-size.
        let duplicates = hostedWindow(
            RootView(initialDestination: .duplicates).environmentObject(model),
            size: NSSize(width: 1440, height: 900)
        )
        await settle()
        capture(duplicates, name: "duplicates-\(languageTag).png")
        duplicates.orderOut(nil)

        // 2b. MCP page, hosted full-size — the new detection surface.
        let mcp = hostedWindow(
            RootView(initialDestination: .mcp).environmentObject(model),
            size: NSSize(width: 1440, height: 900)
        )
        await settle()
        capture(mcp, name: "mcp-\(languageTag).png")
        mcp.orderOut(nil)

        // 2c. Rules page, hosted full-size — pre-select a CLAUDE.md so the
        // capture shows the rendered rule body (Textual) and the
        // same-name comparison against its global/project counterpart.
        let rulesFileID = model.rules.files.first { $0.filename == "CLAUDE.md" }?.id
            ?? model.rules.files.first?.id
        let rules = hostedWindow(
            RootView(
                initialDestination: .rules,
                initialRulesSelection: rulesFileID
            ).environmentObject(model),
            size: NSSize(width: 1440, height: 900)
        )
        await settle()
        capture(rules, name: "rules-\(languageTag).png")
        rules.orderOut(nil)

        // 2d. Catalog page, hosted full-size — real declared sources,
        // fetched live: the listing is public GitHub data and the shot is
        // meant to show what the ecosystem actually offers. Loaded before
        // hosting so the capture never shows a transient loading state.
        // Pre-select the first listed skill so the detail shows its
        // rendered marketplace document; the document is fetched live, so
        // the settle window below covers that fetch.
        await model.catalog.loadIfNeeded()
        let catalogSkillID: String?
        if case .loaded(let skills, _) = model.catalog.state {
            catalogSkillID = skills.first?.id
        } else {
            catalogSkillID = nil
        }
        let catalog = hostedWindow(
            RootView(
                initialDestination: .catalog,
                initialCatalogSelection: catalogSkillID
            ).environmentObject(model),
            size: NSSize(width: 1440, height: 900)
        )
        await settle(seconds: 4)
        capture(catalog, name: "catalog-\(languageTag).png")
        catalog.orderOut(nil)

        // 3. Settings window (directories tab), titled so it can host sheets.
        let settings = titledHostedWindow(
            SettingsView(initialTab: .directories).environmentObject(model)
        )
        await settle()
        capture(settings, name: "settings-\(languageTag).png")

        // 4. Custom agent editor sheet.
        if let droid = model.customAgentDefinitions.first {
            let editor = presentSheet(
                CustomAgentSheet(editing: droid)
                    .environmentObject(model),
                on: settings
            )
            await settle(seconds: 1.2)
            capture(editor, name: "agent-editor-\(languageTag).png", chrome: true)
            settings.endSheet(editor)
            await settle(seconds: 0.4)
        }

        // 5. Diagnostics viewer sheet.
        let diagnostics = presentSheet(
            DiagnosticsViewerView(
                input: model.redactedDiagnostics(),
                onExport: {}
            ),
            on: settings
        )
        await settle()
        capture(diagnostics, name: "diagnostics-\(languageTag).png", chrome: true)
        settings.endSheet(diagnostics)

        restorePreferences()
        exit(EXIT_SUCCESS)
    }

    // MARK: Model and fixtures

    private static func makeModel() throws -> AppModel {
        let fixtures = try FixtureBuilder.build()
        let database = try SkillStore.inMemory()
        let bookmarks = BookmarkStore(
            database: database,
            adapter: ScreenshotBookmarkAdapter()
        )
        try bookmarks.save(url: fixtures.home, kind: .home)
        try bookmarks.save(url: fixtures.project, kind: .project)
        let index = SkillIndex(database: database)
        let registry = BuiltInAgentRegistry.make()
        let refresher = IndexRefresher(
            registry: registry,
            bookmarks: bookmarks,
            // Fingerprints computed inline so the duplicates view is fully
            // grouped by the time the captures start.
            scanner: SkillScanner(),
            index: index
        )
        let defaults = UserDefaults(
            suiteName: "SkillSelectorScreenshots-\(UUID().uuidString)"
        )!
        let model = AppModel(
            refresher: refresher,
            index: index,
            bookmarks: bookmarks,
            registry: registry,
            defaults: defaults,
            homeDirectory: fixtures.home
        )
        try model.saveCustomAgent(
            displayName: "Droid",
            globalRoots: ["~/.droid/skills"],
            entryFilename: "AGENT.md"
        )
        return model
    }

    private static func restorePreferences() {
        if let savedLanguage {
            UserDefaults.standard.set(savedLanguage, forKey: "SkillSelector.preferredLanguage")
        } else {
            UserDefaults.standard.removeObject(forKey: "SkillSelector.preferredLanguage")
        }
        if let savedTheme {
            UserDefaults.standard.set(savedTheme, forKey: ThemePreference.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ThemePreference.storageKey)
        }
        if let savedMainWindowFrame {
            UserDefaults.standard.set(savedMainWindowFrame, forKey: "NSWindow Frame MainWindow")
        } else {
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame MainWindow")
        }
    }

    // MARK: Window helpers

    private static func hostedWindow<Content: View>(
        _ content: Content,
        size: NSSize
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: content)
        window.orderFrontRegardless()
        return window
    }

    private static func titledHostedWindow<Content: View>(
        _ content: Content
    ) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.orderFrontRegardless()
        return window
    }

    private static func presentSheet<Content: View>(
        _ content: Content,
        on parent: NSWindow
    ) -> NSWindow {
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: content))
        sheet.isReleasedWhenClosed = false
        parent.beginSheet(sheet)
        return sheet
    }

    private static func settle(seconds: Double = 0.7) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Capture

    private static func capture(
        _ window: NSWindow,
        name: String,
        chrome: Bool = false
    ) {
        guard let contentView = window.contentView else { return }
        // The titlebar and toolbar live on the window's frame view above
        // the content view; capturing it yields the whole window.
        let target = chrome ? contentView.superview ?? contentView : contentView
        let bounds = target.bounds
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width) * 2,
            pixelsHigh: Int(bounds.height) * 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        representation.size = bounds.size
        target.cacheDisplay(in: bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            return
        }
        try? png.write(to: outputDirectory!.appending(path: name))
    }
}

// MARK: - Fixtures

/// A throwaway tree of fake Skills: a fake home directory with several
/// agents (including one content-identical pair for the duplicates view)
/// and a fake project with a `.droid/skills` directory for the dry-run
/// preview in the custom-agent editor.
private enum FixtureBuilder {
    static func build() throws -> (home: URL, project: URL) {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "SkillSelectorScreenshots", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: base)
        let home = base.appending(path: "home", directoryHint: .isDirectory)
        let project = base.appending(path: "Projects/demo-webapp", directoryHint: .isDirectory)

        try writeSkill(
            at: home.appending(path: ".claude/skills/code-reviewer"),
            name: "code-reviewer",
            description: "Review staged changes for bugs, regressions, and style drift before commit.",
            body: richBody
        )
        try writeSkill(
            at: home.appending(path: ".claude/skills/git-commit-writer"),
            name: "git-commit-writer",
            description: "Turn staged changes into a conventional commit message.",
            body: shortBody("git-commit-writer")
        )
        // Identical bytes under two agents: one duplicate group.
        try writeSkill(
            at: home.appending(path: ".claude/skills/pdf"),
            name: "pdf",
            description: "Extract text, tables, and metadata from PDF files.",
            body: shortBody("pdf")
        )
        try writeSkill(
            at: home.appending(path: ".codex/skills/pdf-toolkit"),
            name: "pdf-toolkit",
            description: "Extract text, tables, and metadata from PDF files.",
            body: pdfBody
        )
        try writeSkill(
            at: home.appending(path: ".cursor/skills/pdf-toolkit"),
            name: "pdf-toolkit",
            description: "Extract text, tables, and metadata from PDF files.",
            body: pdfBody
        )
        try writeSkill(
            at: home.appending(path: ".kiro/skills/test-runner"),
            name: "test-runner",
            description: "Run the focused test target and summarize failures.",
            body: shortBody("test-runner")
        )
        try writeSkill(
            at: home.appending(path: ".agents/skills/doc-style-guardian"),
            name: "doc-style-guardian",
            description: "Keep headings, lists, and code fences consistent.",
            body: shortBody("doc-style-guardian")
        )
        try writeSkill(
            at: project.appending(path: ".cursor/skills/api-mocking"),
            name: "api-mocking",
            description: "Mock REST endpoints from an OpenAPI document.",
            body: shortBody("api-mocking")
        )
        try writeSkill(
            at: project.appending(path: ".droid/skills/deploy-helper"),
            name: "deploy-helper",
            description: "Walk through the staging deploy checklist.",
            body: shortBody("deploy-helper"),
            entryFilename: "AGENT.md"
        )
        // MCP fixtures: a Codex TOML and a Claude JSON, so the MCP entry —
        // sidebar count, list rows, and the Agent detail's MCP half — shows
        // real content in the captures.
        try writeMcpCodexToml(at: home.appending(path: ".codex/config.toml"))
        try writeMcpClaudeJson(at: home.appending(path: ".claude.json"))
        // Rules fixtures: global and project files plus directory sources,
        // so the rules page lists rows instead of its empty state.
        try writeText(
            "# Global Claude Rules\n\n- Review before commit, never after.\n- Prefer small, reversible changes.\n",
            to: home.appending(path: ".claude/CLAUDE.md")
        )
        // A same-named project CLAUDE.md so the rules detail's「同名文件对比」
        // section has a global↔project pair to diff in the capture.
        try writeText(
            "# Project Claude Rules\n\n- Review before commit, never after.\n- Always run the full test suite first.\n",
            to: project.appending(path: "CLAUDE.md")
        )
        try writeText(
            "# Docs Style\n\nKeep headings hierarchical and code fences tagged.\n",
            to: home.appending(path: ".claude/rules/docs-style.md")
        )
        try writeText(
            "---\ndescription: API conventions\nglobs:\n  - \"src/api/**\"\nalwaysApply: false\n---\n\n# API Conventions\n\nReturn typed errors; never throw raw strings.\n",
            to: home.appending(path: ".cursor/rules/api-conventions.mdc")
        )
        try writeText(
            "# Demo Webapp Agents\n\nRun `swift test` before proposing changes.\n",
            to: project.appending(path: "AGENTS.md")
        )
        try writeText(
            "# Testing Rules\n\nEvery bug fix ships with a regression test.\n",
            to: project.appending(path: ".roo/rules/testing.md")
        )
        return (home, project)
    }

    private static func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeMcpCodexToml(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [mcp_servers.context7]
        command = "npx"
        args = ["-y", "@upstash/context7-mcp"]

        [mcp_servers.server-health]
        url = "https://example.com/mcp"
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeMcpClaudeJson(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {
          "mcpServers": {
            "filesystem": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/alice/Projects/demo-webapp"]
            },
            "github": {
              "type": "http",
              "url": "https://api.githubcopilot.com/mcp/"
            }
          }
        }
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeSkill(
        at directory: URL,
        name: String,
        description: String,
        body: String,
        entryFilename: String = "SKILL.md"
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = """
        ---
        name: \(name)
        description: \(description)
        ---

        \(body)
        """
        try document.write(
            to: directory.appending(path: entryFilename),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func shortBody(_ name: String) -> String {
        """
        # \(name)

        Ask with a plain instruction and read the answer in place. The
        skill keeps its guidance short and links out for the long forms.
        """
    }

    private static let pdfBody = """
    # pdf-toolkit

    Extracts text, tables, and metadata from PDF files without external
    services.

    ## Usage

        pdf-toolkit extract report.pdf --pages 1-10 --format markdown

    ## Notes

    - Scanned pages fall back to a clear "no text layer" message
    - Tables come out as pipe-delimited rows
    """

    private static let richBody = """
    # Code Reviewer

    Reviews a diff the way a careful teammate would: read the change, then
    read around it.

    ## What it checks

    - Logic errors and off-by-one mistakes
    - Error paths that swallow failures silently
    - Style drift from the project conventions

    ## Example

    Ask with a path prefix:

        Review the staged changes under Sources/Payments

    Output arrives as one comment block per file, severity-tagged and sorted
    by line number.

    | Severity | Meaning |
    |----------|---------|
    | blocker | Must fix before merge |
    | nit | Judgment call |

    ## Links

    - [Review checklist](https://example.com/code-review-checklist)
    """
}

/// Path-encoding bookmark adapter — the screenshot process runs as a bare
/// binary without the app-scope entitlement real security-scoped bookmarks
/// require (same pattern as the test adapters).
private final class ScreenshotBookmarkAdapter: BookmarkDataCreating, @unchecked Sendable {
    func createBookmarkData(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolveBookmarkData(_ data: Data) throws -> BookmarkResolution {
        BookmarkResolution(
            url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
            isStale: false
        )
    }

    func startAccessing(_ url: URL) -> Bool { true }

    func stopAccessing(_ url: URL) {}
}
#endif
