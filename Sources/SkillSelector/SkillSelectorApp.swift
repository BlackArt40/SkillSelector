import AppKit
import OSLog
import SkillSelectorCore
import SwiftData
import SwiftUI
import Darwin

private let logger = Logger(subsystem: "com.SkillSelector", category: "App")

/// Holds a flock on a lock file for the whole process lifetime. Two
/// SkillSelector instances would otherwise open the same SwiftData store
/// concurrently — SQLite WAL contention made the second process crash on
/// launch (the "flash-exit after restarting the terminal app" report).
private final class SingleInstanceLock {
    private var fileDescriptor: Int32 = -1

    init?() {
        let lockURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SkillSelector", isDirectory: true)
            .appendingPathComponent("instance.lock")
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("Single-instance lock directory creation failed: \(error.localizedDescription)")
        }
        fileDescriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fileDescriptor >= 0 else { return nil }
        if flock(fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            close(fileDescriptor)
            fileDescriptor = -1
            return nil
        }
    }

    deinit {
        if fileDescriptor >= 0 {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }
}

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

    /// Held for the process lifetime; nil means another instance owns the
    /// store (the app then terminates instead of racing it).
    private let instanceLock: SingleInstanceLock?

    init() {
        if CommandLine.arguments.contains("--verify-localization-resource") {
            print(L10n.string("SkillSelector"))
            Darwin.exit(EXIT_SUCCESS)
        }
        #if DEBUG
        if ScreenshotMode.configureFromCommandLine() {
            _model = State(initialValue: ScreenshotMode.model)
            instanceLock = nil
            return
        }
        #endif
        // Grab the single-instance lock *before* touching the store. When a
        // previous instance is still running (e.g. after restarting the
        // terminal app without quitting it), acquiring fails and we exit
        // cleanly instead of crashing on store contention.
        instanceLock = SingleInstanceLock()
        guard instanceLock != nil else {
            logger.info("Another SkillSelector instance is already running; exiting.")
            _model = State(wrappedValue: nil)
            // Let the run loop flush once so the window never appears.
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return
        }
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
            // App-scoped store: the SwiftData default (a shared
            // "default.store" in ~/Library/Application Support) collides
            // with every other SwiftData app on the machine. A dedicated
            // per-app directory keeps this app's store private.
            let storeURL = Self.storeURL()
            let configuration = ModelConfiguration(url: storeURL)
            return try ModelContainer(
                for: SkillRecord.self,
                AuthorizedRootRecord.self,
                configurations: configuration
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

    /// `~/Library/Application Support/SkillSelector/SkillSelector.store` —
    /// never the shared SwiftData default location.
    private static func storeURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SkillSelector", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("SkillSelector.store")
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
