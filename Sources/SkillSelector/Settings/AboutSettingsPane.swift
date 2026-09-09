import AppKit
import SwiftUI

/// The 关于 pane: app icon, version, tagline, links, and the privacy /
/// signature group. Pure presentation — no state, no model access.
struct AboutSettingsPane: View {
    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            AppIconView(size: 128)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
            LogoView(height: 40)
                .padding(.top, 16)
            Text(verbatim: L10n.string("Version Line", appVersion))
                .font(AppTheme.body(12.5))
                .foregroundStyle(AppTheme.muted)
                .padding(.top, 8)
            Text(verbatim: L10n.string("Tagline"))
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.foregroundSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            HStack(spacing: 16) {
                aboutLink(L10n.string("GitHub"), url: URL(string: "https://github.com/BlackArt40/SkillSelector"))
                aboutLink(L10n.string("Release Notes"), url: URL(string: "https://github.com/BlackArt40/SkillSelector/releases"))
                aboutLink(L10n.string("Apache License"), url: URL(string: "https://github.com/BlackArt40/SkillSelector/blob/main/LICENSE"))
            }
            .padding(.top, 16)

            SettingsGroup {
                SettingsRow(
                    label: L10n.string("Privacy"),
                    sub: L10n.string("Privacy Sub")
                )
                SettingsRow(
                    label: L10n.string("Signature"),
                    sub: L10n.string("Signature Sub")
                )
            }
            .padding(.top, 24)

            Text(verbatim: L10n.string("About Footer"))
                .font(AppTheme.body(11))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 24)
        }
        .frame(maxWidth: .infinity)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    private func aboutLink(_ title: String, url: URL?) -> some View {
        Button {
            if let url {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Text(verbatim: title)
                .font(AppTheme.body(12.5))
                .underline()
                .foregroundStyle(AppTheme.accentActive)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}
