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
}

@main
struct SkillSelectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        if CommandLine.arguments.contains("--verify-localization-resource") {
            print(L10n.string("SkillSelector"))
            Darwin.exit(EXIT_SUCCESS)
        }
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: SkillRecord.self,
                AuthorizedRootRecord.self
            )
        } catch {
            logger.fault("Persistent store initialization failed, falling back to in-memory: \(error.localizedDescription)")
            container = try! ModelContainer(
                for: SkillRecord.self,
                AuthorizedRootRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
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
        _model = State(
            initialValue: AppModel(
                refresher: refresher,
                index: index,
                bookmarks: bookmarks,
                registry: registry
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    await model.checkEnvironmentOnLaunch()
                    model.presentOnboardingIfNeeded()
                }
        }
            .defaultSize(width: 1440, height: 900)
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
