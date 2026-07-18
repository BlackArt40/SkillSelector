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
            @Bindable var model = model
            VStack(alignment: .leading, spacing: 18) {
                AuthorizationViews()
                Divider()
                MCPSettingsView()
                Divider()
                Toggle(
                    L10n.string("Enrich Missing Descriptions After Refresh"),
                    isOn: $model.enrichMissingDescriptionsAfterRefresh
                )
                Text(verbatim: L10n.string(
                    "Uses local gh, npm, and enabled read-only MCP tools only for Skills without custom, local, or remote descriptions."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
                .environment(model)
                .padding(20)
                .frame(width: 560)
                .background(
                    SettingsWindowTitle(title: L10n.string("SkillSelector Settings"))
                )
        }
    }
}
