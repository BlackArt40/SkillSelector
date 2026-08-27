import AppKit
import OSLog
import SkillSelectorCore
import SwiftData
import SwiftUI
import Darwin

private let logger = Logger(subsystem: "com.SkillSelector", category: "App")

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bare-binary dev launches (swift run, .build/debug/SkillSelector)
        // carry no bundle Info.plist, so the process starts in the
        // prohibited activation policy: no Dock icon, no Cmd+Tab entry,
        // and the window stuck behind everything. Packaged apps are
        // already .regular, so this is a no-op for them.
        if NSApp.activationPolicy() == .prohibited {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        #if DEBUG
        if ScreenshotMode.isActive {
            Task { @MainActor in
                await ScreenshotMode.run()
            }
        }
        #endif
    }
}

@main
struct SkillSelectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel?

    init() {
        if CommandLine.arguments.contains("--verify-localization-resource") {
            print(L10n.string("SkillSelector"))
            Darwin.exit(EXIT_SUCCESS)
        }
        #if DEBUG
        if ScreenshotMode.configureFromCommandLine() {
            _model = State(initialValue: ScreenshotMode.model)
            return
        }
        #endif
        _model = State(initialValue: Self.makeModel())
    }

    /// Builds the app model, degrading storage instead of crashing (R4):
    /// a damaged or incompatible persistent store falls back to an
    /// in-memory store so the app still opens; only if even the in-memory
    /// container cannot be constructed is the model nil, and the UI shows
    /// a recovery screen instead of terminating.
    private static func makeModel() -> AppModel? {
        guard let container = Self.makeContainer() else {
            logger.fault("Unable to initialize any ModelContainer (persistent and in-memory both failed)")
            return nil
        }
        let bookmarks = BookmarkStore(container: container)
        let index = SkillIndex(container: container)
        let registry = BuiltInAgentRegistry.make()
        let refresher = IndexRefresher(
            registry: registry,
            bookmarks: bookmarks,
            // Fingerprints are the scan's dominant I/O cost; deferring them
            // lets the Skill list appear immediately after an import. The
            // background backfill in AppModel fills them in afterwards.
            scanner: SkillScanner(computesContentFingerprints: false),
            index: index
        )
        return AppModel(
            refresher: refresher,
            index: index,
            bookmarks: bookmarks,
            registry: registry
        )
    }

    private static func makeContainer() -> ModelContainer? {
        do {
            return try ModelContainer(
                for: SkillRecord.self,
                AuthorizedRootRecord.self
            )
        } catch {
            logger.fault("Persistent store initialization failed, falling back to in-memory: \(error.localizedDescription)")
        }
        return try? ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                RootView()
                    .environment(model)
                    .task {
                        await model.checkEnvironmentOnLaunch()
                    }
            } else {
                StorageUnavailableView()
            }
        }
            .defaultSize(width: 1440, height: 900)
            .commands {
                WindowCommands()
            }
        Settings {
            if let model {
                SettingsView()
                    .environment(model)
            }
        }
    }
}
