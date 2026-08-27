import SwiftUI

/// Shown when every storage fallback failed (persistent and in-memory).
/// The app stays open so the user can quit cleanly instead of a hard crash.
struct StorageUnavailableView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(L10n.string("SkillSelector could not initialize its storage."))
                .font(.headline)
            Text(L10n.string("Quit and try again. If the problem persists, the app data may need to be rebuilt."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}