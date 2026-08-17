import AppKit
import SkillSelectorCore
import SwiftUI

/// First-launch welcome sheet. Sandboxed builds cannot silently acquire
/// home-directory access, so the guide routes the user through the
/// directory panel once instead of leaving the app silently unscanned.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            AppIconView(size: 88)
            VStack(spacing: 10) {
                Text(verbatim: L10n.string("Welcome to SkillSelector"))
                    .font(AppTheme.display(22, weight: .semibold))
                    .foregroundStyle(AppTheme.foreground)
                Text(verbatim: L10n.string("Onboarding Message"))
                    .font(AppTheme.body(13))
                    .foregroundStyle(AppTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            HStack(spacing: 12) {
                actionButton(
                    icon: Image(systemName: "house"),
                    title: L10n.string("Authorize Home and Scan"),
                    role: .primary,
                    action: chooseHomeDirectory
                )
                actionButton(
                    icon: nil,
                    title: L10n.string("Skip for Now"),
                    role: .secondary,
                    action: { model.dismissOnboarding() }
                )
            }
        }
        .padding(32)
        .frame(width: 460)
        .background(AppTheme.background)
    }

    private func chooseHomeDirectory() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Authorize Home Directory")
        panel.message = L10n.string("Choose a home directory containing Agent Skills (e.g. ~/.claude, ~/.codex).")
        panel.prompt = L10n.string("Authorize")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        // `homeDirectoryForCurrentUser` points at the sandbox container in
        // packaged builds; the panel should open at the real home instead.
        panel.directoryURL = AppModel.realUserHomeDirectory()
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return }
        Task {
            await model.authorize(url, as: .home)
            model.dismissOnboarding()
        }
    }
}
