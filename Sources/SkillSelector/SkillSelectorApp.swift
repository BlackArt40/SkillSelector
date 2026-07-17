import SkillSelectorCore
import SwiftData
import SwiftUI

@main
struct SkillSelectorApp: App {
    @State private var model: AppModel

    init() {
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
        let refresher = IndexRefresher(
            registry: BuiltInAgentRegistry.make(),
            bookmarks: bookmarks,
            index: index
        )
        _model = State(initialValue: AppModel(refresher: refresher, bookmarks: bookmarks))
    }

    var body: some Scene {
        WindowGroup {
            HSplitView {
                AuthorizationViews()
                    .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
                    .padding()
                RootView()
            }
                .environment(model)
                .task { await model.checkEnvironmentOnLaunch() }
        }
            .defaultSize(width: 1120, height: 720)
    }
}
