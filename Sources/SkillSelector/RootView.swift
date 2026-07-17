import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationSplitView {
            Text("SkillSelector")
        } content: {
            ContentUnavailableView("No Skills", systemImage: "tray")
        } detail: {
            ContentUnavailableView("Select a Skill", systemImage: "doc.text")
        }
    }
}
