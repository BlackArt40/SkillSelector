import SwiftUI

/// Shown when every storage fallback failed (persistent and in-memory).
/// The app stays open so the user can quit cleanly instead of a hard crash.
struct StorageUnavailableView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.muted)
            Text(L10n.string("SkillSelector could not initialize its storage."))
                .font(AppTheme.display(14, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            Text(L10n.string("Quit and try again. If the problem persists, the app data may need to be rebuilt."))
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.foregroundSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}