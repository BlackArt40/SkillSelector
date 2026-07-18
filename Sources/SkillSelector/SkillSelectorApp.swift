import SkillSelectorCore
import SwiftData
import SwiftUI
import Darwin

@main
struct SkillSelectorApp: App {
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
            fatalError("Unable to initialize SkillSelector storage: \(error)")
        }
        let bookmarks = BookmarkStore(container: container)
        let index = SkillIndex(container: container)
        let registry = BuiltInAgentRegistry.make()
        let refresher = IndexRefresher(
            registry: registry,
            bookmarks: bookmarks,
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
                .task { await model.checkEnvironmentOnLaunch() }
        }
            .defaultSize(width: 1120, height: 720)
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
